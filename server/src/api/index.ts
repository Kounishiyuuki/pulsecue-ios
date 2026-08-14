/**
 * `pulsecue-api` — the account and sync Worker.
 *
 * Separate from `pulsecue-gym-machine-api` on purpose: that Worker is
 * machine-to-machine (a static import key, short-lived HMAC tokens, no
 * users), while this one owns accounts and per-user data. Sharing a router
 * would mix two incompatible authorization models.
 *
 * This PR lays the foundation only: the D1 schema and the repository layer.
 * There is deliberately no auth endpoint yet — Apple and Google token
 * verification land in their own PRs, so nothing here can be mistaken for a
 * usable sign-in.
 */

import { Hono } from "hono";
import type { ApiEnv } from "./types";

const app = new Hono<{ Bindings: ApiEnv }>();

app.get("/health", (c) => c.json({ status: "ok", service: "pulsecue-api" }));

app.notFound((c) =>
	c.json({ error: { code: "not_found", message: "Route not found" } }, 404),
);

app.onError((err, c) => {
	// Message only: never the request body, headers, or any bound value, so
	// a token or email can't reach the log.
	console.error("unhandled_error", err instanceof Error ? err.message : "unknown");
	return c.json(
		{ error: { code: "internal_error", message: "Internal error" } },
		500,
	);
});

export default app;
