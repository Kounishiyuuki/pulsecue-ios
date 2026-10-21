/**
 * The API Worker's `app.onError`, exercised through the real router.
 *
 * An unexpected exception must leave as a fixed 500 `internal_error` with a
 * correlation id, and the log must carry that id but nothing from the error:
 * repository errors quote user ids, tokens and SQL. A D1 failure inside
 * `requireSession` on GET /v1/me reaches the handler without any test-only
 * route.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../../src/api/index";
import type { ApiEnv } from "../../src/api/types";
import { fakeRateLimiters } from "./support/rateLimiters";

const SECRETS = ["SECRET-DB-DETAIL", "private-user", "private-token", "private-sql"];
const DB_ERROR = "SECRET-DB-DETAIL user=private-user token=private-token SQL=private-sql";

/** A D1 double whose every query fails with an error quoting secrets. */
function failingDb(): D1Database {
	const statement = {
		bind: () => statement,
		first: async () => {
			throw new Error(DB_ERROR);
		},
		all: async () => {
			throw new Error(DB_ERROR);
		},
		run: async () => {
			throw new Error(DB_ERROR);
		},
		raw: async () => {
			throw new Error(DB_ERROR);
		},
	};
	return { prepare: () => statement } as unknown as D1Database;
}

let errorSpy: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
	errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
	vi.spyOn(console, "warn").mockImplementation(() => {});
});

afterEach(() => {
	vi.restoreAllMocks();
});

describe("unexpected exception on GET /v1/me", () => {
	it("never logs a client-controlled unknown pathname", async () => {
		const env: ApiEnv = {
			DB: failingDb(),
			...fakeRateLimiters().bindings,
		};
		// An infrastructure error before the limiter can answer reaches onError.
		Object.defineProperty(env, "API_IP_RATE_LIMITER", {
			get() {
				throw new Error(DB_ERROR);
			},
		});
		const response = await worker.fetch(
			new Request(
				"https://api.test/v1/private-user/private-token?email=private-email",
				{ headers: { "cf-connecting-ip": "203.0.113.90" } },
			),
			env,
			{} as ExecutionContext,
		);
		expect(response.status).toBe(500);
		const log = JSON.parse(errorSpy.mock.calls[0]?.[0] as string);
		expect(log.path).toBe("/v1/*");
		expect(JSON.stringify(log)).not.toContain(DB_ERROR);
		for (const value of [...SECRETS, "private-email"]) {
			expect(JSON.stringify(log)).not.toContain(value);
		}
	});

	it("answers a sanitized 500 and logs only the correlation id", async () => {
		const env: ApiEnv = {
			DB: failingDb(),
			...fakeRateLimiters().bindings,
		};
		// A rejection here would hand the raw error to the runtime instead of
		// the sanitized answer, so it is asserted against, not thrown.
		const res = await Promise.resolve(
			worker.fetch(
				new Request("https://api.test/v1/me", {
					headers: {
						"cf-connecting-ip": "203.0.113.90",
						authorization: "Bearer private-token-abcdefghijklmnopqrstuvwxyz",
					},
				}),
				env,
				{} as ExecutionContext,
			),
		).catch((err: unknown) => err);

		expect(res).toBeInstanceOf(Response);
		if (!(res instanceof Response)) return;
		expect(res.status).toBe(500);
		const text = await res.text();
		const body = JSON.parse(text) as {
			error: { code: string; message: string; correlationId: string };
		};
		expect(Object.keys(body)).toEqual(["error"]);
		expect(Object.keys(body.error).sort()).toEqual(["code", "correlationId", "message"]);
		expect(body.error.code).toBe("internal_error");
		expect(body.error.message).toBe("Internal error");
		expect(typeof body.error.correlationId).toBe("string");
		expect(body.error.correlationId.length).toBeGreaterThan(0);
		for (const secret of SECRETS) expect(text).not.toContain(secret);

		expect(errorSpy).toHaveBeenCalledTimes(1);
		const args = errorSpy.mock.calls[0] ?? [];
		// One string argument: the raw Error is never handed to the logger.
		expect(args).toHaveLength(1);
		expect(typeof args[0]).toBe("string");
		const log = JSON.parse(args[0] as string) as Record<string, unknown>;
		expect(log).toEqual({
			event: "unhandled_error",
			code: "internal_error",
			correlationId: body.error.correlationId,
			path: "/v1/me",
			method: "GET",
		});
		for (const secret of SECRETS) expect(args[0]).not.toContain(secret);
	});
});
