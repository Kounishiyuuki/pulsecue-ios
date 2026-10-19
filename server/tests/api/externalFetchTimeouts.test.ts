/**
 * Every outbound provider request has a total deadline, and hitting it
 * aborts the real request instead of merely abandoning it.
 *
 * Before this, a provider that never answered — or answered `200` and then
 * stalled the body — hung a sign-in, wedged the JWKS single-flight for every
 * later caller, and stopped the Cron run before its cleanup steps.
 *
 * Timers are faked so the deadlines are exact and nothing sleeps. The fakes
 * behave as the Fetch standard says a real request does: aborting the
 * signal rejects a pending fetch and errors a body that is still streaming.
 * One fake deliberately ignores the signal, to pin the race that covers a
 * runtime which does not.
 */

import { Hono } from "hono";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
	AppleExchangeError,
	exchangeAppleAuthorizationCode,
	revokeAppleRefreshToken,
} from "../../src/api/auth/appleTokenExchange";
import { fetchWithDeadline } from "../../src/api/auth/fetchWithDeadline";
import { JwksFetchError, RemoteJwksProvider } from "../../src/api/auth/jwks";
import { TokenCipher } from "../../src/api/crypto/tokenCipher";
import { findAccountDeletion, requestAccountDeletion } from "../../src/api/db/accountDeletion";
import { findOrCreateAccountForIdentity, findUserById } from "../../src/api/db/accounts";
import { consumeNonce } from "../../src/api/db/nonces";
import {
	findCredentialForIdentity,
	prepareCredentialUpsert,
} from "../../src/api/db/providerCredentials";
import { SESSION_TTL_SECONDS, createSession, findSessionById } from "../../src/api/db/sessions";
import worker from "../../src/api/index";
import { makeAppleAuthHandler } from "../../src/api/routes/authApple";
import type { ApiEnv } from "../../src/api/types";
import { TEST_AUDIENCE, appleClaims, createTestSigner, hashedNonce } from "./support/appleTokens";
import {
	appleTokenResponse,
	appleTokenResponseFor,
	createTestAppleSigningKey,
	testEncryptionKey,
} from "./support/appleProduction";
import { fakeRateLimiters } from "./support/rateLimiters";
import { type TestDatabase, createTestDatabase } from "./support/sqliteD1";

const NOW = 1_800_000_100;
const SUBJECT = "apple-sub-timeouts";
const AUTH_CODE = "secret-authorization-code-xyz";
const REFRESH_TOKEN = "secret-refresh-token-xyz";

beforeEach(() => {
	// Only the timers: Date stays real so the crypto and clocks under test
	// behave exactly as they do outside this file.
	vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
});

afterEach(() => {
	vi.useRealTimers();
	vi.unstubAllGlobals();
	vi.restoreAllMocks();
});

// MARK: - Fakes

const abortError = () => new DOMException("The operation was aborted.", "AbortError");

type Handler = (url: string, signal: AbortSignal) => Response | Promise<Response>;

/**
 * A fetch whose every call is observable: which URL, whether its signal was
 * aborted, and a promise that resolves once the call has started — the
 * point from which a deadline is running.
 */
function controllableFetch(handler: Handler) {
	const calls: { url: string; signal: AbortSignal }[] = [];
	const waiters: Array<() => void> = [];
	let awaited = 0;
	const impl = (async (url: string, init?: RequestInit) => {
		const signal = init?.signal as AbortSignal;
		calls.push({ url: String(url), signal });
		waiters[calls.length - 1]?.();
		return handler(String(url), signal);
	}) as unknown as typeof fetch;
	/** Resolves once the next not-yet-awaited call has started. */
	const nextStart = () => {
		const index = awaited++;
		if (index < calls.length) return Promise.resolve();
		return new Promise<void>((resolve) => {
			waiters[index] = resolve;
		});
	};
	return { impl, calls, nextStart };
}

/** Never answers; rejects when aborted, as a real fetch does. */
const neverAnswers: Handler = (_url, signal) =>
	new Promise((_, reject) => {
		signal.addEventListener("abort", () => reject(abortError()));
	});

/** Never answers and ignores the signal: a runtime that does not abort. */
const deafNeverAnswers: Handler = () => new Promise(() => {});

