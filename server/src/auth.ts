import type { MiddlewareHandler } from "hono";

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
