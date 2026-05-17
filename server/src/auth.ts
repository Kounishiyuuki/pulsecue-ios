import type { MiddlewareHandler } from "hono";
import { verifyImportToken } from "./auth/tokens";

/**
 * Hono middleware that gates a route behind the import API key.
 *
 * The caller must send `Authorization: Bearer <key>` where `<key>`
 * matches the `PULSECUE_IMPORT_API_KEY` Worker secret. Any failure —
 * missing secret, missing header, malformed header, or wrong key —
 * yields a uniform 401 envelope. Fails closed: if the secret is not
 * configured, every request is rejected.
 */
export const requireImportApiKey: MiddlewareHandler<{ Bindings: Env }> = async (
	c,
	next,
) => {
	const expected = c.env.PULSECUE_IMPORT_API_KEY;
	const provided = extractBearerToken(c.req.header("Authorization"));

	if (
		typeof expected !== "string" ||
		expected.length === 0 ||
		provided === null ||
		!timingSafeEqual(provided, expected)
	) {
		return c.json(
			{
				error: {
					code: "unauthorized",
					message: "A valid API key is required",
				},
			},
			401,
		);
	}

	await next();
	return undefined;
};

/**
 * Hono middleware that gates a route behind **either** the long-lived
 * `PULSECUE_IMPORT_API_KEY` bearer token **or** a valid short-lived
 * import token signed by `PULSECUE_IMPORT_TOKEN_SECRET`.
 *
 * Evaluation order (deliberate): the long-lived API key is checked
 * first, so existing server/admin/dev callers experience zero change.
 * If the supplied bearer doesn't match the API key, the middleware
 * falls back to short-lived token verification. Either path success
 * proceeds; otherwise the same 401 envelope used by the API-key-only
 * middleware is returned. Token values are never logged.
 *
 * Fail-closed behavior:
 *   - missing Authorization header             → 401
 *   - malformed Authorization header           → 401
 *   - bearer matches no key and no token       → 401
 *   - `PULSECUE_IMPORT_TOKEN_SECRET` unset:
 *       - API-key match still succeeds (long-lived path unchanged)
 *       - short-lived token fails verification → 401
 */
export const requireImportAuthorization: MiddlewareHandler<{ Bindings: Env }> = async (
	c,
	next,
) => {
	const provided = extractBearerToken(c.req.header("Authorization"));
	if (provided === null) return unauthorizedResponse(c);

	// 1. Long-lived API key (kept identical to PR #18 semantics).
	const apiKey = c.env.PULSECUE_IMPORT_API_KEY;
	if (
		typeof apiKey === "string" &&
		apiKey.length > 0 &&
		timingSafeEqual(provided, apiKey)
	) {
		await next();
		return undefined;
	}

	// 2. Short-lived token (only when the signing secret is configured).
	const tokenSecret = c.env.PULSECUE_IMPORT_TOKEN_SECRET;
	if (typeof tokenSecret === "string" && tokenSecret.length > 0) {
		const verified = await verifyImportToken(provided, tokenSecret);
		if (verified !== null) {
			await next();
			return undefined;
		}
	}

	return unauthorizedResponse(c);
};

function unauthorizedResponse(c: Parameters<MiddlewareHandler<{ Bindings: Env }>>[0]) {
	return c.json(
		{
			error: {
				code: "unauthorized",
				message: "A valid API key is required",
			},
		},
		401,
	);
}

/**
 * Returns the token from an `Authorization: Bearer <token>` header, or
 * `null` if the header is absent or not a well-formed bearer header.
 */
export function extractBearerToken(headerValue: string | undefined): string | null {
	if (!headerValue) return null;
	const match = /^Bearer[ ]+(\S.*)$/i.exec(headerValue.trim());
	if (!match) return null;
	const token = match[1]?.trim();
	return token && token.length > 0 ? token : null;
}

/**
 * Constant-time string comparison. Workers does not expose
 * `crypto.timingSafeEqual`, so this compares UTF-8 bytes with a fixed
 * number of operations regardless of where the first difference is.
 */
function timingSafeEqual(a: string, b: string): boolean {
	const encoder = new TextEncoder();
	const aBytes = encoder.encode(a);
	const bBytes = encoder.encode(b);
	const length = Math.max(aBytes.length, bBytes.length);
	let mismatch = aBytes.length ^ bBytes.length;
	for (let i = 0; i < length; i += 1) {
		mismatch |= (aBytes[i] ?? 0) ^ (bBytes[i] ?? 0);
	}
	return mismatch === 0;
}
