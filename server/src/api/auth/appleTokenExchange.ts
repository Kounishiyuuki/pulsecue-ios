/**
 * Talking to Apple's token endpoints: exchanging an authorization code, and
 * revoking the refresh token it returns.
 *
 * Why the exchange exists at all: Apple requires an app that offers Sign in
 * with Apple to let users delete their account *and* revoke the token. The
 * revoke call needs a refresh token, and the only way to get one is to trade
 * the `authorizationCode` the app receives during sign-in. So the code is
 * exchanged at sign-in, when it is still valid — it is single-use and
 * short-lived, and there is no way to go back for one at deletion time.
 *
 * Three rules this file exists to hold:
 *
 *   Fixed endpoints. Both URLs are module constants. Nothing derived from a
 *   request reaches `fetch`, so no request can steer an outbound call.
 *
 *   Apple's response is not trusted. It is JSON from the network like any
 *   other; the shape is checked before anything is stored, and a response
 *   carrying an `id_token` has that token verified and its subject compared
 *   against the identity token the client already proved.
 *
 *   Nothing leaks. The authorization code, the client secret, the refresh
 *   token and Apple's raw error body are never logged, never returned, and
 *   never put in an error message. Failures are a small closed set of codes.
 */

import {
	type AppleClientSecretConfig,
	createAppleClientSecret,
} from "./appleClientSecret";
import { APPLE_ISSUER } from "./apple";
import { type JwksProvider } from "./jwks";
import { decodeJwt, verifyRs256 } from "./jwt";

const APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token";
const APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke";

/**
 * Why a call failed, in terms the HTTP layer can map without knowing Apple.
 *
 * `invalidGrant` is the caller's fault (a reused, expired or forged code) and
 * becomes a 401. Everything else is Apple's or ours and becomes a 503 —
 * reporting an Apple outage as "your credentials are invalid" would tell a
 * user something untrue and hide the incident.
 */
export type AppleExchangeFailure =
	| "invalidGrant"
	| "invalidClient"
	| "providerUnavailable"
	| "malformedResponse"
	| "subjectMismatch";

export class AppleExchangeError extends Error {
	constructor(readonly failure: AppleExchangeFailure) {
		// The failure kind only. Never Apple's body, never the code or secret.
		super(`apple token exchange failed: ${failure}`);
		this.name = "AppleExchangeError";
	}
}

export interface AppleTokenExchangeInput {
	authorizationCode: string;
	config: AppleClientSecretConfig;
	/**
	 * The `sub` from the identity token the client already proved. Apple's
	 * response must agree with it, or nothing is stored.
	 */
	expectedSubject: string;
	/** Used only if the response carries an `id_token`. */
	jwks: JwksProvider;
	fetchImpl?: typeof fetch;
	now?: number;
}

export interface AppleTokenExchangeResult {
	/** The credential PulseCue stores, encrypted, solely to revoke later. */
	refreshToken: string;
	/** Seconds, as Apple reported it. Informational. */
	expiresIn: number | null;
}

/** Trades the single-use authorization code for a refresh token. */
export async function exchangeAppleAuthorizationCode(
	input: AppleTokenExchangeInput,
): Promise<AppleTokenExchangeResult> {
	const now = input.now ?? Math.floor(Date.now() / 1000);
	const clientSecret = await createAppleClientSecret(input.config, now);

	const body = new URLSearchParams({
		client_id: input.config.clientId,
		client_secret: clientSecret,
		code: input.authorizationCode,
		grant_type: "authorization_code",
	});

	const payload = await postForm(
		APPLE_TOKEN_URL,
		body,
		input.fetchImpl ?? fetch,
	);

	const refreshToken = payload.refresh_token;
	if (typeof refreshToken !== "string" || refreshToken.length === 0) {
		// Without it there is nothing to revoke at deletion, which is the only
		// reason this exchange happens. Accepting the sign-in anyway would
		// quietly create an account that cannot meet Apple's requirement.
		throw new AppleExchangeError("malformedResponse");
	}
	if (payload.token_type !== undefined && !isBearer(payload.token_type)) {
		throw new AppleExchangeError("malformedResponse");
	}

	// Apple normally returns an id_token here too. When it does, it is a
	// second signed statement about who this is — and it must name the same
	// person the client already proved, or the code belonged to someone else.
	if (payload.id_token !== undefined) {
		await assertIdTokenSubject(payload.id_token, input, now);
	}

	return {
		refreshToken,
		expiresIn:
			typeof payload.expires_in === "number" ? payload.expires_in : null,
	};
}

export type AppleRevocationOutcome =
	| { status: "revoked" }
	/** Apple no longer recognises the token: the end state we wanted anyway. */
	| { status: "alreadyInvalid" }
	/** Transient. The caller should keep the account deleting and retry. */
	| { status: "unavailable" };

export interface AppleRevocationInput {
	refreshToken: string;
	config: AppleClientSecretConfig;
	fetchImpl?: typeof fetch;
	now?: number;
}

