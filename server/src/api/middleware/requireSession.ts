/**
 * Bearer authentication for everything that is not a sign-in route.
 *
 * The token is the opaque 256-bit value issued at sign-in. It is never stored
 * in plaintext, so authentication is: hash it, look the hash up, and let the
 * query decide. `findActiveSessionByToken` joins `users`, which means the
 * account's state is re-checked on **every** request — a session cannot
 * outlive the account even if a revocation were somehow missed.
 *
 * Fail closed, and fail identically. Missing header, malformed header,
 * unknown token, expired, revoked, and "account is being deleted" are five
 * different facts and one answer: `401 invalid_session`. Telling them apart
 * would let a caller probe which tokens ever existed, and would turn account
 * deletion into something observable from outside.
 *
 * The raw token never reaches a log. Only the correlation id does.
 */

import type { Context, MiddlewareHandler } from "hono";
import { newId } from "../db/ids";
import { findActiveSessionByToken } from "../db/sessions";
import { findUserById } from "../db/accounts";
import type { AuthedEnv } from "../types";

export type { AuthVariables, AuthedEnv } from "../types";

/**
 * Extracts a bearer token, or `null`.
 *
 * Deliberately strict: exactly one `Bearer` scheme, case-insensitive per RFC
 * 6750, one space, non-empty rest, no internal whitespace. A lenient parser
 * here is how a token ends up read from somewhere it was not meant to be.
 */
export function readBearerToken(header: string | undefined | null): string | null {
	if (!header) return null;
	const match = /^Bearer ([A-Za-z0-9._~+/-]+=*)$/i.exec(header.trim());
	return match?.[1] ?? null;
}

export function requireSession(options: { now?: () => number } = {}): MiddlewareHandler<AuthedEnv> {
	return async (c, next) => {
		const now = options.now?.() ?? Math.floor(Date.now() / 1000);

		const token = readBearerToken(c.req.header("authorization"));
		if (!token) return rejectSession(c, "missing_bearer");

		const session = await findActiveSessionByToken(c.env.DB, token, now);
		// One answer for unknown, expired, revoked, and deleting-account: the
		// query already collapsed them, and so does this.
		if (!session) return rejectSession(c, "session_not_active");

		const user = await findUserById(c.env.DB, session.user_id);
		if (!user || user.state !== "active") {
			// Belt and braces. The join above already covers this; if the two
			// ever disagree, the refusal wins.
			return rejectSession(c, "user_not_active");
		}

		c.set("session", session);
		c.set("user", user);
		await next();
		return undefined;
	};
}

function rejectSession(c: Context<AuthedEnv>, reason: string) {
	const correlationId = newId();
	console.warn(
		JSON.stringify({
			event: "session_rejected",
			reason,
			correlationId,
			// Deliberately absent: the token, its hash, the user id.
		}),
	);
	return c.json(
		{
			error: {
				code: "invalid_session",
				message: "Sign in again",
				correlationId,
			},
		},
		401,
	);
}
