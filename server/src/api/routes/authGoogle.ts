/**
 * `POST /v1/auth/google`
 *
 * Trades a verified Google ID token for a PulseCue session. The client sends
 * what Google gave it; it does not get to say who it is. `userID`, `email`,
 * `displayName` and any other profile field from `GIDGoogleUser` are not part
 * of the request schema at all — the account is keyed on the `sub` of a
 * signature-verified token.
 *
 * Every failure answers the same way — `401 invalid_credentials`, no detail.
 * Which check failed (bad signature, wrong audience, expired, unknown
 * account, account being deleted) is exactly what an attacker would iterate
 * against, and distinguishing "no such account" from "wrong token" is an
 * enumeration oracle. The reason is logged as a short code with a correlation
 * id instead. Google's key service being unreachable is a `503`: an outage
 * must not be reported as a bad credential.
 */

import type { Context } from "hono";
import { z } from "zod";
import {
	AccountUnavailableError,
	findOrCreateAccountForIdentity,
} from "../db/accounts";
import { newId } from "../db/ids";
import { createSession } from "../db/sessions";
import { GoogleTokenInvalidError, verifyGoogleIdToken } from "../auth/google";
import { JwksFetchError, type JwksProvider } from "../auth/jwks";
import { JwtMalformedError, JwtSignatureError } from "../auth/jwt";
import type { ApiEnv } from "../types";

const requestSchema = z.object({
	idToken: z.string().min(1).max(8192),
	/** Optional label for a future "signed-in devices" screen. */
	deviceName: z.string().min(1).max(120).optional(),
});

export interface GoogleAuthDependencies {
	jwks: JwksProvider;
	/**
	 * The PulseCue **Web application (server) OAuth client id** — the value
	 * the iOS app sets as `GIDServerClientID`, which is what Google puts in
	 * `aud`. Not the iOS client id. Empty means "refuse", not "any".
	 */
	audience: string;
	now?: () => number;
}

export function makeGoogleAuthHandler(deps: GoogleAuthDependencies) {
	return async (c: Context<{ Bindings: ApiEnv }>) => {
		const correlationId = newId();
		const now = deps.now?.() ?? Math.floor(Date.now() / 1000);

		const parsed = requestSchema.safeParse(await readJson(c));
		if (!parsed.success) {
			return reject(c, correlationId, "malformed_request", 400);
		}

		let verified: Awaited<ReturnType<typeof verifyGoogleIdToken>>;
		try {
			verified = await verifyGoogleIdToken({
				idToken: parsed.data.idToken,
				audience: deps.audience,
				jwks: deps.jwks,
				now,
			});
		} catch (error) {
			if (error instanceof JwksFetchError) {
				// Google being unreachable is our problem, not a bad credential.
				return reject(c, correlationId, "jwks_unavailable", 503);
			}
			if (
				error instanceof GoogleTokenInvalidError ||
				error instanceof JwtMalformedError ||
				error instanceof JwtSignatureError
			) {
				return reject(c, correlationId, "token_rejected", 401);
			}
			throw error;
		}

		try {
			// Matching is on (provider, subject) only. A Google identity whose
			// email happens to equal an existing Apple identity's is a
			// different account, deliberately: an address is not proof of
			// ownership, and merging on one is an account-takeover path.
			const account = await findOrCreateAccountForIdentity(
				c.env.DB,
				{
					provider: "google",
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
			event: "google_auth_rejected",
			reason,
			correlationId,
			// Deliberately absent: token, subject, email, user id.
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
