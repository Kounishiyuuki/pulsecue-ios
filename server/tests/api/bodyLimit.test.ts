/**
 * Request body ceilings, exercised through the real Worker router.
 *
 * Built on the exported `fetch` rather than a hand-assembled Hono app, so the
 * assertions are about the middleware order production actually mounts: an
 * oversized body must be refused before the session lookup, the provider
 * fetch, or the JSON parse — not merely refused eventually.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../../src/api/index";
import { findOrCreateAccountForIdentity } from "../../src/api/db/accounts";
import { createSession } from "../../src/api/db/sessions";
import {
	AUTH_BODY_LIMIT_BYTES,
	SYNC_UPLOAD_BODY_LIMIT_BYTES,
} from "../../src/api/middleware/bodyLimit";
import type { ApiEnv } from "../../src/api/types";
import { type FakeRateLimiters, fakeRateLimiters } from "./support/rateLimiters";
import { type TestDatabase, createTestDatabase } from "./support/sqliteD1";

const ROUTES = [
	{ path: "/v1/auth/apple", limit: AUTH_BODY_LIMIT_BYTES },
	{ path: "/v1/auth/google", limit: AUTH_BODY_LIMIT_BYTES },
	{ path: "/v1/sync/workouts", limit: SYNC_UPLOAD_BODY_LIMIT_BYTES },
] as const;

/** Valid JSON of exactly `bytes` bytes: an object padded with spaces. */
function jsonOfSize(bytes: number, value: object = {}): string {
	const base = JSON.stringify(value);
	return base.slice(0, -1) + " ".repeat(bytes - base.length) + "}";
}

/**
 * A body with no `Content-Length`, served in 1 KiB chunks on demand. Counts
 * how many chunks were pulled so a test can show reading stopped early.
 */
function chunkedBody(totalBytes: number) {
	const chunk = new TextEncoder().encode(" ".repeat(1024));
	let pulled = 0;
	const stream = new ReadableStream<Uint8Array>({
		pull(controller) {
			if (pulled * chunk.length >= totalBytes) {
				controller.close();
				return;
			}
			pulled += 1;
			controller.enqueue(chunk);
		},
	});
	return { stream, pulled: () => pulled };
}

let db: TestDatabase;
let fetchSpy: ReturnType<typeof vi.fn>;
let parseSpy: ReturnType<typeof vi.spyOn>;
let token: string;
let limiters: FakeRateLimiters;

function env(): ApiEnv {
	// Configured audiences, so a request that got past the limiter would go
	// on to verify a token — the path whose provider fetch must not happen.
	return {
		DB: db as unknown as D1Database,
		...limiters.bindings,
		APPLE_AUDIENCE: "com.example.pulsecue",
		GOOGLE_AUDIENCE: "server-client-id.apps.googleusercontent.com",
	};
}

function send(path: string, init: RequestInit & { duplex?: "half" }) {
	return worker.fetch(
		new Request(`https://api.test${path}`, {
			method: "POST",
			...init,
			headers: {
				authorization: `Bearer ${token}`,
				"content-type": "application/json",
				// Set by Cloudflare's edge; without it the limiter refuses.
				"cf-connecting-ip": "203.0.113.1",
				...(init.headers as Record<string, string> | undefined),
			},
		}),
		env(),
		{} as ExecutionContext,
	);
}

beforeEach(async () => {
	db = await createTestDatabase();
	const account = await findOrCreateAccountForIdentity(
		db,
		{ provider: "apple", subject: "body-limit-sub" },
		Math.floor(Date.now() / 1000),
	);
	token = (await createSession(db, account.user.id)).token;
	db.resetRecording();
	limiters = fakeRateLimiters();
	fetchSpy = vi.fn(async () => new Response("unexpected", { status: 500 }));
	vi.stubGlobal("fetch", fetchSpy);
	// Hono's `c.req.json()` is `raw.text()` then `JSON.parse`, so a read
	// through `text` is the parse path.
	parseSpy = vi.spyOn(Request.prototype, "text");
	vi.spyOn(console, "warn").mockImplementation(() => {});
});

afterEach(() => {
	vi.restoreAllMocks();
	vi.unstubAllGlobals();
	db.close();
});

async function expectRefused(res: Response) {
	expect(res.status).toBe(413);
	const body = (await res.json()) as { error: Record<string, unknown> };
	expect(Object.keys(body.error).sort()).toEqual([
		"code",
		"correlationId",
		"message",
	]);
	expect(body.error.code).toBe("payload_too_large");
	// The request body was never handed to the parser.
	expect(parseSpy).not.toHaveBeenCalled();
	expect(db.recorded()).toHaveLength(0);
	expect(fetchSpy).not.toHaveBeenCalled();
	// Refused before any rate limiter spent a token.
	expect(limiters.calls).toHaveLength(0);
}

describe.each(ROUTES)("$path body limit", ({ path, limit }) => {
	it("refuses Content-Length one byte over the limit", async () => {
		await expectRefused(await send(path, { body: jsonOfSize(limit + 1) }));
	});

	it("refuses a declared Content-Length over the limit without reading", async () => {
		const { stream, pulled } = chunkedBody(limit * 4);
		const res = await send(path, {
			body: stream,
			duplex: "half",
			headers: { "content-length": String(limit * 4) },
		});
		await expectRefused(res);
		expect(pulled()).toBeLessThanOrEqual(1);
	});

	it("refuses a stream without Content-Length once it passes the limit", async () => {
		const { stream, pulled } = chunkedBody(limit * 4);
		const res = await send(path, { body: stream, duplex: "half" });
		await expectRefused(res);
		// Stopped at the first chunk past the limit (plus the stream's one
		// chunk of read-ahead), not at the end of a body four times larger.
		expect(pulled()).toBeLessThanOrEqual(Math.floor(limit / 1024) + 2);
	});

	it("passes a body of exactly the limit through to the handler", async () => {
		const res = await send(path, {
			body: jsonOfSize(limit, { sessions: [], stepResults: [] }),
		});
		expect(res.status).not.toBe(413);
		expect(parseSpy).toHaveBeenCalledTimes(1);
	});

	it("passes a stream of exactly the limit through to the handler", async () => {
		const { stream } = chunkedBody(limit);
		const res = await send(path, { body: stream, duplex: "half" });
		expect(res.status).not.toBe(413);
		// Whitespace only: buffered, re-streamed, and parsed (and rejected)
		// by the handler rather than the limiter.
		expect(parseSpy).toHaveBeenCalledTimes(1);
	});
});

describe("sync upload at the limit", () => {
	it("is accepted end to end", async () => {
		const res = await send("/v1/sync/workouts", {
			body: jsonOfSize(SYNC_UPLOAD_BODY_LIMIT_BYTES, {
				sessions: [],
				stepResults: [],
			}),
		});
		expect(res.status).toBe(200);
	});
});

describe("routes that do not read a body", () => {
	it.each([
		["GET", "/v1/me"],
		["GET", "/v1/sync/workouts"],
		["DELETE", "/v1/me"],
		["POST", "/v1/auth/logout"],
		["POST", "/v1/auth/logout-all"],
	])("%s %s is not body-limited", async (method, path) => {
		const res = await worker.fetch(
			new Request(`https://api.test${path}`, {
				method,
				headers: {
					"content-length": String(64 * 1024 * 1024),
					"cf-connecting-ip": "203.0.113.1",
				},
			}),
			env(),
			{} as ExecutionContext,
		);
		// No bearer: the session middleware answers, not a limiter.
		expect(res.status).toBe(401);
	});
});