/** Sends headers, then a body that never closes until aborted. */
function stalledBody(status = 200): Handler {
	return (_url, signal) =>
		new Response(
			new ReadableStream({
				start(controller) {
					controller.enqueue(new TextEncoder().encode('{"keys":'));
					signal.addEventListener("abort", () => controller.error(abortError()));
				},
			}),
			{ status },
		);
}

/** Sends headers, then a body that fails mid-stream. */
const brokenBody: Handler = () =>
	new Response(
		new ReadableStream({
			pull(controller) {
				controller.error(new Error("connection reset"));
			},
		}),
		{ status: 200 },
	);

/** Records whether a promise has settled, without letting it go unhandled. */
function track<T>(promise: Promise<T>) {
	let settled = false;
	const tracked = promise.then(
		(value) => {
			settled = true;
			return value;
		},
		(error: unknown) => {
			settled = true;
			throw error;
		},
	);
	tracked.catch(() => {});
	return { promise: tracked, settled: () => settled };
}

/** Asserts the promise is still pending at `ms - 1` and settled at `ms`. */
async function expectDeadline<T>(
	started: Promise<void>,
	promise: Promise<T>,
	ms: number,
): Promise<{ result: Promise<T> }> {
	const tracked = track(promise);
	await started;
	await vi.advanceTimersByTimeAsync(ms - 1);
	expect(tracked.settled()).toBe(false);
	await vi.advanceTimersByTimeAsync(1);
	expect(tracked.settled()).toBe(true);
	// Wrapped: returning the promise itself from an async function would
	// adopt it, and a rejection would throw out of this helper.
	return { result: tracked.promise };
}

function captureLogs() {
	const lines: string[] = [];
	for (const method of ["log", "warn", "error"] as const) {
		vi.spyOn(console, method).mockImplementation((...args: unknown[]) => {
			lines.push(args.map(String).join(" "));
		});
	}
	return () => lines.join("\n");
}

function keySet(...kids: string[]) {
	return { keys: kids.map((kid) => ({ kid, kty: "RSA", n: "x", e: "AQAB" })) };
}

// MARK: - Shared helper

describe("fetchWithDeadline", () => {
	it("leaves no timer behind after a request that succeeded", async () => {
		const fetcher = controllableFetch(() => new Response("ok"));
		const text = await fetchWithDeadline(fetcher.impl, "https://x.test", {}, 4000, (r) =>
			r.text(),
		);
		expect(text).toBe("ok");
		expect(vi.getTimerCount()).toBe(0);
	});

	it("leaves no timer behind after a request that timed out", async () => {
		const fetcher = controllableFetch(neverAnswers);
		const result = fetchWithDeadline(fetcher.impl, "https://x.test", {}, 4000, (r) => r.text());
		await expect((await expectDeadline(fetcher.nextStart(), result, 4000)).result).rejects.toMatchObject({
			phase: "before_headers",
			reason: "timeout",
		});
		expect(vi.getTimerCount()).toBe(0);
	});

	it("aborts the real request, not just the wait", async () => {
		const fetcher = controllableFetch(neverAnswers);
		const result = fetchWithDeadline(fetcher.impl, "https://x.test", {}, 4000, (r) => r.text());
		await (await expectDeadline(fetcher.nextStart(), result, 4000)).result.catch(() => {});
		expect(fetcher.calls[0]?.signal.aborted).toBe(true);
	});

	it("still settles when the runtime ignores the abort", async () => {
		const fetcher = controllableFetch(deafNeverAnswers);
		const result = fetchWithDeadline(fetcher.impl, "https://x.test", {}, 4000, (r) => r.text());
		await expect((await expectDeadline(fetcher.nextStart(), result, 4000)).result).rejects.toMatchObject({
			reason: "timeout",
		});
		expect(fetcher.calls[0]?.signal.aborted).toBe(true);
	});

	it("carries fixed codes and never the original AbortError", async () => {
		const fetcher = controllableFetch(neverAnswers);
		const result = fetchWithDeadline(fetcher.impl, "https://x.test", {}, 4000, (r) => r.text());
		const error = await (await expectDeadline(fetcher.nextStart(), result, 4000)).result.catch(
			(e: unknown) => e,
		);
		expect(String(error)).not.toMatch(/AbortError|aborted/i);
		expect((error as Error).cause).toBeUndefined();
	});
});

