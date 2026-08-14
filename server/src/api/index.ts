/**
 * `pulsecue-api` — the account and sync Worker.
 *
 * Separate from `pulsecue-gym-machine-api` on purpose: that Worker is
 * machine-to-machine (a static import key, short-lived HMAC tokens, no
 * users), while this one owns accounts and per-user data. Sharing a router
 * would mix two incompatible authorization models.
 */

import { Hono } from "hono";
import { APPLE_JWKS_URL } from "./auth/apple";
import { RemoteJwksProvider } from "./auth/jwks";
import { newId } from "./db/ids";
import { makeAppleAuthHandler } from "./routes/authApple";
import type { ApiEnv } from "./types";

const app = new Hono<{ Bindings: ApiEnv }>();

/**
 * One provider per isolate, so Apple's key set is fetched once and reused
 * across requests instead of on every sign-in.
 */
const appleJwks = new RemoteJwksProvider({ url: APPLE_JWKS_URL });

app.get("/health", (c) => c.json({ status: "ok", service: "pulsecue-api" }));

app.post("/v1/auth/apple", (c) =>
	makeAppleAuthHandler({
		jwks: appleJwks,
		// Empty when unconfigured; verification rejects that rather than
		// treating it as "any audience".
		audience: c.env.APPLE_AUDIENCE ?? "",
	})(c),
);

app.notFound((c) =>
	c.json({ error: { code: "not_found", message: "Route not found" } }, 404),
);

app.onError((_err, c) => {
	// Nothing derived from the error reaches the log.
	//
	// Repository errors quote the values they failed on — a user id, a
	// provider subject, a bound SQL parameter — and a driver error can quote
	// a whole statement. Observability is enabled on this Worker, so logging
	// `err.message` would publish exactly the identifiers this service exists
	// to protect. A correlation id is emitted instead: it ties a user's
	// report to a request without describing anything about them, and the
	// same id is returned so support can ask for it.
	const correlationId = newId();
	console.error(
		JSON.stringify({
			event: "unhandled_error",
			code: "internal_error",
			correlationId,
			path: new URL(c.req.url).pathname,
			method: c.req.method,
		}),
	);
	return c.json(
		{
			error: {
				code: "internal_error",
				message: "Internal error",
				correlationId,
			},
		},
		500,
	);
});

export default app;
