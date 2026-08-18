/**
 * `POST /v1/auth/apple`
 *
 * Trades a verified Sign in with Apple identity token for a PulseCue
 * session. The client sends what Apple gave it plus the raw nonce it
 * generated; it does not get to say who it is.
 *
 * Every failure answers the same way — `401 invalid_credentials`, no
 * detail. Which check failed (bad signature, wrong audience, expired,
 * replayed, account being deleted, unknown account) is exactly what an
 * attacker would iterate against, and distinguishing "no such account" from
 * "wrong token" is an enumeration oracle. The reason is logged as a short
 * code with a correlation id instead.
 */

import type { Context } from "hono";
import { z } from "zod";
import {
	AccountUnavailableError,
	findOrCreateAccountForIdentity,
} from "../db/accounts";
import { newId } from "../db/ids";
import {
	NonceAlreadyUsedError,
	NonceStoreUnavailableError,
	consumeNonce,
} from "../db/nonces";
import { saveCredentialAndIssueSession } from "../db/providerCredentials";
import { AppleTokenInvalidError, verifyAppleIdentityToken } from "../auth/apple";
import type { AppleClientSecretConfig } from "../auth/appleClientSecret";
import {
	AppleExchangeError,
	exchangeAppleAuthorizationCode,
	revokeAppleRefreshToken,
} from "../auth/appleTokenExchange";
import type { TokenCipher } from "../crypto/tokenCipher";
import { JwksFetchError, type JwksProvider } from "../auth/jwks";
import { JwtMalformedError, JwtSignatureError } from "../auth/jwt";
import type { ApiEnv } from "../types";

const requestSchema = z.object({
	identityToken: z.string().min(1).max(8192),
	/**
	 * Required, not optional. Apple hands this to the app once per sign-in and
	 * it is the only way to obtain the refresh token that account deletion
	 * must revoke. Accepting a sign-in without it would create an account that
	 * cannot meet Apple's revoke-on-deletion requirement — a problem that
	 * cannot be repaired later, because the code is single-use and cannot be
	 * re-requested.
	 */
	authorizationCode: z.string().min(1).max(2048),
	rawNonce: z.string().min(1).max(512),
	/** Optional label for a future "signed-in devices" screen. */
	deviceName: z.string().min(1).max(120).optional(),
});

export interface AppleAuthDependencies {
	jwks: JwksProvider;
	audience: string;
	/**
	 * Null when Apple is not configured for this deployment. Sign-in then
	 * refuses: without the client secret the code cannot be exchanged, and
	 * without the exchange the account could not be deleted properly.
	 */
	clientSecret: AppleClientSecretConfig | null;
	/** Null when no encryption key is configured. Same refusal, same reason. */
	cipher: TokenCipher | null;
	/** Injectable so the exchange is testable without reaching Apple. */
	fetchImpl?: typeof fetch;
	now?: () => number;
}