// MARK: - JWKS

describe("JWKS fetch deadline (4 s)", () => {
	function provider(fetchImpl: typeof fetch, now: () => number = () => 0) {
		return new RemoteJwksProvider({
			url: "https://example.test/keys",
			fetchImpl,
			nowMs: now,
		});
	}

	it("times out a fetch that never answers as JwksFetchError", async () => {
		const fetcher = controllableFetch(neverAnswers);
		const result = provider(fetcher.impl).keyForId("k1");
		await expect((await expectDeadline(fetcher.nextStart(), result, 4000)).result).rejects.toBeInstanceOf(
			JwksFetchError,
		);
	});

	it("times out a body that never completes, within the same deadline", async () => {
		const fetcher = controllableFetch(stalledBody());
		const result = provider(fetcher.impl).keyForId("k1");
		await expect((await expectDeadline(fetcher.nextStart(), result, 4000)).result).rejects.toBeInstanceOf(
			JwksFetchError,
		);
		expect(fetcher.calls[0]?.signal.aborted).toBe(true);
	});

	it("clears inFlight, sets the backoff, and recovers on the next allowed fetch", async () => {
		let hang = true;
		const fetcher = controllableFetch((url, signal) =>
			hang ? neverAnswers(url, signal) : new Response(JSON.stringify(keySet("k1"))),
		);
		let now = 0;
		const jwks = provider(fetcher.impl, () => now);

		const first = jwks.keyForId("k1");
		await (await expectDeadline(fetcher.nextStart(), first, 4000)).result.catch(() => {});

		// Inside the backoff: fails fast without a new request — which also
		// proves the next caller is not stuck on the old promise.
		hang = false;
		await expect(jwks.keyForId("k1")).rejects.toBeInstanceOf(JwksFetchError);
		expect(fetcher.calls).toHaveLength(1);

		now = 5_000;
		expect(await jwks.keyForId("k1")).not.toBeNull();
		expect(fetcher.calls).toHaveLength(2);
	});

	it("keeps single-flight: concurrent callers share one timed-out request", async () => {
		const fetcher = controllableFetch(neverAnswers);
		const jwks = provider(fetcher.impl);
		const callers = [jwks.keyForId("a"), jwks.keyForId("b"), jwks.keyForId("c")];
		const all = Promise.allSettled(callers);
		(await expectDeadline(fetcher.nextStart(), all, 4000)).result;
		for (const outcome of await all) {
			expect(outcome.status).toBe("rejected");
		}
		expect(fetcher.calls).toHaveLength(1);
	});

	it("does not cache a partial body", async () => {
		let stall = true;
		const fetcher = controllableFetch((url, signal) =>
			stall ? stalledBody()(url, signal) : new Response(JSON.stringify(keySet("k2"))),
		);
		let now = 0;
		const jwks = provider(fetcher.impl, () => now);
		await (await expectDeadline(fetcher.nextStart(), jwks.keyForId("k1"), 4000)).result.catch(() => {});

		stall = false;
		now = 5_000;
		expect(await jwks.keyForId("k2")).not.toBeNull();
		expect(fetcher.calls).toHaveLength(2);
	});
});

// MARK: - Apple exchange

