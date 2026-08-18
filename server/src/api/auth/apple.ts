/**
 * Server-side verification of a Sign in with Apple identity token.
 *
 * The whole point of this file is that the iOS app is not trusted. It sends
 * an identity token and the raw nonce it generated; everything that decides
 * *who* the user is comes out of a signature Apple made, never out of a
 * field the client filled in. `ASAuthorizationAppleIDCredential.user` is
 * deliberately not accepted from the client — the `sub` claim is the only
 * subject this service will store.
 *
 * What is checked, and why each one matters:
 *
 *   signature   — the token really came from Apple.
 *   alg RS256   — enforced in `verifyRs256` before any key is used, so a
 *                 `none` or HMAC token cannot be smuggled through.
 *   iss         — issued by appleid.apple.com and not some other IdP.
 *   aud         — issued for *this* app. Without it, a token minted for any
 *                 other Apple client would sign the holder in here.
 *   exp / iat   — inside its short validity window, with a small skew
 *                 allowance in both directions.
 *   nonce       — SHA-256 of the raw nonce the client sends must equal the
 *                 `nonce` claim, which ties the token to this sign-in
 *                 attempt. Single-use enforcement is the caller's job (see
 *                 `db/nonces.ts`); this function only proves the binding.
 *
 * Not here: the authorization code. Exchanging it needs an Apple client
 * secret signed with a .p8 key, which this PR deliberately does not add.
 *
 * That is a deferral, not a dismissal. Apple requires an app offering Sign
 * in with Apple to let users delete their account *and* revoke the token
 * (`/auth/revoke`), which needs the code exchange, the refresh token in
 * encrypted storage, and the .p8 client secret. So this is a gate that must
 * close before Apple sign-in ships publicly — not something to pick up
 * "later, if deletion is ever built".
 */

import { type JwksProvider, RemoteJwksProvider } from "./jwks";
import {
	type JwtClaims,
	decodeJwt,
	sha256Hex,
	verifyRs256,
} from "./jwt";

export const APPLE_ISSUER = "https://appleid.apple.com";
const APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys";

/**
 * Apple's key set, and only Apple's.
 *
 * The endpoint is a module constant that nothing outside this file can see,
 * so there is no path from a request field to an outbound URL.
 */
export function createAppleJwksProvider(): JwksProvider {
	return new RemoteJwksProvider({ url: APPLE_JWKS_URL });
}

/** Tolerance for clock drift between Apple, the edge, and the device. */
export const APPLE_CLOCK_SKEW_SECONDS = 60;

export interface AppleVerificationInput {
	identityToken: string;
	/** The un-hashed nonce the app generated for this sign-in. */
	rawNonce: string;
	/** This app's bundle identifier. */
	audience: string;
	jwks: JwksProvider;
	/** Unix seconds; injectable so expiry is testable. */
	now?: number;
}

export interface VerifiedAppleIdentity {
	/** Apple's stable subject. The only identifier this service stores. */
	subject: string;
	email: string | null;
	emailVerified: boolean;
	/** SHA-256 of the raw nonce — the value replay protection keys on. */
	nonceHash: string;
	expiresAt: number;
}

export class AppleTokenInvalidError extends Error {
	constructor(readonly reason: string) {
		// The reason is for logs and tests. The HTTP layer must not pass it
		// to the client: which check failed is information an attacker can
		// iterate against.
		super(`apple identity token rejected: ${reason}`);
		this.name = "AppleTokenInvalidError";
	}
}

export async function verifyAppleIdentityToken(
	input: AppleVerificationInput,
): Promise<VerifiedAppleIdentity> {
	const now = input.now ?? Math.floor(Date.now() / 1000);

	if (!input.audience) {
		// A misconfigured audience must never degrade into "accept anything".
		throw new AppleTokenInvalidError("audience is not configured");
	}
	if (!input.rawNonce) {
		throw new AppleTokenInvalidError("missing nonce");
	}

	const decoded = decodeJwt(input.identityToken);

	const kid = decoded.header.kid;
	if (!kid) throw new AppleTokenInvalidError("header has no kid");

	const key = await input.jwks.keyForId(kid);
	if (!key) throw new AppleTokenInvalidError("unknown signing key");

	await verifyRs256(decoded, key);

	const claims = decoded.claims;
	assertIssuer(claims);
	assertAudience(claims, input.audience);
	assertWindow(claims, now);
	const nonceHash = await assertNonce(claims, input.rawNonce);

	const subject = claims.sub;
	if (typeof subject !== "string" || subject.length === 0) {
		throw new AppleTokenInvalidError("missing sub");
	}

	return {
		subject,
		email: typeof claims.email === "string" ? claims.email : null,
		emailVerified: readEmailVerified(claims),
		nonceHash,
		expiresAt: claims.exp as number,
	};
}

function assertIssuer(claims: JwtClaims): void {
	if (claims.iss !== APPLE_ISSUER) {
		throw new AppleTokenInvalidError("unexpected issuer");
	}
}

/** Apple sends `aud` as a string; the spec allows an array, so both work. */
function assertAudience(claims: JwtClaims, audience: string): void {
	const actual = claims.aud;
	const matches = Array.isArray(actual)
		? actual.includes(audience)
		: actual === audience;
	if (!matches) throw new AppleTokenInvalidError("audience mismatch");
}

function assertWindow(claims: JwtClaims, now: number): void {
	const { exp, iat } = claims;
	if (typeof exp !== "number") throw new AppleTokenInvalidError("missing exp");
	if (now >= exp + APPLE_CLOCK_SKEW_SECONDS) {
		throw new AppleTokenInvalidError("expired");
	}
	// Required, not merely checked-if-present. Apple always sends `iat`, and
	// treating an absent or non-numeric one as "fine" would let a token with
	// a forged-looking time window through the only freshness check `exp`
	// does not cover.
	if (typeof iat !== "number") throw new AppleTokenInvalidError("missing iat");
	if (iat - APPLE_CLOCK_SKEW_SECONDS > now) {
		throw new AppleTokenInvalidError("issued in the future");
	}
}

async function assertNonce(
	claims: JwtClaims,
	rawNonce: string,
): Promise<string> {
	const expected = await sha256Hex(rawNonce);
	if (typeof claims.nonce !== "string" || claims.nonce.length === 0) {
		throw new AppleTokenInvalidError("token carries no nonce");
	}
	// iOS hands Apple `sha256(rawNonce)`, and Apple echoes it back here.
	if (!timingSafeEqual(claims.nonce, expected)) {
		throw new AppleTokenInvalidError("nonce mismatch");
	}
	return expected;
}

function readEmailVerified(claims: JwtClaims): boolean {
	const value = claims.email_verified;
	return value === true || value === "true";
}

/** Fixed-time comparison of two same-purpose hex strings. */
function timingSafeEqual(a: string, b: string): boolean {
	if (a.length !== b.length) return false;
	let diff = 0;
	for (let i = 0; i < a.length; i += 1) {
		diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
	}
	return diff === 0;
}
