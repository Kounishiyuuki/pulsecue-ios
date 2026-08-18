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
 * Four rules this file exists to hold:
 *
 *   Fixed endpoints. Both URLs are module constants. Nothing derived from a
 *   request reaches `fetch`, so no request can steer an outbound call.
 *
 *   Apple's response is not trusted. The shape is checked before anything is
 *   stored, and the `id_token` it carries is *required* and fully verified —
 *   signature, issuer, audience, window, subject — before its subject is
 *   compared to the one the client already proved.
 *
 *   **Revocation succeeds on HTTP 2xx and nothing else.** No error body is
 *   ever read as evidence that a token is gone. See `revokeAppleRefreshToken`.
 *
 *   Nothing leaks. The authorization code, the client secret, the refresh
 *   token, the id_token and Apple's raw error body are never logged, never
 *   returned, and never put in an error message.
 */

import {
	type AppleClientSecretConfig,
	createAppleClientSecret,
} from "./appleClientSecret";
import { AppleTokenInvalidError, verifyAppleIdentityClaims } from "./apple";
import { type JwksProvider } from "./jwks";

const APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token";
const APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke";

/**
 * Why an exchange failed, in terms the HTTP layer can map without knowing
 * Apple.
 *
 * `invalidGrant` and `subjectMismatch` are the caller's fault (a reused,
 * expired or forged code; a code that belongs to somebody else) and become a
 * 401. Everything else is Apple's or ours and becomes a 503 — reporting an
 * Apple outage as "your credentials are invalid" would tell a user something
 * untrue and hide the incident.
 */
export type AppleExchangeFailure =
	| "invalidGrant"
	| "invalidClient"
	| "providerUnavailable"
	| "malformedResponse"
	| "subjectMismatch";

export class AppleExchangeError extends Error {
	constructor(
		readonly failure: AppleExchangeFailure,
		/**
		 * Set when the failure happened *after* Apple issued a refresh token,
		 * and therefore after this service became responsible for that token's
		 * lifecycle. It reports what the compensating revoke achieved.
		 *
		 * `undefined` means no token existed yet, so there was nothing to
		 * compensate — not that compensation was skipped.
		 */
		readonly compensation?: AppleRevocationOutcome,
	) {
		// The failure kind only. Never Apple's body, never the code or secret.
		super(`apple token exchange failed: ${failure}`);
		this.name = "AppleExchangeError";
	}

	/** True when a live Apple grant may still exist that nothing tracks. */
	get leftCredentialOrphaned(): boolean {
		return this.compensation !== undefined && this.compensation.status !== "revoked";
	}
}

export interface AppleTokenExchangeInput {
	authorizationCode: string;
	config: AppleClientSecretConfig;
	/**
	 * The `sub` from the identity token the client already proved. Apple's
	 * response must name the same person, or nothing is stored.
	 */
	expectedSubject: string;
	/** Verifies the `id_token` in Apple's response. */
	jwks: JwksProvider;
	fetchImpl?: typeof fetch;
	now?: number;
}

export interface AppleTokenExchangeResult {
	/** The credential PulseCue stores, encrypted, solely to revoke later. */
	refreshToken: string;
	/** The subject Apple named in the response's own `id_token`. */
	verifiedSubject: string;
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

	const response = await postForm(
		APPLE_TOKEN_URL,
		body,
		input.fetchImpl ?? fetch,
	);

	if (!response.ok) {
		// Only here — on the token endpoint — is an OAuth error code read, and
		// only to tell "this code is bad" from "Apple is having a bad time".
		// It is never read as evidence that something succeeded.
		throw new AppleExchangeError(classifyExchangeError(response));
	}

	const payload = parseJsonObject(response.body);

	const refreshToken = payload.refresh_token;
	if (typeof refreshToken !== "string" || refreshToken.length === 0) {
		// Nothing was issued, so there is nothing to compensate. Without a
		// refresh token there is also nothing to revoke at deletion, which is
		// the only reason this exchange happens — so the sign-in cannot be
		// accepted either.
		throw new AppleExchangeError("malformedResponse");
	}

	// ─────────────────────────────────────────────────────────────────────
	// Apple has now issued a live refresh token, and this function owns its
	// lifecycle from here.
	//
	// Every remaining check can fail, and each one used to `throw` straight
	// past the caller — which left the token valid at Apple with nothing on
	// our side holding it: unrevokable at account deletion, and invisible.
	// So from this point failures go through `abandon`, which hands the token
	// back to Apple before rejecting.
	// ─────────────────────────────────────────────────────────────────────
	const abandon = async (
		failure: AppleExchangeFailure,
	): Promise<never> => {
		const compensation = await revokeAppleRefreshToken({
			refreshToken,
			config: input.config,
			fetchImpl: input.fetchImpl,
			now,
		});
		throw new AppleExchangeError(failure, compensation);
	};

	if (payload.token_type !== undefined && !isBearer(payload.token_type)) {
		await abandon("malformedResponse");
	}
	if (payload.expires_in !== undefined && typeof payload.expires_in !== "number") {
		await abandon("malformedResponse");
	}

	// `id_token` is REQUIRED, not "verified if present". Treating it as
	// optional means an attacker who can suppress it — or an Apple response
	// shape nobody expected — skips the only check that proves this code
	// belonged to the person whose identity token arrived with it.
	//
	// `access_token` is deliberately ignored and never stored: nothing here
	// calls an Apple API on the user's behalf, so keeping one would be holding
	// a credential for no reason.
	let verifiedSubject: string;
	try {
		verifiedSubject = await verifyExchangeIdToken(payload.id_token, input, now);
	} catch {
		return abandon("malformedResponse");
	}

