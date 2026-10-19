/**
 * Abuse throttling on top of Cloudflare's Workers Rate Limiting bindings.
 *
 * **What this is not.** The binding is local to each Cloudflare location,
 * eventually consistent, and permissive by design — Cloudflare documents it
 * as "not an accurate accounting system". It blunts floods; it does not
 * enforce a quota. Per-user storage limits are a separate control.
 *
 * Two kinds of key, never mixed:
 *
 * - **Before authentication**, only `CF-Connecting-IP`. Cloudflare sets it at
 *   the edge; `X-Forwarded-For` and friends are client-written and are never
 *   read as a fallback, or a caller could pick a fresh identity per request.
 * - **After `requireSession`**, only the internal user UUID it put on the
 *   context. Never a provider subject or an email: those are personal data,
 *   and the UUID is already the identity everything else is keyed by.
 *
 * Each limiter is its own binding with its own `namespace_id`, so a key only
 * ever counts against the limit it was meant for; the key itself needs no
 * prefix.
 *
 * **Fail closed.** A missing binding, a throw, or an answer that is not a
 * boolean `success` is refused with 503, not waved through. This is a
 * security control; degrading it into unlimited access when it misbehaves
 * would make the failure invisible exactly when it matters.
 *
 * Nothing about the caller — IP, user id, token, key — reaches the response
 * or the log. Only a correlation id and a coarse route class do.
 */

import type { Context, MiddlewareHandler } from "hono";
import { newId } from "../db/ids";
import type { ApiEnv, AuthedEnv } from "../types";

export type RateLimitBinding =
	| "API_IP_RATE_LIMITER"
	| "AUTH_IP_RATE_LIMITER"
	| "SYNC_USER_RATE_LIMITER"
	| "ACCOUNT_USER_RATE_LIMITER";

export function limitByIp(
	binding: "API_IP_RATE_LIMITER" | "AUTH_IP_RATE_LIMITER",
	routeClass: string,
): MiddlewareHandler<AuthedEnv> {
	return async (c, next) => {
		// Cloudflare's edge sets this on every request it serves, so its
		// absence is an infrastructure or config anomaly (e.g. the "Remove
		// visitor IP headers" transform), not a client state. Refuse rather
		// than skip the limiter (a bypass) or pool such requests into one
		// shared bucket (one actor could then 429 everyone). No other header
		// stands in for it: those are client-written.
		const ip = c.req.header("cf-connecting-ip")?.trim();
		if (!ip) return refuse(c, "limiter_failed", routeClass);
		const outcome = await consume(c.env, binding, ip);
		if (outcome !== "allowed") return refuse(c, outcome, routeClass);
		await next();
		return undefined;
	};
}

/** Must be mounted after `requireSession`; refuses (503) if it is not. */
export function limitByUser(
	binding: "SYNC_USER_RATE_LIMITER" | "ACCOUNT_USER_RATE_LIMITER",
	routeClass: string,
): MiddlewareHandler<AuthedEnv> {
	return async (c, next) => {
		const userId = c.get("user")?.id;
		if (!userId) return refuse(c, "limiter_failed", routeClass);
		const outcome = await consume(c.env, binding, userId);
		if (outcome !== "allowed") return refuse(c, outcome, routeClass);
		await next();
		return undefined;
	};
}

type Outcome = "allowed" | "rate_limited" | "limiter_failed";

async function consume(
	env: ApiEnv,
	binding: RateLimitBinding,
	key: string,
): Promise<Outcome> {
	const limiter = env[binding];
	if (typeof limiter?.limit !== "function") return "limiter_failed";
	let result: unknown;
	try {
		result = await limiter.limit({ key });
	} catch {
		return "limiter_failed";
	}
	const success = (result as { success?: unknown } | null)?.success;
	if (success === true) return "allowed";
	if (success === false) return "rate_limited";
	return "limiter_failed";
}

function refuse(
	c: Context<AuthedEnv>,
	outcome: Exclude<Outcome, "allowed">,
	routeClass: string,
) {
	const correlationId = newId();
	const limited = outcome === "rate_limited";
	const log = limited ? console.warn : console.error;
	log(
		JSON.stringify({
			event: limited ? "rate_limited" : "rate_limiter_failed",
			correlationId,
			routeClass,
			// Deliberately absent: the IP, the user id, the limiter key.
		}),
	);
	return limited
		? c.json(
				{
					error: {
						code: "rate_limited",
						message: "Too many requests. Try again later.",
						correlationId,
					},
				},
				429,
			)
		: c.json(
				{
					error: {
						code: "service_unavailable",
						message: "Service temporarily unavailable",
						correlationId,
					},
				},
				503,
			);
}
