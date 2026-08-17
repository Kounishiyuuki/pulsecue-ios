/**
 * Server-side verification of a Google Sign-In ID token.
 *
 * Same rule as Apple: the iOS app is not trusted with identity. `GIDGoogleUser`
 * hands the app a `userID`, an email and a profile name, and none of them are
 * accepted here — the only subject this service stores is the `sub` claim out
 * of a token whose signature Google made.
 *
 * What is checked, and why each one matters:
 *
 *   signature   — the token really came from Google.
 *   alg RS256   — enforced in `verifyRs256` before any key is used, so a
 *                 `none` or HMAC token cannot be smuggled through.
 *   iss         — one of Google's two documented issuer spellings, from a
 *                 fixed allowlist. Never taken from the token.
 *   aud         — issued for *this backend*. Without it, an ID token minted
 *                 for any other Google client — including one an attacker
 *                 registered themselves — would sign its holder in here.
 *                 This is the single most important claim on a Google ID
 *                 token.
 *
 *                 Which client id that is, is easy to get wrong: it is the
 *                 **Web application ("server") client id**, not the iOS one.
 *                 When the iOS app sets `GIDServerClientID`, Google mints the
 *                 ID token with `aud` set to that server client id — the iOS
 *                 client id stays behind `GIDClientID` and the reversed-client-id
 *                 URL scheme, and never appears in `aud`. `GOOGLE_AUDIENCE`
 *                 must therefore hold the same value as `GIDServerClientID`.
 *                 See the README for the full mapping.
 *   exp / iat   — inside its validity window, with a small skew allowance.
 *   sub         — present and non-empty; it is the account key.
 *
 * Deliberately not here: a nonce / one-time store. Apple's nonce exists
 * because `ASAuthorizationAppleIDRequest` lets the app bind a value it
 * generated into the token, and spending it turns a captured request body
 * into a single-use one. Nothing equivalent reaches this endpoint: the
 * request carries only the ID token, and copying Apple's shape would require
 * the iOS client to supply a bound nonce, which is out of scope for this
 * server-only change. The residual risk it would remove is small: replaying a
 * captured body needs the body, and anyone who can read a TLS request body
 * can equally read the session token in the response. See the README for the
 * follow-up option (single-use on the ID token's own hash) if that call ever
 * changes.
 */

import { type JwksProvider, RemoteJwksProvider } from "./jwks";
import { type JwtClaims, decodeJwt, verifyRs256 } from "./jwt";

/**
 * Google documents both spellings for the same issuer, and which one a token
 * carries has varied by flow. Both are accepted; nothing else is.
 */
export const GOOGLE_ISSUERS = [
	"https://accounts.google.com",
	"accounts.google.com",
] as const;

const GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs";

/** Tolerance for clock drift between Google, the edge, and the device. */
export const GOOGLE_CLOCK_SKEW_SECONDS = 60;

/**
 * Google's key set, and only Google's. The endpoint is a module constant
 * nothing outside this file can see, so no request field can steer a fetch.
 */
export function createGoogleJwksProvider(): JwksProvider {
	return new RemoteJwksProvider({ url: GOOGLE_JWKS_URL });
}

export interface GoogleVerificationInput {
	idToken: string;
	/**
	 * The PulseCue **Web application (server) OAuth client id**, from
	 * configuration — the same value the app sets as `GIDServerClientID`.
	 * Not the iOS client id.
	 */
	audience: string;
	jwks: JwksProvider;
	/** Unix seconds; injectable so expiry is testable. */
	now?: number;
}

export interface VerifiedGoogleIdentity {
	/** Google's stable subject. The only identifier this service stores. */
	subject: string;
	email: string | null;
	emailVerified: boolean;
	expiresAt: number;
}

export class GoogleTokenInvalidError extends Error {
	constructor(readonly reason: string) {
		// The reason is for logs and tests. The HTTP layer must not pass it to
		// the client: which check failed is information an attacker can
		// iterate against.
		super(`google id token rejected: ${reason}`);
		this.name = "GoogleTokenInvalidError";
	}
}

export async function verifyGoogleIdToken(
	input: GoogleVerificationInput,
): Promise<VerifiedGoogleIdentity> {
	const now = input.now ?? Math.floor(Date.now() / 1000);

	if (!input.audience) {
		// A misconfigured audience must never degrade into "accept anything".
		throw new GoogleTokenInvalidError("audience is not configured");
	}

	const decoded = decodeJwt(input.idToken);

	const kid = decoded.header.kid;
	if (!kid) throw new GoogleTokenInvalidError("header has no kid");

	const key = await input.jwks.keyForId(kid);
	if (!key) throw new GoogleTokenInvalidError("unknown signing key");

	await verifyRs256(decoded, key);

	const claims = decoded.claims;
	assertIssuer(claims);
	assertAudience(claims, input.audience);
	assertWindow(claims, now);

	const subject = claims.sub;
	if (typeof subject !== "string" || subject.length === 0) {
		throw new GoogleTokenInvalidError("missing sub");
	}

	return {
		subject,
		email: typeof claims.email === "string" ? claims.email : null,
		emailVerified: readEmailVerified(claims),
		expiresAt: claims.exp as number,
	};
}

function assertIssuer(claims: JwtClaims): void {
	if (
		typeof claims.iss !== "string" ||
		!(GOOGLE_ISSUERS as readonly string[]).includes(claims.iss)
	) {
		throw new GoogleTokenInvalidError("unexpected issuer");
	}
}

/**
 * `aud` must be exactly the one configured audience, as a single string.
 *
 * The JWT spec allows an array, and Google's own tokens for this flow do not
 * use one. Accepting an array would mean accepting a token that was *also*
 * minted for someone else, and the `azp` claim that exists to disambiguate
 * that case is not checked here — so the permissive reading would widen who
 * can sign in without anything else narrowing it back. PulseCue has exactly
 * one server client id, so the narrow contract loses nothing and there is no
 * reason to generalise ahead of a real need.
 */
function assertAudience(claims: JwtClaims, audience: string): void {
	const actual = claims.aud;
	if (typeof actual !== "string" || actual.length === 0) {
		throw new GoogleTokenInvalidError("audience is not a single string");
	}
	if (actual !== audience) {
		throw new GoogleTokenInvalidError("audience mismatch");
	}
}

function assertWindow(claims: JwtClaims, now: number): void {
	const { exp, iat } = claims;
	if (typeof exp !== "number") throw new GoogleTokenInvalidError("missing exp");
	if (now >= exp + GOOGLE_CLOCK_SKEW_SECONDS) {
		throw new GoogleTokenInvalidError("expired");
	}
	if (typeof iat !== "number") throw new GoogleTokenInvalidError("missing iat");
	if (iat - GOOGLE_CLOCK_SKEW_SECONDS > now) {
		throw new GoogleTokenInvalidError("issued in the future");
	}
}

/** Google sends this as a boolean; accept the string form defensively. */
function readEmailVerified(claims: JwtClaims): boolean {
	const value = claims.email_verified;
	return value === true || value === "true";
}
