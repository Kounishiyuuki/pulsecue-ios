/**
 * `pulsecue-api` — the account and sync Worker.
 *
 * Separate from `pulsecue-gym-machine-api` on purpose: that Worker is
 * machine-to-machine (a static import key, short-lived HMAC tokens, no
 * users), while this one owns accounts and per-user data. Sharing a router
 * would mix two incompatible authorization models.
 */

import { Hono } from "hono";
import { createAppleJwksProvider } from "./auth/apple";
import { processDueAccountDeletions } from "./auth/accountDeletionService";
import { appleClientSecretConfigFromEnv } from "./auth/appleClientSecret";
import { createGoogleJwksProvider } from "./auth/google";
import { tokenCipherFromEnv } from "./crypto/tokenCipher";
import { newId } from "./db/ids";
import { type AuthedEnv, requireSession } from "./middleware/requireSession";
import { makeAppleAuthHandler } from "./routes/authApple";
import { makeGoogleAuthHandler } from "./routes/authGoogle";
import { makeDeleteMeHandler } from "./routes/deleteMe";
import { handleLogout, handleLogoutAll } from "./routes/logout";
import {
	handlePullWorkouts,
	makeUploadWorkoutsHandler,
} from "./routes/syncWorkouts";
import { handleGetMe } from "./routes/me";
import type { ApiEnv } from "./types";

const app = new Hono<AuthedEnv>();

/**
 * One provider per isolate per issuer, so each key set is fetched once and
 * reused across requests instead of on every sign-in. Each factory pins its
 * own endpoint, so there is no shared "JWKS client" a URL could be passed to.
 */
const appleJwks = createAppleJwksProvider();
const googleJwks = createGoogleJwksProvider();

app.get("/health", (c) => c.json({ status: "ok", service: "pulsecue-api" }));

app.post("/v1/auth/apple", (c) =>
	makeAppleAuthHandler({
		jwks: appleJwks,
		// Empty when unconfigured; verification rejects that rather than
		// treating it as "any audience".
		audience: c.env.APPLE_AUDIENCE ?? "",
		// Both null when Apple is not configured for this deployment, and the
		// handler then answers 503 rather than signing anyone in: an account
		// created without a stored refresh token could not be deleted the way
		// Apple requires, and the authorization code cannot be re-requested
		// later to repair it.
		clientSecret: appleClientSecretConfigFromEnv(c.env),
		cipher: tokenCipherFromEnv(c.env),
	})(c),
);

app.post("/v1/auth/google", (c) =>
	makeGoogleAuthHandler({
		jwks: googleJwks,
		// Same fail-closed rule as Apple: unset means no one signs in.
		audience: c.env.GOOGLE_AUDIENCE ?? "",
	})(c),
);

/**
 * Everything below requires a session.
 *
 * The middleware is attached per route rather than globally. A global guard
 * that a future sign-in route silently inherits locks users out; one a future
 * authenticated route silently misses is caught by that route's own tests.
 * The second failure is the recoverable one.
 */
app.get("/v1/me", requireSession(), handleGetMe);
app.post("/v1/auth/logout", requireSession(), handleLogout);
app.post("/v1/auth/logout-all", requireSession(), handleLogoutAll);
// The first sync slice. Not full multi-device sync — see the README.
app.post("/v1/sync/workouts", requireSession(), makeUploadWorkoutsHandler());
app.get("/v1/sync/workouts", requireSession(), handlePullWorkouts);

app.delete("/v1/me", requireSession(), (c) =>
	makeDeleteMeHandler({
		// Null when Apple is unconfigured. Deletion then keeps the account in
		// `deleting` and retries, rather than reporting a revocation that
		// never happened.
		appleConfig: appleClientSecretConfigFromEnv(c.env),
		cipher: tokenCipherFromEnv(c.env),
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

/**
 * Cron-triggered retry of account deletions a provider blocked.
 *
 * Without a caller, an account whose Apple revocation failed once would stay
 * `deleting` forever. The dependencies are built exactly as the DELETE route
 * builds them, and the account deletion service stays the only business
 * logic.
 *
 * Only aggregate counts are logged. On an unexpected failure a fixed error is
 * rethrown — not the original, whose message may quote ids or SQL — so the
 * Cron run is marked failed without publishing anything about a user. This
 * runs as its own invocation and cannot affect `fetch`.
 */
async function scheduled(
	controller: ScheduledController,
	env: ApiEnv,
	_ctx: ExecutionContext,
): Promise<void> {
	let result: Awaited<ReturnType<typeof processDueAccountDeletions>>;
	try {
		result = await processDueAccountDeletions(
			{
				db: env.DB,
				appleConfig: appleClientSecretConfigFromEnv(env),
				cipher: tokenCipherFromEnv(env),
			},
			Math.floor(controller.scheduledTime / 1000),
		);
	} catch {
		console.error(
			JSON.stringify({
				event: "account_deletion_retry_run_failed",
				code: "internal_error",
			}),
		);
		throw new Error("account deletion retry run failed");
	}
	console.log(JSON.stringify({ event: "account_deletion_retry_run", ...result }));
}

export default {
	fetch: app.fetch,
	scheduled,
} satisfies ExportedHandler<ApiEnv>;
