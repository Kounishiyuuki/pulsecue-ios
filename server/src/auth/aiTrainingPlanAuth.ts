import type { Context, MiddlewareHandler } from "hono";
import { extractBearerToken, timingSafeEqual } from "../auth";

//
//  aiTrainingPlanAuth.ts
//  server
//
//  MOCK-ONLY auth gate for `POST /api/ai/training-plan`. Implements the
//  auth contract documented in `Docs/ai-training-plan-proxy-endpoint-spec.md`
//  §4 — but only against **fake, local/test-only** tokens supplied via env.
//
//  Boundaries (locked for this PR):
//   - **Opt-in.** Active only when `AI_TRAINING_PLAN_AUTH_MODE === "mock"`.
//     Any other value (or unset) is a pass-through, so the current ungated
//     DEBUG loopback QA behavior is unchanged by default.
//   - **No real auth.** No token issuer, no JWT, no signature verification,
//     no provider key. Tokens are compared (constant-time) against fake
//     values that exist only in tests or a local `.dev.vars`.
//   - **Tokens are app→backend only.** They are never forwarded to any
//     provider (there is no provider here) and never logged.
//   - Auth failures return the §4.3 envelope `{ error: { code, message,
//     requestId } }` and run **before** any plan generation, so no body is
//     read or echoed on the auth-failure path.
//

/** Normalized `"mock"` check for the opt-in switch. */
function isMockAuthMode(mode: string | undefined): boolean {
	return typeof mode === "string" && mode.trim().toLowerCase() === "mock";
}

/** A safe, non-sensitive correlation id for an auth-error response. */
function newRequestId(): string {
	return crypto.randomUUID();
}

function authError(
	c: Context<{ Bindings: Env }>,
	status: 401 | 403,
	code: string,
	message: string,
): Response {
	// Fixed strings only — never the token, Authorization header, or body.
	return c.json({ error: { code, message, requestId: newRequestId() } }, status);
}

/** True only when `configured` is a non-empty string equal to `provided`. */
function matchesConfiguredToken(
	provided: string,
	configured: string | undefined,
): boolean {
	return (
		typeof configured === "string" &&
		configured.length > 0 &&
		timingSafeEqual(provided, configured)
	);
}

/**
 * Mock-auth middleware for the AI training-plan route.
 *
 * Pass-through unless `AI_TRAINING_PLAN_AUTH_MODE === "mock"`. In mock
 * mode it requires `Authorization: Bearer <token>` and maps the token to
 * the §4.4 outcomes:
 *   - missing / malformed / empty / unknown token → 401 `unauthorized`
 *   - `AI_TRAINING_PLAN_MOCK_EXPIRED_TOKEN`       → 401 `token_expired`
 *   - `AI_TRAINING_PLAN_MOCK_WRONG_SCOPE_TOKEN`   → 403 `invalid_scope`
 *   - `AI_TRAINING_PLAN_MOCK_VALID_TOKEN`         → continue (next)
 *
 * Fail-closed: if mock mode is on but no valid token is configured, every
 * request is rejected. Token values are never logged.
 */
export const requireAiTrainingPlanMockAuth: MiddlewareHandler<{ Bindings: Env }> = async (
	c,
	next,
) => {
	if (!isMockAuthMode(c.env.AI_TRAINING_PLAN_AUTH_MODE)) {
		await next();
		return undefined;
	}

	// Covers missing header, non-Bearer header, and empty bearer token.
	const provided = extractBearerToken(c.req.header("Authorization"));
	if (provided === null) {
		return authError(c, 401, "unauthorized", "A valid token is required");
	}

	if (matchesConfiguredToken(provided, c.env.AI_TRAINING_PLAN_MOCK_VALID_TOKEN)) {
		await next();
		return undefined;
	}
	if (matchesConfiguredToken(provided, c.env.AI_TRAINING_PLAN_MOCK_EXPIRED_TOKEN)) {
		return authError(c, 401, "token_expired", "The token has expired");
	}
	if (matchesConfiguredToken(provided, c.env.AI_TRAINING_PLAN_MOCK_WRONG_SCOPE_TOKEN)) {
		return authError(
			c,
			403,
			"invalid_scope",
			"The token is missing the required scope",
		);
	}

	return authError(c, 401, "unauthorized", "A valid token is required");
};