/**
 * Revokes a refresh token at Apple.
 *
 * Returns an outcome rather than throwing, because the caller — account
 * deletion — must make a different decision for each one and must never
 * treat "Apple is down" as "revoked".
 */
export async function revokeAppleRefreshToken(
	input: AppleRevocationInput,
): Promise<AppleRevocationOutcome> {
	const now = input.now ?? Math.floor(Date.now() / 1000);

	let clientSecret: string;
	try {
		clientSecret = await createAppleClientSecret(input.config, now);
	} catch {
		// A broken key is our problem and is fixable; it must not be recorded
		// as a successful revocation.
		return { status: "unavailable" };
	}

	const body = new URLSearchParams({
		client_id: input.config.clientId,
		client_secret: clientSecret,
		token: input.refreshToken,
		token_type_hint: "refresh_token",
	});

	try {
		await postForm(APPLE_REVOKE_URL, body, input.fetchImpl ?? fetch, {
			allowEmptyBody: true,
		});
		return { status: "revoked" };
	} catch (error) {
		if (error instanceof AppleExchangeError) {
			// Apple answers `invalid_grant` for a token it has already
			// forgotten. The account is in the state deletion wanted.
			if (error.failure === "invalidGrant") return { status: "alreadyInvalid" };
		}
		return { status: "unavailable" };
	}
}

// MARK: - Internals

async function postForm(
	url: string,
	body: URLSearchParams,
	fetchImpl: typeof fetch,
	options: { allowEmptyBody?: boolean } = {},
): Promise<Record<string, unknown>> {
	let response: Response;
	try {
		response = await fetchImpl(url, {
			method: "POST",
			headers: { "content-type": "application/x-www-form-urlencoded" },
			body: body.toString(),
		});
	} catch {
		throw new AppleExchangeError("providerUnavailable");
	}

	const text = await response.text().catch(() => "");

	if (!response.ok) {
		// Apple's OAuth errors are a documented small set. Anything else — a
		// 5xx, an HTML error page from a proxy — is an outage, not a verdict
		// on the credential. Apple's body itself is never surfaced.
		const code = readErrorCode(text);
		if (code === "invalid_grant") throw new AppleExchangeError("invalidGrant");
		if (code === "invalid_client") throw new AppleExchangeError("invalidClient");
		throw new AppleExchangeError("providerUnavailable");
	}

	if (text.length === 0) {
		// `/auth/revoke` answers 200 with no body on success.
		if (options.allowEmptyBody) return {};
		throw new AppleExchangeError("malformedResponse");
	}

	let parsed: unknown;
	try {
		parsed = JSON.parse(text);
	} catch {
		throw new AppleExchangeError("malformedResponse");
	}
	if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
		throw new AppleExchangeError("malformedResponse");
	}
	return parsed as Record<string, unknown>;
}

/** Reads `error` out of an OAuth error body without trusting its shape. */
function readErrorCode(text: string): string | null {
	try {
		const parsed = JSON.parse(text) as unknown;
		if (typeof parsed !== "object" || parsed === null) return null;
		const code = (parsed as { error?: unknown }).error;
		return typeof code === "string" ? code : null;
	} catch {
		return null;
	}
}

function isBearer(value: unknown): boolean {
	return typeof value === "string" && value.toLowerCase() === "bearer";
}

/**
 * Verifies the `id_token` Apple returned and checks it names the same person
 * as the identity token the client proved.
 *
 * A mismatch means the authorization code did not belong to the identity
 * token presented alongside it — exactly the shape of an attack that pairs a
 * victim's code with the attacker's own token. Nothing is stored and no
 * session is issued.
 */
async function assertIdTokenSubject(
	idToken: unknown,
	input: AppleTokenExchangeInput,
	now: number,
): Promise<void> {
	if (typeof idToken !== "string" || idToken.length === 0) {
		throw new AppleExchangeError("malformedResponse");
	}

	let subject: string;
	try {
		const decoded = decodeJwt(idToken);
		const kid = decoded.header.kid;
		if (!kid) throw new Error("no kid");
		const key = await input.jwks.keyForId(kid);
		if (!key) throw new Error("unknown key");
		await verifyRs256(decoded, key);

		const claims = decoded.claims;
		if (claims.iss !== APPLE_ISSUER) throw new Error("issuer");
		const audience = claims.aud;
		const audienceOk = Array.isArray(audience)
			? audience.includes(input.config.clientId)
			: audience === input.config.clientId;
		if (!audienceOk) throw new Error("audience");
		if (typeof claims.exp !== "number" || now >= claims.exp + 60) {
			throw new Error("expired");
		}
		if (typeof claims.sub !== "string" || claims.sub.length === 0) {
			throw new Error("sub");
		}
		subject = claims.sub;
	} catch {
		// A response we cannot verify is a response we do not act on.
		throw new AppleExchangeError("malformedResponse");
	}

	if (subject !== input.expectedSubject) {
		throw new AppleExchangeError("subjectMismatch");
	}
}