describe("Apple token exchange deadline (8 s)", () => {
	async function exchange(fetchImpl: typeof fetch) {
		const key = await createTestAppleSigningKey();
		const signer = await createTestSigner();
		return exchangeAppleAuthorizationCode({
			authorizationCode: AUTH_CODE,
			config: key.config,
			expectedSubject: SUBJECT,
			jwks: signer.jwks,
			fetchImpl,
			now: NOW,
		});
	}

	async function failure(promise: Promise<unknown>) {
		const error = await promise.catch((e: unknown) => e);
		expect(error).toBeInstanceOf(AppleExchangeError);
		return error as AppleExchangeError;
	}

	it("a request that never answers is indeterminate, never invalidGrant", async () => {
		const fetcher = controllableFetch(neverAnswers);
		const error = await failure(
			(await expectDeadline(fetcher.nextStart(), exchange(fetcher.impl), 8000)).result,
		);
		expect(error.failure).toBe("providerUnavailable");
		expect(error.indeterminate).toEqual({ phase: "before_headers", reason: "timeout" });
		expect(fetcher.calls[0]?.signal.aborted).toBe(true);
	});

	it("a transport error is indeterminate", async () => {
		const fetcher = controllableFetch(() => {
			throw new TypeError("network down");
		});
		const error = await failure(exchange(fetcher.impl));
		expect(error.failure).toBe("providerUnavailable");
		expect(error.indeterminate).toEqual({
			phase: "before_headers",
			reason: "transport_error",
		});
	});

	it("a 200 whose body never completes is indeterminate, within the same deadline", async () => {
		const fetcher = controllableFetch(stalledBody(200));
		const error = await failure(
			(await expectDeadline(fetcher.nextStart(), exchange(fetcher.impl), 8000)).result,
		);
		expect(error.indeterminate).toEqual({ phase: "body_read", reason: "timeout" });
	});

	it("a 200 whose body read fails is indeterminate, not an empty body", async () => {
		const fetcher = controllableFetch(brokenBody);
		const error = await failure(exchange(fetcher.impl));
		expect(error.failure).toBe("providerUnavailable");
		expect(error.indeterminate).toEqual({ phase: "body_read", reason: "body_read_failed" });
	});

	it.each([
		["truncated JSON", () => new Response('{"refresh_token":"abc', { status: 200 })],
		["empty body", () => new Response("", { status: 200 })],
		["missing refresh_token", () => appleTokenResponse({ refresh_token: undefined })],
		["empty refresh_token", () => appleTokenResponse({ refresh_token: "" })],
	])("a 200 without a readable refresh token is indeterminate — %s", async (_name, body) => {
		const fetcher = controllableFetch(body);
		const error = await failure(exchange(fetcher.impl));
		expect(error.failure).toBe("malformedResponse");
		expect(error.indeterminate).toEqual({
			phase: "success_body",
			reason: "malformed_success_response",
		});
		expect(error.compensation).toBeUndefined();
	});

	it("a non-2xx keeps its classification and is not indeterminate", async () => {
		const fetcher = controllableFetch(
			() => new Response(JSON.stringify({ error: "invalid_grant" }), { status: 400 }),
		);
		const error = await failure(exchange(fetcher.impl));
		expect(error.failure).toBe("invalidGrant");
		expect(error.indeterminate).toBeUndefined();
	});

	it("a non-2xx whose body stalls is an outage, not indeterminate", async () => {
		const fetcher = controllableFetch(stalledBody(503));
		const error = await failure(
			(await expectDeadline(fetcher.nextStart(), exchange(fetcher.impl), 8000)).result,
		);
		expect(error.failure).toBe("providerUnavailable");
		expect(error.indeterminate).toBeUndefined();
	});
});

// MARK: - Apple revoke

describe("Apple revoke deadline (8 s, status line only)", () => {
	async function revoke(fetchImpl: typeof fetch) {
		const key = await createTestAppleSigningKey();
		return revokeAppleRefreshToken({
			refreshToken: REFRESH_TOKEN,
			config: key.config,
			fetchImpl,
			now: NOW,
		});
	}

	it("a revoke that never answers is retryable, never revoked", async () => {
		const fetcher = controllableFetch(neverAnswers);
		const outcome = (await expectDeadline(fetcher.nextStart(), revoke(fetcher.impl), 8000)).result;
		expect(await outcome).toEqual({ status: "retryable" });
		expect(fetcher.calls[0]?.signal.aborted).toBe(true);
	});

	it("decides on a 200 without waiting for a body that never closes", async () => {
		const fetcher = controllableFetch(stalledBody(200));
		// No timers advanced: the outcome must not depend on the body at all.
		expect(await revoke(fetcher.impl)).toEqual({ status: "revoked" });
		expect(vi.getTimerCount()).toBe(0);
	});

	it("still maps 5xx to retryable and 4xx to rejected", async () => {
		expect(await revoke(controllableFetch(() => new Response("", { status: 503 })).impl)).toEqual({
			status: "retryable",
		});
		expect(await revoke(controllableFetch(() => new Response("", { status: 400 })).impl)).toEqual({
			status: "rejected",
		});
	});
});

