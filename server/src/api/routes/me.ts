/**
 * `GET /v1/me` — who the caller is, as far as they need to know.
 *
 * The response is an **allowlist**, not a row. `SELECT *` reaching a client
 * is how a schema change quietly becomes a disclosure, so every field is
 * named here and the shape is pinned by a test.
 *
 * Deliberately absent:
 *
 *   provider subject — the stable Apple/Google identifier. It is the account
 *     key; nothing the client does needs it, and echoing it back turns a
 *     stolen session into a correlatable identity across services.
 *   email — the app has no use for it today. Apple's private relay address
 *     in particular is not something to surface without a reason.
 *   the session token hash, and any provider credential material.
 *
 * `linkedProviders` is which providers are attached, and when — enough for a
 * settings screen to say "Apple, connected" without naming the subject.
 */

import type { Context } from "hono";
import { listIdentities } from "../db/accounts";
import type { AuthedEnv } from "../types";
import type { UserProfileRow } from "../types";

export async function handleGetMe(c: Context<AuthedEnv>) {
	const user = c.get("user");
	const session = c.get("session");

	const profile = await c.env.DB.prepare(
		`SELECT display_name FROM user_profiles WHERE user_id = ?`,
	)
		.bind(user.id)
		.first<Pick<UserProfileRow, "display_name">>();

	const identities = await listIdentities(c.env.DB, user.id);

	return c.json({
		user: {
			id: user.id,
			state: user.state,
			displayName: profile?.display_name ?? null,
			createdAt: user.created_at,
		},
		linkedProviders: identities.map((identity) => ({
			provider: identity.provider,
			linkedAt: identity.created_at,
			// Not the subject, and not the email.
		})),
		session: {
			// The caller's own session expiry, so the app can prompt a
			// re-sign-in before it lapses rather than discovering it mid-use.
			expiresAt: session.expires_at,
		},
	});
}
