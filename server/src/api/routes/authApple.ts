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
import { NonceAlreadyUsedError, consumeNonce } from "../db/nonces";
import { createSession } from "../db/sessions";
import { AppleTokenInvalidError, verifyAppleIdentityToken } from "../auth/apple";
import { JwksFetchError, type JwksProvider } from "../auth/jwks";
import { JwtMalformedError, JwtSignatureError } from "../auth/jwt";
import type { ApiEnv } from "../types";

const requestSchema = z.object({
	identityToken: z.string().min(1).max(8192),
	rawNonce: z.string().min(1).max(512),
	/** Optional label for a future "signed-in devices" screen. */
	deviceName: z.string().min(1).max(120).optional(),
});

export interface AppleAuthDependencies {
	jwks: JwksProvider;
	audience: string;
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

			const account = await findOrCreateAccountForIdentity(
				c.env.DB,
				{
					provider: "apple",
					subject: verified.subject,
					email: verified.email,
					emailVerified: verified.emailVerified,
				},
				now,
			);

			const issued = await createSession(c.env.DB, account.user.id, {
				deviceName: parsed.data.deviceName ?? null,
				now,
			});

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
			if (error instanceof AccountUnavailableError) {
				// Same answer as a bad token: whether an account exists and is
				// being deleted is not the client's to learn.
				return reject(c, correlationId, "account_unavailable", 401);
			}
			throw error;
		}
	};
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