	if (verifiedSubject !== input.expectedSubject) {
		// The attack this closes: a victim's authorization code paired with the
		// attacker's own identity token. Nothing is written, and the token the
		// attacker just caused Apple to mint does not survive the attempt.
		return abandon("subjectMismatch");
	}

	return {
		refreshToken,
		verifiedSubject,
		expiresIn:
			typeof payload.expires_in === "number" ? payload.expires_in : null,
	};
}

/**
 * Why a revocation attempt did not confirm.
 *
 * There is deliberately no "already revoked" outcome. Apple answers 2xx when
 * it accepts a revoke, including for a token it has already forgotten, so a
 * non-2xx is never evidence that the token is gone.
 */
export type AppleRevocationOutcome =
	/** Apple returned 2xx. The only outcome that means revoked. */
	| { status: "revoked" }
	/** Network trouble or a 5xx. Transient; the credential must be kept. */
	| { status: "retryable" }
	/**
	 * Apple returned 4xx. Not transient, and **not revoked** — a bad client
	 * secret or a malformed request says nothing about the token's state.
	 */
	| { status: "rejected" };

export interface AppleRevocationInput {
	refreshToken: string;
	config: AppleClientSecretConfig;
	fetchImpl?: typeof fetch;
	now?: number;
}

/**
 * Revokes a refresh token at Apple.
 *
 * **Success is HTTP 2xx and nothing else.** An earlier version read
 * `invalid_grant` out of a 400 body and called it "already revoked". That
 * inference is wrong and it is dangerous: `invalid_grant` from this endpoint
 * can equally mean the token was issued to a different client, or that the
 * request was malformed. Apple answers 2xx when it *accepts* a revoke —
 * including for a token it has already forgotten — so there is no case where
 * a non-2xx has to be read as success, and every case where doing so records
 * a revocation that never happened. That is precisely the failure Apple's
 * requirement exists to prevent.
 *
 * Returns an outcome rather than throwing, because the caller — account
 * deletion — must make a different decision for each one.
 */
export async function revokeAppleRefreshToken(
	input: AppleRevocationInput,
): Promise<AppleRevocationOutcome> {
	const now = input.now ?? Math.floor(Date.now() / 1000);

	let clientSecret: string;
	try {
		clientSecret = await createAppleClientSecret(input.config, now);
	} catch {
		// A broken key is our problem and is fixable; it must never be
		// recorded as a successful revocation.
		return { status: "retryable" };
	}

	const body = new URLSearchParams({
		client_id: input.config.clientId,
		client_secret: clientSecret,
		token: input.refreshToken,
		token_type_hint: "refresh_token",
	});

	let response: RawResponse;
	try {
		response = await postForm(
			APPLE_REVOKE_URL,
			body,
			input.fetchImpl ?? fetch,
		);
	} catch {
		return { status: "retryable" };
	}

	// The whole decision, in one place, reading only the status line. The
	// body is never consulted — not for success, and not to soften a failure.
	if (response.ok) return { status: "revoked" };
	if (response.status >= 500) return { status: "retryable" };
	return { status: "rejected" };
}

// MARK: - Internals

interface RawResponse {
	ok: boolean;
	status: number;
	body: string;
}

async function postForm(
	url: string,
	body: URLSearchParams,
	fetchImpl: typeof fetch,
): Promise<RawResponse> {
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
	return { ok: response.ok, status: response.status, body: text };
}

/**
 * Maps a failed `/auth/token` response.
 *
 * A 5xx is an outage whatever the body says — an error code inside a 500 is
 * not a verdict on the credential. Only a 4xx carrying a documented OAuth
 * code is treated as one, and anything else (an HTML page from a proxy, an
 * empty body) is an outage.
 */
function classifyExchangeError(response: RawResponse): AppleExchangeFailure {
	if (response.status >= 500) return "providerUnavailable";

	const code = readErrorCode(response.body);
	if (code === "invalid_grant") return "invalidGrant";
	if (code === "invalid_client") return "invalidClient";
	return "providerUnavailable";
}

function parseJsonObject(text: string): Record<string, unknown> {
	if (text.length === 0) throw new AppleExchangeError("malformedResponse");

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
 * Fully verifies the `id_token` Apple returned and yields its subject.
 *
 * The same verifier the app's identity token goes through, minus the nonce:
 * this token is not bound to one. That request is authenticated by the client
 * secret, and Apple does not document a nonce on the exchange response, so
 * demanding one would reject every real exchange. The omission is explicit
 * here rather than hidden inside a shared verifier that quietly stopped
 * checking.
 */
async function verifyExchangeIdToken(
	idToken: unknown,
	input: AppleTokenExchangeInput,
	now: number,
): Promise<string> {
	if (typeof idToken !== "string" || idToken.length === 0) {
		throw new AppleExchangeError("malformedResponse");
	}

	try {
		const verified = await verifyAppleIdentityClaims({
			token: idToken,
			audience: input.config.clientId,
			jwks: input.jwks,
			now,
		});
		return verified.subject;
	} catch (error) {
		// A response we cannot verify is a response we do not act on. The
		// specific claim that failed stays in the log, not in the outcome.
		if (error instanceof AppleTokenInvalidError) {
			throw new AppleExchangeError("malformedResponse");
		}
		throw new AppleExchangeError("malformedResponse");
	}
}
