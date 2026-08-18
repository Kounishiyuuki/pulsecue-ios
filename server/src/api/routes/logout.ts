/**
 * `POST /v1/auth/logout` and `POST /v1/auth/logout-all`.
 *
 * Both are **idempotent**, which matters more than it sounds: the iOS client
 * must be able to log out while the network is unreliable, and a retry that
 * errored would leave the user unable to complete the action. Calling logout
 * on an already-revoked session is a success — the requested end state is the
 * one that holds.
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
