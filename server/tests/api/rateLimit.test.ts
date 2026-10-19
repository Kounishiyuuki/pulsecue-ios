/**
 * Rate limiting, exercised through the real Worker router.
 *
 * Like the body-limit tests, these go through the exported `fetch`, so they
 * pin the order production mounts: which limiter runs, with which key, and
 * whether it runs before or after D1, the provider fetch, the JSON parse and
 * the handler. The fake limiters take their ceilings from
 * wrangler.api.jsonc itself, and that file's values are pinned below, so a
 * changed limit fails here rather than in production.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../../src/api/index";
import { findOrCreateAccountForIdentity, findUserById } from "../../src/api/db/accounts";
import { createSession, findActiveSessionByToken } from "../../src/api/db/sessions";
import { MISSING_IP_KEY } from "../../src/api/middleware/rateLimit";
import type { ApiEnv } from "../../src/api/types";
import {
	type FakeRateLimiters,
	type LimiterCall,
	type LimiterName,
	fakeRateLimiters,
} from "./support/rateLimiters";
import { type TestDatabase, createTestDatabase } from "./support/sqliteD1";

interface RateLimitConfig {
	name: LimiterName;
	namespace_id: string;
	simple: { limit: number; period: number };
}

/** The `ratelimits` block of wrangler.api.jsonc, comments stripped. */
function deployedLimiters(): RateLimitConfig[] {
	const path = fileURLToPath(new URL("../../wrangler.api.jsonc", import.meta.url).href);
	const text = readFileSync(path, "utf8")
		.replace(/\/\*[\s\S]*?\*\//g, "")
		.replace(/^\s*\/\/.*$/gm, "");
	return (JSON.parse(text) as { ratelimits: RateLimitConfig[] }).ratelimits;
}

const CONFIG = deployedLimiters();
const LIMIT = Object.fromEntries(
	CONFIG.map((r) => [r.name, r.simple.limit]),
) as Record<LimiterName, number>;

const IP = "203.0.113.77";
const BODY_MARKER = "body-marker-7f3a";

let db: TestDatabase;
let limiters: FakeRateLimiters;
/** D1 statement count at the moment each limiter call happened. */
let d1AtCall: Array<LimiterCall & { d1: number }>;
let fetchSpy: ReturnType<typeof vi.fn>;
let parseSpy: ReturnType<typeof vi.spyOn>;
let logs: string[];

function env(overrides: Partial<ApiEnv> = {}): ApiEnv {
	return {
		DB: db as unknown as D1Database,
		...limiters.bindings,
		APPLE_AUDIENCE: "com.example.pulsecue",
		GOOGLE_AUDIENCE: "server-client-id.apps.googleusercontent.com",
		...overrides,
	};
}

function send(
	method: string,
	path: string,
	options: { token?: string; ip?: string | null; body?: string; headers?: Record<string, string>; env?: ApiEnv } = {},
) {
	const headers: Record<string, string> = { ...options.headers };
	if (options.ip !== null) headers["cf-connecting-ip"] = options.ip ?? IP;
	if (options.token) headers.authorization = `Bearer ${options.token}`;
	if (options.body !== undefined) headers["content-type"] = "application/json";
	return worker.fetch(
		new Request(`https://api.test${path}`, { method, headers, body: options.body }),
		options.env ?? env(),
		{} as ExecutionContext,
	);
}

async function signIn(subject: string) {
	const account = await findOrCreateAccountForIdentity(
		db,
		{ provider: "google", subject, email: `${subject}@example.com`, emailVerified: true },
		Math.floor(Date.now() / 1000),
	);
	const { token } = await createSession(db, account.user.id);
	return { userId: account.user.id, token, subject };
}

const emptyUpload = JSON.stringify({ sessions: [], stepResults: [], note: BODY_MARKER });
const syncBody = () => JSON.stringify({ sessions: [], stepResults: [] });

beforeEach(async () => {
	db = await createTestDatabase();
	d1AtCall = [];
	limiters = fakeRateLimiters(LIMIT, (call) =>
		d1AtCall.push({ ...call, d1: db.recorded().length }),
	);
	fetchSpy = vi.fn(async () => new Response("unexpected", { status: 500 }));
	vi.stubGlobal("fetch", fetchSpy);
	parseSpy = vi.spyOn(Request.prototype, "text");
	logs = [];
	const capture = (...args: unknown[]) => {
		logs.push(args.map(String).join(" "));
	};
	vi.spyOn(console, "warn").mockImplementation(capture);
	vi.spyOn(console, "error").mockImplementation(capture);
	vi.spyOn(console, "log").mockImplementation(capture);
});

afterEach(() => {
	vi.restoreAllMocks();
	vi.unstubAllGlobals();
	db.close();
});

async function expectRateLimited(res: Response) {
	expect(res.status).toBe(429);
	const body = (await res.json()) as { error: Record<string, unknown> };
	expect(Object.keys(body.error).sort()).toEqual(["code", "correlationId", "message"]);
	expect(body.error.code).toBe("rate_limited");
}

/** Spends `n` tokens of the API IP limiter for `ip` without touching D1. */
async function spendApi(n: number, ip = IP) {
	for (let i = 0; i < n; i++) {
		const res = await send("GET", "/v1/me", { ip });
		expect(res.status).toBe(401);
	}
}

describe("wrangler.api.jsonc", () => {
	it("declares exactly the four limiters, at these limits, per minute", () => {
		expect(
			CONFIG.map((r) => [r.name, r.simple.limit, r.simple.period]),
		).toEqual([
			["API_IP_RATE_LIMITER", 300, 60],
			["AUTH_IP_RATE_LIMITER", 60, 60],
			["SYNC_USER_RATE_LIMITER", 30, 60],
			["ACCOUNT_USER_RATE_LIMITER", 10, 60],
		]);
	});

	it("gives every limiter its own namespace", () => {
		const ids = CONFIG.map((r) => r.namespace_id);
		expect(new Set(ids).size).toBe(ids.length);
		for (const id of ids) expect(id).toMatch(/^[1-9]\d*$/);
	});
});

describe("API IP limiter", () => {
	it("allows exactly 300 per IP, then answers 429 before any D1 query", async () => {
		const { token } = await signIn("api-ip-user");
		await spendApi(LIMIT.API_IP_RATE_LIMITER - 1);
		// The 300th, with a real session, still gets through to D1.
		expect((await send("GET", "/v1/me", { token })).status).toBe(200);

		db.resetRecording();
		await expectRateLimited(await send("GET", "/v1/me", { token }));
		await expectRateLimited(await send("GET", "/v1/sync/workouts", { token: "invalid" }));
		await expectRateLimited(await send("POST", "/v1/sync/workouts", { token, body: syncBody() }));
		await expectRateLimited(await send("POST", "/v1/auth/logout", { token }));
		await expectRateLimited(await send("POST", "/v1/auth/logout-all", { token }));
		await expectRateLimited(await send("DELETE", "/v1/me", { token }));
		await expectRateLimited(await send("POST", "/v1/auth/google", { body: "{}" }));
		expect(db.recorded()).toHaveLength(0);
		expect(fetchSpy).not.toHaveBeenCalled();
		// No later limiter ran for a request the shield already refused.
		expect(limiters.calls.every((c) => c.binding === "API_IP_RATE_LIMITER")).toBe(true);
	});

	it("is keyed by CF-Connecting-IP only", async () => {
		await spendApi(LIMIT.API_IP_RATE_LIMITER);
		await expectRateLimited(await send("GET", "/v1/me"));
		// A different edge-reported IP has its own budget; a forged
		// X-Forwarded-For on the exhausted one does not.
		expect((await send("GET", "/v1/me", { ip: "198.51.100.9" })).status).toBe(401);
		await expectRateLimited(
			await send("GET", "/v1/me", { headers: { "x-forwarded-for": "192.0.2.1" } }),
		);
		expect(new Set(limiters.calls.map((c) => c.key))).toEqual(new Set([IP, "198.51.100.9"]));
	});

	it("puts every request without CF-Connecting-IP in one shared bucket", async () => {
		for (let i = 0; i < LIMIT.API_IP_RATE_LIMITER; i++) {
			const res = await send("GET", "/v1/me", {
				ip: null,
				headers: { "x-forwarded-for": `192.0.2.${i % 250}` },
			});
			expect(res.status).toBe(401);
		}
		await expectRateLimited(await send("GET", "/v1/me", { ip: null }));
		expect(new Set(limiters.calls.map((c) => c.key))).toEqual(new Set([MISSING_IP_KEY]));
	});

	it("runs once per request, covers unknown /v1 paths, and skips /health", async () => {
		expect((await send("GET", "/health")).status).toBe(200);
		expect(limiters.calls).toHaveLength(0);

		expect((await send("GET", "/v1/me")).status).toBe(401);
		expect(limiters.calls).toHaveLength(1);

		expect((await send("GET", "/v1/nope")).status).toBe(404);
		expect((await send("PUT", "/v1/me")).status).toBe(404);
		expect(limiters.callsTo("API_IP_RATE_LIMITER")).toHaveLength(3);
	});
});

describe("auth IP limiter", () => {
	it.each(["/v1/auth/apple", "/v1/auth/google"])(
		"%s runs body limit, API IP, then auth IP, before the parse",
		async (path) => {
			const res = await send("POST", path, { body: JSON.stringify({ idToken: "x" }) });
			expect(res.status).not.toBe(429);
			expect(limiters.calls.map((c) => [c.binding, c.key])).toEqual([
				["API_IP_RATE_LIMITER", IP],
				["AUTH_IP_RATE_LIMITER", IP],
			]);
			expect(parseSpy).toHaveBeenCalledTimes(1);
		},
	);

	it("shares 60 per IP across Apple and Google, then refuses before parse or fetch", async () => {
		for (let i = 0; i < LIMIT.AUTH_IP_RATE_LIMITER; i++) {
			const path = i % 2 === 0 ? "/v1/auth/apple" : "/v1/auth/google";
			const res = await send("POST", path, { body: "not json" });
			expect(res.status).not.toBe(429);
		}
		parseSpy.mockClear();
		fetchSpy.mockClear();
		db.resetRecording();

		for (const path of ["/v1/auth/apple", "/v1/auth/google"]) {
			await expectRateLimited(
				await send("POST", path, { body: JSON.stringify({ idToken: "x", authorizationCode: "y" }) }),
			);
		}
		expect(parseSpy).not.toHaveBeenCalled();
		expect(fetchSpy).not.toHaveBeenCalled();
		expect(db.recorded()).toHaveLength(0);

		// Other IPs and non-auth routes are unaffected.
		expect((await send("POST", "/v1/auth/google", { ip: "198.51.100.9", body: "{}" })).status).not.toBe(429);
		expect((await send("GET", "/v1/me")).status).toBe(401);
	});

	it("is not consumed by an oversized body", async () => {
		const res = await send("POST", "/v1/auth/apple", { body: " ".repeat(64 * 1024) });
		expect(res.status).toBe(413);
		expect(limiters.calls).toHaveLength(0);
	});
});

describe("sync user limiter", () => {
	it("runs API IP, then requireSession, then the user limiter, keyed by user UUID", async () => {
		const a = await signIn("sync-order");
		db.resetRecording();
		const res = await send("POST", "/v1/sync/workouts", { token: a.token, body: syncBody() });
		expect(res.status).toBe(200);
		expect(d1AtCall.map((c) => [c.binding, c.key])).toEqual([
			["API_IP_RATE_LIMITER", IP],
			["SYNC_USER_RATE_LIMITER", a.userId],
		]);
		expect(d1AtCall[0]?.d1).toBe(0);
		expect(d1AtCall[1]?.d1).toBeGreaterThan(0);
	});

	it("gives each user 30 per minute independently, even behind one IP", async () => {
		const a = await signIn("sync-a");
		const b = await signIn("sync-b");
		for (let i = 0; i < LIMIT.SYNC_USER_RATE_LIMITER; i++) {
			const res = await send("POST", "/v1/sync/workouts", { token: a.token, body: syncBody() });
			expect(res.status).toBe(200);
		}

		const sessionsBefore = await db.count("workout_sessions");
		db.resetRecording();
		parseSpy.mockClear();
		await expectRateLimited(
			await send("POST", "/v1/sync/workouts", {
				token: a.token,
				body: JSON.stringify({
					sessions: [{ id: crypto.randomUUID(), startedAt: 1_800_000_000, title: BODY_MARKER }],
					stepResults: [],
				}),
			}),
		);
		// Only the session lookup ran; the handler never read or wrote.
		expect(parseSpy).not.toHaveBeenCalled();
		expect(db.recorded().every((q) => !/workout_sessions|step_results/.test(q.sql))).toBe(true);
		expect(await db.count("workout_sessions")).toBe(sessionsBefore);

		const resB = await send("POST", "/v1/sync/workouts", { token: b.token, body: syncBody() });
		expect(resB.status).toBe(200);
		// Reading is not throttled per user.
		expect((await send("GET", "/v1/sync/workouts", { token: a.token })).status).toBe(200);
	});

	it("is not consumed by an oversized body, and neither is D1", async () => {
		const a = await signIn("sync-oversized");
		db.resetRecording();
		const res = await send("POST", "/v1/sync/workouts", {
			token: a.token,
			body: " ".repeat(1024 * 1024 + 1),
		});
		expect(res.status).toBe(413);
		expect(limiters.calls).toHaveLength(0);
		expect(db.recorded()).toHaveLength(0);
	});

	it("is not reached with an invalid bearer: API IP, then requireSession says 401", async () => {
		const res = await send("POST", "/v1/sync/workouts", { token: "not-a-session", body: syncBody() });
		expect(res.status).toBe(401);
		expect(limiters.calls.map((c) => c.binding)).toEqual(["API_IP_RATE_LIMITER"]);
		expect(db.recorded().length).toBeGreaterThan(0);
	});
});

describe("account mutation limiter", () => {
	it("shares 10 per user across logout-all and DELETE /v1/me", async () => {
		const a = await signIn("account-a");
		const b = await signIn("account-b");
		// logout-all revokes the bearer, so each attempt needs a fresh one.
		for (let i = 0; i < LIMIT.ACCOUNT_USER_RATE_LIMITER; i++) {
			const { token } = await createSession(db, a.userId);
			expect((await send("POST", "/v1/auth/logout-all", { token })).status).toBe(200);
		}
		const keys = limiters.callsTo("ACCOUNT_USER_RATE_LIMITER").map((c) => c.key);
		expect(new Set(keys)).toEqual(new Set([a.userId]));

		const { token: survivor } = await createSession(db, a.userId);
		await expectRateLimited(await send("POST", "/v1/auth/logout-all", { token: survivor }));
		await expectRateLimited(await send("DELETE", "/v1/me", { token: survivor }));
		// Neither handler ran: the session survives and the account is active.
		const now = Math.floor(Date.now() / 1000);
		expect(await findActiveSessionByToken(db, survivor, now)).not.toBeNull();
		expect((await findUserById(db, a.userId))?.state).toBe("active");
		expect(fetchSpy).not.toHaveBeenCalled();

		// B, behind the same IP, is unaffected.
		expect((await send("POST", "/v1/auth/logout-all", { token: b.token })).status).toBe(200);
	});

	it("runs after requireSession on DELETE /v1/me", async () => {
		const a = await signIn("delete-order");
		db.resetRecording();
		await send("DELETE", "/v1/me", { token: a.token });
		expect(d1AtCall.map((c) => [c.binding, c.key])).toEqual([
			["API_IP_RATE_LIMITER", IP],
			["ACCOUNT_USER_RATE_LIMITER", a.userId],
		]);
		expect(d1AtCall[0]?.d1).toBe(0);
		expect(d1AtCall[1]?.d1).toBeGreaterThan(0);
	});

	it("does not apply to plain logout", async () => {
		const a = await signIn("logout-plain");
		expect((await send("POST", "/v1/auth/logout", { token: a.token })).status).toBe(200);
		expect(limiters.calls.map((c) => c.binding)).toEqual(["API_IP_RATE_LIMITER"]);
	});
});

describe("limiter failure fails closed", () => {
	const broken: Array<[string, RateLimit | undefined]> = [
		["missing", undefined],
		["throwing", { limit: async () => { throw new Error(`boom ${IP}`); } }],
		["malformed", { limit: async () => ({}) as RateLimitOutcome }],
		["truthy non-boolean", { limit: async () => ({ success: "yes" }) as unknown as RateLimitOutcome }],
	];

	describe.each(broken)("%s binding", (_label, binding) => {
		it.each([
			["API_IP_RATE_LIMITER", "GET", "/v1/me"],
			["AUTH_IP_RATE_LIMITER", "POST", "/v1/auth/google"],
			["SYNC_USER_RATE_LIMITER", "POST", "/v1/sync/workouts"],
			["ACCOUNT_USER_RATE_LIMITER", "POST", "/v1/auth/logout-all"],
		] as const)("%s → 503 on %s %s", async (name, method, path) => {
			const a = await signIn(`broken-${name}`);
			const res = await send(method, path, {
				token: a.token,
				body: method === "POST" ? syncBody() : undefined,
				env: env({ [name]: binding }),
			});
			expect(res.status).toBe(503);
			const body = (await res.json()) as { error: Record<string, unknown> };
			expect(body.error.code).toBe("service_unavailable");
			expect(JSON.stringify(body)).not.toContain("boom");
			expect(logs.join("\n")).not.toContain("boom");
			// The handler did not run.
			expect(await findActiveSessionByToken(db, a.token, Math.floor(Date.now() / 1000))).not.toBeNull();
			expect(fetchSpy).not.toHaveBeenCalled();
		});
	});
});

describe("privacy of the refusal", () => {
	it("carries no IP, user id, token, subject, email, key, or body", async () => {
		const a = await signIn("private-subject-9c1e");
		for (let i = 0; i < LIMIT.SYNC_USER_RATE_LIMITER; i++) {
			await send("POST", "/v1/sync/workouts", { token: a.token, body: syncBody() });
		}
		logs = [];
		const userLimited = await send("POST", "/v1/sync/workouts", { token: a.token, body: emptyUpload });
		await spendApi(LIMIT.API_IP_RATE_LIMITER - limiters.callsTo("API_IP_RATE_LIMITER").length);
		const ipLimited = await send("POST", "/v1/sync/workouts", { token: a.token, body: emptyUpload });

		const texts = [await userLimited.text(), await ipLimited.text(), ...logs];
		expect(userLimited.status).toBe(429);
		expect(ipLimited.status).toBe(429);
		const all = texts.join("\n");
		for (const secret of [IP, a.userId, a.token, a.subject, `${a.subject}@example.com`, BODY_MARKER]) {
			expect(all).not.toContain(secret);
		}
		expect(logs.some((l) => l.includes('"event":"rate_limited"'))).toBe(true);
	});
});
