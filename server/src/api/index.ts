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
import { purgeReplayableNonces } from "./db/nonces";
import { purgeExpiredSessions } from "./db/sessions";
import {
	AUTH_BODY_LIMIT_BYTES,
	SYNC_UPLOAD_BODY_LIMIT_BYTES,
	limitBody,
} from "./middleware/bodyLimit";
import { limitByIp, limitByUser } from "./middleware/rateLimit";
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

/**
 * Rate limiters are mounted per route, not with `app.use("/v1/*")`: Hono
 * runs middleware in registration order, so a global one would run before
 * each route's body limit, and an oversized body would then spend tokens.
 * The order on every route is:
 *
 *   body limit → API IP limiter → (auth IP limiter | requireSession → user limiter) → handler
 *
 * The IP limiter sits ahead of `requireSession` so that a flood of invalid
 * bearers is cut off before any D1 lookup. It is the only throttle that can,
 * and it is shared by everyone behind one IP, hence the generous ceiling in
 * wrangler.api.jsonc.
 */
const apiIpLimit = () => limitByIp("API_IP_RATE_LIMITER", "api");

// Body limits come first on every route that parses a body, so an oversized
// request is refused before any D1 query, provider fetch, JSON parse, or
// rate-limit token.
app.post(
	"/v1/auth/apple",
	limitBody(AUTH_BODY_LIMIT_BYTES),
	apiIpLimit(),
	limitByIp("AUTH_IP_RATE_LIMITER", "auth"),
	(c) =>
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

app.post(
	"/v1/auth/google",
	limitBody(AUTH_BODY_LIMIT_BYTES),
	apiIpLimit(),
	limitByIp("AUTH_IP_RATE_LIMITER", "auth"),
	(c) =>
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
app.get("/v1/me", apiIpLimit(), requireSession(), handleGetMe);
app.post("/v1/auth/logout", apiIpLimit(), requireSession(), handleLogout);
app.post(
	"/v1/auth/logout-all",
	apiIpLimit(),
	requireSession(),
	limitByUser("ACCOUNT_USER_RATE_LIMITER", "account"),
	handleLogoutAll,
);
// The first sync slice. Not full multi-device sync — see the README.
app.post(
	"/v1/sync/workouts",
	limitBody(SYNC_UPLOAD_BODY_LIMIT_BYTES),
	apiIpLimit(),
	requireSession(),
	limitByUser("SYNC_USER_RATE_LIMITER", "sync"),
	makeUploadWorkoutsHandler(),
);
app.get("/v1/sync/workouts", apiIpLimit(), requireSession(), handlePullWorkouts);

// Shares the account limiter with logout-all: one budget for every
// account-wide mutation, so alternating between them buys nothing.
app.delete(
	"/v1/me",
	apiIpLimit(),
	requireSession(),
	limitByUser("ACCOUNT_USER_RATE_LIMITER", "account"),
	(c) =>
		makeDeleteMeHandler({
			// Null when Apple is unconfigured. Deletion then keeps the account in
			// `deleting` and retries, rather than reporting a revocation that
			// never happened.
			appleConfig: appleClientSecretConfigFromEnv(c.env),
			cipher: tokenCipherFromEnv(c.env),
		})(c),
);

// Registered after every route, so it runs only for a `/v1` request no route
// answered (a matched handler returns without calling `next`). Unknown paths
// stay inside the coarse shield without double-counting known ones.
app.use("/v1/*", apiIpLimit());

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
 * One step of a scheduled run, isolated from the others.
 *
 * Returns whether it succeeded instead of throwing, so a failing step can
 * never skip the steps after it. Only the fixed `category` and the run id
 * are logged on failure — never the original error, whose message may quote
 * ids or SQL.
 */
async function runScheduledStep(
	category: string,
	runId: string,
	step: () => Promise<Record<string, number>>,
): Promise<boolean> {
	let counts: Record<string, number>;
	try {
		counts = await step();
	} catch {
		console.error(
			JSON.stringify({
				event: `${category}_run_failed`,
				category,
				runId,
				code: "internal_error",
			}),
		);
		return false;
	}
	console.log(JSON.stringify({ event: `${category}_run`, category, runId, ...counts }));
	return true;
}

/**
 * Cron-triggered maintenance: retries account deletions a provider blocked,
 * then sweeps auth state no request can use any more.
 *
 * Without the retry, an account whose Apple revocation failed once would
 * stay `deleting` forever. Its dependencies are built exactly as the DELETE
 * route builds them, and the account deletion service stays the only
 * business logic.
 *
 * The three steps are independent: each runs even if an earlier one failed,
 * because a D1 hiccup in a sweep must not strand a deletion, nor the reverse.
 * Each sweep is bounded, so a backlog carries over to the next run. If any
 * step failed, a fixed error is thrown after all have run, so the Cron run is
 * marked failed without publishing anything about a user. This runs as its
 * own invocation and cannot affect `fetch`.
 */
async function scheduled(
	controller: ScheduledController,
	env: ApiEnv,
	_ctx: ExecutionContext,
): Promise<void> {
	const now = Math.floor(controller.scheduledTime / 1000);
	const runId = newId();

	const results = [
		await runScheduledStep("account_deletion_retry", runId, () =>
			processDueAccountDeletions(
				{
					db: env.DB,
					appleConfig: appleClientSecretConfigFromEnv(env),
					cipher: tokenCipherFromEnv(env),
				},
				now,
			),
		),
		await runScheduledStep("auth_nonce_cleanup", runId, async () => ({
			deleted: await purgeReplayableNonces(env.DB, now),
		})),
		await runScheduledStep("auth_session_cleanup", runId, async () => ({
			deleted: await purgeExpiredSessions(env.DB, now),
		})),
	];
	if (results.includes(false)) throw new Error("scheduled run failed");
}

export default {
	fetch: app.fetch,
	scheduled,
} satisfies ExportedHandler<ApiEnv>;
