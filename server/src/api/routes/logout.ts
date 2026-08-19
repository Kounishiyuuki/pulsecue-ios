/**
 * `POST /v1/auth/logout` and `POST /v1/auth/logout-all`.
 *
 * **What is idempotent, and what is not.** The revocation *mutation* is:
 * revoking an already-revoked session changes nothing and keeps the original
 * `revoked_at`, so a repeated repository call cannot rewrite history. The
 * HTTP endpoint is a different question, and deliberately not exempt from
 * authentication — replaying the same bearer after a successful logout hits
 * the session middleware first, which no longer recognises that token and
 * normalises it to `401 invalid_session` like any other revoked credential.
 *
 * So: first call `200`, same raw token again `401`. That is the contract, and
 * it is the right one. Carving out an exception so a revoked bearer could
 * still reach this handler would turn logout into a route that accepts dead
 * credentials — a strictly worse trade for a status code the client does not
 * need, since the user is logged out either way.
 *
 * A client should therefore treat `401` from logout as success, not as
 * something to retry: the requested end state already holds.
 *
 * Logout revokes exactly the session that authenticated the request. Other
 * devices keep working; signing out of a phone must not sign out the iPad.
 * `logout-all` is the deliberate opposite, for "I lost a device".
 *
 * Revocation is a single UPDATE and takes effect on the very next request,
 * because sessions are stored rather than self-contained. That is the whole
 * reason for the opaque-token design.
 */

import type { Context } from "hono";
import {
	revokeAllSessionsForUser,
	revokeSession,
} from "../db/sessions";
import type { AuthedEnv } from "../types";

export async function handleLogout(c: Context<AuthedEnv>) {
	const session = c.get("session");
	const now = Math.floor(Date.now() / 1000);

	// Already-revoked sessions keep their original revocation time, so a
	// retry cannot rewrite history.
	await revokeSession(c.env.DB, session.id, now);

	return c.json({ ok: true });
}

export async function handleLogoutAll(c: Context<AuthedEnv>) {
	const user = c.get("user");
	const now = Math.floor(Date.now() / 1000);

	// Scoped to this user by the WHERE clause, and the user comes from the
	// authenticated session rather than from anything the caller sent — there
	// is no user id in the request to tamper with.
	await revokeAllSessionsForUser(c.env.DB, user.id, now);

	return c.json({ ok: true });
}
