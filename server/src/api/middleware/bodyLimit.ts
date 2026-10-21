/**
 * Byte ceilings on request bodies, enforced before anything reads them.
 *
 * The zod schemas bound every field, but only *after* `c.req.json()` has
 * buffered and parsed the whole body — so without this an oversized request
 * costs the full upload in memory and a JSON parse before it is refused.
 * Hono's `bodyLimit` checks `Content-Length` up front and, when there is
 * none, counts the stream and stops reading the moment the ceiling is passed.
 *
 * Mounted per route, ahead of `requireSession` where a route has one, so an
 * oversized body is refused without a single D1 query or provider fetch.
 * Routes that never read a body do not get it: wrapping them would buffer
 * bodies they would otherwise ignore.
 *
 * Hono's default `onError` throws an HTTPException, which `app.onError`
 * would report as a 500 `internal_error`; the handler below answers 413
 * itself. Nothing from the body is logged or echoed.
 */

import type { MiddlewareHandler } from "hono";
import { bodyLimit } from "hono/body-limit";
import { newId } from "../db/ids";
import type { AuthedEnv } from "../types";

/** The largest sign-in body the schemas accept is about 11 KB. */
export const AUTH_BODY_LIMIT_BYTES = 16 * 1024;

/** 500 rows at roughly 1.1 KB each in the worst case, with headroom. */
export const SYNC_UPLOAD_BODY_LIMIT_BYTES = 1024 * 1024;

export function limitBody(maxSize: number): MiddlewareHandler<AuthedEnv> {
	return bodyLimit({
		maxSize,
		onError: (c) => {
			const correlationId = newId();
			console.warn(
				JSON.stringify({
					event: "request_body_too_large",
					correlationId,
					path: c.req.routePath,
					// Deliberately absent: any part of the body.
				}),
			);
			return c.json(
				{
					error: {
						code: "payload_too_large",
						message: "Request body is too large",
						correlationId,
					},
				},
				413,
			);
		},
	});
}