export function makeAppleAuthHandler(deps: AppleAuthDependencies) {
	return async (c: Context<{ Bindings: ApiEnv }>) => {
		const correlationId = newId();
		const now = deps.now?.() ?? Math.floor(Date.now() / 1000);

		const parsed = requestSchema.safeParse(await readJson(c));
		if (!parsed.success) {
			return reject(c, correlationId, "malformed_request", 400);
		}

		// Checked before anything is verified or spent. A deployment that
		// cannot exchange the code must not consume the user's nonce or create
		// an account it would be unable to delete properly.
		const { clientSecret, cipher } = deps;
		if (!clientSecret || !cipher) {
			return reject(c, correlationId, "apple_not_configured", 503);
		}

		let verified: Awaited<ReturnType<typeof verifyAppleIdentityToken>>;
		try {
			verified = await verifyAppleIdentityToken({
				identityToken: parsed.data.identityToken,
				rawNonce: parsed.data.rawNonce,
				audience: deps.audience,
				jwks: deps.jwks,
				now,
			});
		} catch (error) {
			if (error instanceof JwksFetchError) {
				// Apple being unreachable is our problem, not a bad credential.
				return reject(c, correlationId, "jwks_unavailable", 503);
			}
			if (
				error instanceof AppleTokenInvalidError ||
				error instanceof JwtMalformedError ||
				error instanceof JwtSignatureError
			) {
				return reject(c, correlationId, "token_rejected", 401);
			}
			throw error;
		}

		try {
			// Claimed before the account is touched: a replay must not even
			// refresh `last_seen_at`.
			await consumeNonce(c.env.DB, {
				nonceHash: verified.nonceHash,
				provider: "apple",
				expiresAt: verified.expiresAt,
				now,
			});

			// The exchange comes FIRST, and nothing about the account is
			// written until it has fully succeeded.
			//
			// An earlier version resolved the account before this call, to
			// shrink the window in which an un-stored refresh token could
			// exist. That trade was wrong: it meant a token whose exchange
			// `id_token` named a *different* subject still created a PulseCue
			// user and an auth identity. The window is closed properly instead
			// — `exchangeAppleAuthorizationCode` now revokes the token itself
			// on any validation failure — so account mutation can wait until
			// the subject binding actually holds.
			const exchanged = await exchangeAppleAuthorizationCode({
				authorizationCode: parsed.data.authorizationCode,
				config: clientSecret,
				expectedSubject: verified.subject,
				jwks: deps.jwks,
				fetchImpl: deps.fetchImpl,
				now,
			});

			// Past this line the exchange is fully validated and the two
			// subjects agree, so it is safe to touch the account.
			//
			// A live Apple refresh token exists that only this request knows
			// about. If it is not stored, it becomes a credential nobody can
			// revoke and nobody can see — so *every* failure below, account
			// resolution included, must hand it back to Apple rather than drop
			// it.
			let account: Awaited<ReturnType<typeof findOrCreateAccountForIdentity>>;
			let issued: Awaited<ReturnType<typeof saveCredentialAndIssueSession>>;
			try {
				account = await findOrCreateAccountForIdentity(
					c.env.DB,
					{
						provider: "apple",
						subject: verified.subject,
						email: verified.email,
						emailVerified: verified.emailVerified,
					},
					now,
				);

				// One batch: the encrypted refresh token and the session commit
				// together or not at all. A live session for an account whose
				// credential was not stored is an account that cannot be deleted
				// per Apple's requirement, so that state is unreachable rather
				// than merely unlikely.
				issued = await saveCredentialAndIssueSession(c.env.DB, cipher, {
					userId: account.user.id,
					credential: {
						authIdentityId: account.identity.id,
						provider: "apple",
						refreshToken: exchanged.refreshToken,
					},
					deviceName: parsed.data.deviceName ?? null,
					now,
				});
			} catch (persistenceError) {
				// Best-effort compensation. Note what this deliberately does
				// NOT do: it does not write the token anywhere for a later
				// retry. The failure we are handling is the database, so
				// "store it and try again" would be storing it in the thing
				// that just failed — and persisting a plaintext credential to
				// recover from a storage failure is worse than the problem.
				const compensation = await revokeAppleRefreshToken({
					refreshToken: exchanged.refreshToken,
					config: clientSecret,
					fetchImpl: deps.fetchImpl,
					now,
				});
				if (compensation.status !== "revoked") {
					logCompensationFailure(correlationId, compensation.status);
				}

				// A concurrent deletion is answered exactly as a settled one is,
				// so the race is not a way to tell a deleting account from an
				// unknown one.
				if (persistenceError instanceof AccountUnavailableError) {
					return reject(c, correlationId, "account_unavailable", 401);
				}

				// Otherwise this is our storage failing. Either way no session
				// is issued; the reason only tells an operator whether a live
				// Apple grant is still out there.
				return reject(
					c,
					correlationId,
					compensation.status === "revoked"
						? "persistence_failed_credential_revoked"
						: "persistence_failed_credential_orphaned",
					503,
				);
			}

			return c.json({
				sessionToken: issued.token,
				expiresAt: issued.session.expires_at,
				user: {
					id: account.user.id,
					created: account.created,
				},
			});
		} catch (error) {
			if (error instanceof NonceAlreadyUsedError) {
				return reject(c, correlationId, "nonce_replayed", 401);
			}
			if (error instanceof AppleExchangeError) {
				// The exchange revokes the token itself when it fails *after*
				// Apple issued one. If that revoke did not confirm, a live
				// Apple grant may still exist that nothing here tracks — the
				// one condition an operator has to be able to find later.
				if (error.leftCredentialOrphaned) {
					logCompensationFailure(
						correlationId,
						error.compensation?.status ?? "unknown",
					);
				}

				// A spent, expired or forged code is the caller's problem; an
				// Apple outage or a broken client secret is ours. Reporting the
				// second as "invalid credentials" would be untrue and would
				// hide the incident.
				const credentialFailure =
					error.failure === "invalidGrant" ||
					error.failure === "subjectMismatch";
				return reject(
					c,
					correlationId,
					`exchange_${error.failure}`,
					credentialFailure ? 401 : 503,
				);
			}
			if (error instanceof NonceStoreUnavailableError) {
				// The store being down says nothing about the credential.
				return reject(c, correlationId, "nonce_store_unavailable", 503);
			}
			if (error instanceof AccountUnavailableError) {
				// Same answer as a bad token: whether an account exists and is
				// being deleted is not the client's to learn.
				return reject(c, correlationId, "account_unavailable", 401);
			}
			throw error;
		}
	};
}

/**
 * Records that a compensating revoke did not confirm.
 *
 * This is the one condition an operator has to be able to find after the
 * fact: a refresh token Apple may still honour, which nothing on this side
 * holds — so it cannot be revoked at account deletion and cannot be seen in
 * any table. A fixed code and a correlation id are enough to locate the
 * request; nothing that identifies the user or the credential is included.
 *
 * Deliberately absent: the refresh token, the authorization code, the
 * identity token, the exchanged id_token, the Apple subject, the client
 * secret, and Apple's raw response body.
 */
function logCompensationFailure(correlationId: string, outcome: string): void {
	console.error(
		JSON.stringify({
			event: "apple_auth_compensation_revoke_failed",
			outcome,
			correlationId,
		}),
	);
}

/** Logs a short code and answers without it. */
function reject(
	c: Context<{ Bindings: ApiEnv }>,
	correlationId: string,
	reason: string,
	status: 400 | 401 | 503,
) {
	console.warn(
		JSON.stringify({
			event: "apple_auth_rejected",
			reason,
			correlationId,
			// Deliberately absent: token, nonce, subject, email, user id.
		}),
	);
	const body =
		status === 400
			? { code: "malformed_request", message: "Malformed request" }
			: status === 503
				? { code: "service_unavailable", message: "Try again shortly" }
				: { code: "invalid_credentials", message: "Could not sign in" };
	return c.json({ error: { ...body, correlationId } }, status);
}

async function readJson(c: Context<{ Bindings: ApiEnv }>): Promise<unknown> {
	try {
		return await c.req.json();
	} catch {
		return null;
	}
}