// MARK: - The sign-in route

async function signInWith(fetcher: ReturnType<typeof controllableFetch>, signer: Awaited<ReturnType<typeof createTestSigner>>, key: Awaited<ReturnType<typeof createTestAppleSigningKey>>, db: TestDatabase) {
	const app = new Hono<{ Bindings: ApiEnv }>();
	app.post(
		"/v1/auth/apple",
		makeAppleAuthHandler({
			jwks: signer.jwks,
			audience: TEST_AUDIENCE,
			clientSecret: key.config,
			cipher: new TokenCipher({ version: 1, material: testEncryptionKey() }),
			fetchImpl: fetcher.impl,
			now: () => NOW,
		}),
	);
	const nonce = `nonce-${Math.random()}`;
	const identityToken = await signer.sign(
		await appleClaims({ sub: SUBJECT, nonce: await hashedNonce(nonce) }),
	);
	return app.request(
		"/v1/auth/apple",
		{
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify({
				identityToken,
				authorizationCode: AUTH_CODE,
				rawNonce: nonce,
			}),
		},
		{ DB: db, APPLE_AUDIENCE: TEST_AUDIENCE } as unknown as ApiEnv,
	);
}

async function writtenRowCounts(db: TestDatabase) {
	return {
		users: await db.count("users"),
		identities: await db.count("auth_identities"),
		credentials: await db.count("provider_credentials"),
		sessions: await db.count("sessions"),
	};
}

describe("POST /v1/auth/apple when the exchange is indeterminate", () => {
	const cases: Array<{ name: string; handler: Handler; deadline: boolean; phase: string; reason: string }> = [
		{ name: "no answer", handler: neverAnswers, deadline: true, phase: "before_headers", reason: "timeout" },
		{
			name: "transport error",
			handler: () => {
				throw new TypeError("network down");
			},
			deadline: false,
			phase: "before_headers",
			reason: "transport_error",
		},
		{ name: "stalled 200 body", handler: stalledBody(200), deadline: true, phase: "body_read", reason: "timeout" },
		{ name: "broken 200 body", handler: brokenBody, deadline: false, phase: "body_read", reason: "body_read_failed" },
		{
			name: "malformed 200 body",
			handler: () => new Response("{not json", { status: 200 }),
			deadline: false,
			phase: "success_body",
			reason: "malformed_success_response",
		},
		{
			name: "200 without refresh_token",
			handler: () => appleTokenResponse({ refresh_token: undefined }),
			deadline: false,
			phase: "success_body",
			reason: "malformed_success_response",
		},
	];

	for (const testCase of cases) {
		it(`answers 503, writes nothing and logs the fixed event — ${testCase.name}`, async () => {
			const db = await createTestDatabase();
			const signer = await createTestSigner();
			const key = await createTestAppleSigningKey();
			const fetcher = controllableFetch(testCase.handler);
			const logs = captureLogs();

			const pending = signInWith(fetcher, signer, key, db);
			const response = testCase.deadline
				? await (await expectDeadline(fetcher.nextStart(), pending, 8000)).result
				: await pending;

			expect(response.status).toBe(503);
			expect(await writtenRowCounts(db)).toEqual({
				users: 0,
				identities: 0,
				credentials: 0,
				sessions: 0,
			});
			// Nothing to revoke: the token value never arrived.
			expect(fetcher.calls.filter((c) => c.url.endsWith("/auth/revoke"))).toHaveLength(0);

			const events = logs()
				.split("\n")
				.filter((line) => line.includes("apple_auth_exchange_indeterminate"))
				.map((line) => JSON.parse(line) as Record<string, unknown>);
			expect(events).toHaveLength(1);
			expect(Object.keys(events[0] ?? {}).sort()).toEqual(
				["correlationId", "event", "phase", "reason"].sort(),
			);
			expect(events[0]).toMatchObject({ phase: testCase.phase, reason: testCase.reason });

			const body = await response.text();
			for (const leaked of [AUTH_CODE, SUBJECT, "AbortError", "aborted", "network down", "connection reset"]) {
				expect(body).not.toContain(leaked);
				expect(logs()).not.toContain(leaked);
			}
			db.close();
		});
	}

	it("is distinct from a compensation failure: a revoke that times out after a token was issued", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const key = await createTestAppleSigningKey();
		// A usable refresh token but no id_token: the exchange must hand the
		// token back, and the revoke hangs.
		const fetcher = controllableFetch((url, signal) =>
			url.endsWith("/auth/revoke")
				? neverAnswers(url, signal)
				: appleTokenResponse({ refresh_token: REFRESH_TOKEN }),
		);
		const logs = captureLogs();

		const pending = track(signInWith(fetcher, signer, key, db));
		await fetcher.nextStart(); // token
		await fetcher.nextStart(); // revoke
		await vi.advanceTimersByTimeAsync(7999);
		expect(pending.settled()).toBe(false);
		await vi.advanceTimersByTimeAsync(1);
		const response = await pending.promise;

		expect(response.status).toBe(503);
		expect(fetcher.calls[1]?.signal.aborted).toBe(true);
		expect(await writtenRowCounts(db)).toEqual({ users: 0, identities: 0, credentials: 0, sessions: 0 });
		expect(logs()).toContain('"event":"apple_auth_compensation_revoke_failed","outcome":"retryable"');
		expect(logs()).not.toContain("apple_auth_exchange_indeterminate");
		expect(logs()).not.toContain(REFRESH_TOKEN);
		db.close();
	});

	it("the exchange reports the timed-out compensation as orphaned, never revoked", async () => {
		const key = await createTestAppleSigningKey();
		const signer = await createTestSigner();
		const fetcher = controllableFetch((url, signal) =>
			url.endsWith("/auth/revoke")
				? neverAnswers(url, signal)
				: appleTokenResponse({ refresh_token: REFRESH_TOKEN }),
		);
		const result = track(
			exchangeAppleAuthorizationCode({
				authorizationCode: AUTH_CODE,
				config: key.config,
				expectedSubject: SUBJECT,
				jwks: signer.jwks,
				fetchImpl: fetcher.impl,
				now: NOW,
			}),
		);
		await fetcher.nextStart();
		await fetcher.nextStart();
		await vi.advanceTimersByTimeAsync(8000);
		const error = (await result.promise.catch((e: unknown) => e)) as AppleExchangeError;
		expect(error.compensation).toEqual({ status: "retryable" });
		expect(error.leftCredentialOrphaned).toBe(true);
		expect(error.indeterminate).toBeUndefined();
	});

	it("bounds a persistence-failure compensation by the same deadline", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const key = await createTestAppleSigningKey();
		const fetcher = controllableFetch(async (url, signal) =>
			url.endsWith("/auth/revoke")
				? neverAnswers(url, signal)
				: appleTokenResponseFor(signer, { sub: SUBJECT, audience: key.config.clientId, now: NOW }),
		);
		const logs = captureLogs();
		const broken = {
			prepare(query: string) {
				if (/INSERT INTO sessions/.test(query)) throw new Error("D1 failed");
				return db.prepare(query);
			},
			batch: (statements: Parameters<TestDatabase["batch"]>[0]) => db.batch(statements),
		} as unknown as TestDatabase;

		const pending = track(signInWith(fetcher, signer, key, broken));
		await fetcher.nextStart();
		await fetcher.nextStart();
		await vi.advanceTimersByTimeAsync(8000);
		const response = await pending.promise;

		expect(response.status).toBe(503);
		expect(logs()).toContain("apple_auth_compensation_revoke_failed");
		expect(logs()).toContain("persistence_failed_credential_orphaned");
		expect(logs()).not.toContain("test-refresh-token");
		expect(logs()).not.toContain(AUTH_CODE);
		expect(logs()).not.toContain(SUBJECT);
		db.close();
	});
});

// MARK: - Account deletion and the Cron run

async function cronSetup() {
	const db = await createTestDatabase();
	const material = testEncryptionKey();
	const cipher = new TokenCipher({ version: 1, material });
	const key = await createTestAppleSigningKey();
	const env = {
		DB: db,
		...fakeRateLimiters().bindings,
		APPLE_CLIENT_ID: key.config.clientId,
		APPLE_TEAM_ID: key.config.teamId,
		APPLE_KEY_ID: key.config.keyId,
		APPLE_PRIVATE_KEY: key.config.privateKeyPem,
		APPLE_TOKEN_ENCRYPTION_KEY: material,
	} as unknown as ApiEnv;
	return { db, cipher, env };
}

async function deletingAppleUser(db: TestDatabase, cipher: TokenCipher, subject: string) {
	const account = await findOrCreateAccountForIdentity(db, { provider: "apple", subject }, NOW);
	await (
		await prepareCredentialUpsert(
			db,
			cipher,
			{ authIdentityId: account.identity.id, provider: "apple", refreshToken: `refresh-${subject}` },
			NOW,
		)
	).run();
	await requestAccountDeletion(db, account.user.id, NOW);
	return { userId: account.user.id, identityId: account.identity.id };
}

function runCron(env: ApiEnv, at: number) {
	const controller = { scheduledTime: at * 1000, cron: "*/15 * * * *", noRetry() {} } as ScheduledController;
	const ctx = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;
	return worker.scheduled(controller, env, ctx);
}

describe("a hung Apple revoke inside the Cron run", () => {
	it("times out, keeps the deletion pending, and still runs both cleanups", async () => {
		const { db, cipher, env } = await cronSetup();
		const hung = await deletingAppleUser(db, cipher, "apple-hung");
		const fetcher = controllableFetch(neverAnswers);
		vi.stubGlobal("fetch", fetcher.impl);
		const logs = captureLogs();

		await consumeNonce(db, { nonceHash: "a".repeat(64), provider: "apple", expiresAt: 1, now: 1 });
		const owner = await findOrCreateAccountForIdentity(
			db,
			{ provider: "google", subject: "google-sessions" },
			NOW - SESSION_TTL_SECONDS * 3,
		);
		const stale = await createSession(db, owner.user.id, { now: NOW - SESSION_TTL_SECONDS * 3 });

		const run = (await expectDeadline(fetcher.nextStart(), runCron(env, NOW), 8000)).result;
		await run;

		expect(fetcher.calls[0]?.signal.aborted).toBe(true);
		expect((await findUserById(db, hung.userId))?.state).toBe("deleting");
		expect((await findAccountDeletion(db, hung.userId))?.attempts).toBe(1);
		const credential = await findCredentialForIdentity(db, hung.identityId);
		expect(credential?.revoked_at ?? null).toBeNull();
		expect(credential?.encrypted_refresh_token).toBeTruthy();

		expect(await db.count("auth_nonces")).toBe(0);
		expect(await findSessionById(db, stale.session.id)).toBeNull();
		expect(logs()).toContain('"event":"account_deletion_retry_run"');
		expect(logs()).toContain('"stillPending":1');
		expect(logs()).toContain('"event":"auth_nonce_cleanup_run"');
		expect(logs()).toContain('"event":"auth_session_cleanup_run"');
		expect(logs()).not.toContain("refresh-apple-hung");
		expect(logs()).not.toMatch(/AbortError|aborted/);

		// The next run, once Apple answers, finishes the deletion.
		vi.stubGlobal("fetch", controllableFetch(() => new Response("", { status: 200 })).impl);
		const deletion = await findAccountDeletion(db, hung.userId);
		await runCron(env, deletion?.next_attempt_at ?? NOW);
		expect(await findUserById(db, hung.userId)).toBeNull();
		db.close();
	});

	it("worst case is the batch limit × the revoke deadline: 50 × 8 s, inside 15 minutes", async () => {
		const { db, cipher, env } = await cronSetup();
		for (let i = 0; i < 51; i += 1) await deletingAppleUser(db, cipher, `apple-${i}`);
		const fetcher = controllableFetch(neverAnswers);
		vi.stubGlobal("fetch", fetcher.impl);
		captureLogs();

		const run = track(runCron(env, NOW + 1));
		let elapsed = 0;
		for (let i = 0; i < 50; i += 1) {
			await fetcher.nextStart();
			expect(run.settled()).toBe(false);
			await vi.advanceTimersByTimeAsync(8000);
			elapsed += 8000;
		}
		await run.promise;

		// The 51st row waits for the next run, so the bound holds.
		expect(fetcher.calls).toHaveLength(50);
		expect(elapsed).toBe(400_000);
		expect(elapsed).toBeLessThanOrEqual(15 * 60 * 1000);
		db.close();
	});
});
