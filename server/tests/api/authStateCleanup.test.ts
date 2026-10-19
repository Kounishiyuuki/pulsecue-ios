/**
 * The scheduled sweep of auth state no request can use any more: replayable
 * nonces and long-expired sessions — and its independence from the account
 * deletion retry that shares the same Cron run.
 */

import { afterEach, describe, expect, it, vi } from "vitest";
import { APPLE_CLOCK_SKEW_SECONDS } from "../../src/api/auth/apple";
import { TokenCipher } from "../../src/api/crypto/tokenCipher";
import { findAccountDeletion, requestAccountDeletion } from "../../src/api/db/accountDeletion";
import { findOrCreateAccountForIdentity, findUserById } from "../../src/api/db/accounts";
import { consumeNonce } from "../../src/api/db/nonces";
import { findCredentialForIdentity, prepareCredentialUpsert } from "../../src/api/db/providerCredentials";
import {
	SESSION_PURGE_BATCH_LIMIT,
	SESSION_PURGE_GRACE_SECONDS,
	SESSION_TTL_SECONDS,
	createSession,
	findActiveSessionByToken,
	findSessionById,
	purgeExpiredSessions,
	revokeSession,
} from "../../src/api/db/sessions";
import worker from "../../src/api/index";
import type { ApiEnv, SqlDatabase } from "../../src/api/types";
import {
	createTestAppleSigningKey,
	fakeAppleEndpoint,
	testEncryptionKey,
} from "./support/appleProduction";
import { fakeRateLimiters } from "./support/rateLimiters";
import { type TestDatabase, createTestDatabase } from "./support/sqliteD1";

const NOW = 1_800_000_100;
const GRACE = SESSION_PURGE_GRACE_SECONDS;

afterEach(() => {
	vi.unstubAllGlobals();
	vi.restoreAllMocks();
});

async function setup() {
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

async function activeUser(db: TestDatabase, subject: string) {
	const account = await findOrCreateAccountForIdentity(
		db,
		{ provider: "google", subject },
		NOW - SESSION_TTL_SECONDS * 2,
	);
	return account.user.id;
}

/** A session whose absolute expiry lands exactly on `expiresAt`. */
function sessionExpiringAt(db: TestDatabase, userId: string, expiresAt: number) {
	return createSession(db, userId, { now: expiresAt - SESSION_TTL_SECONDS });
}

function runCron(env: ApiEnv, at: number) {
	const controller = {
		scheduledTime: at * 1000,
		cron: "*/15 * * * *",
		noRetry() {},
	} as ScheduledController;
	const ctx = {
		waitUntil() {},
		passThroughOnException() {},
	} as unknown as ExecutionContext;
	return worker.scheduled(controller, env, ctx);
}

/** A database on which every statement matching one of `broken` throws. */
function faultyDb(db: TestDatabase, broken: RegExp[]): SqlDatabase {
	return {
		prepare(query) {
			if (broken.some((pattern) => pattern.test(query))) {
				throw new Error(`D1 failed for ${query}`);
			}
			return db.prepare(query);
		},
		batch: (statements) => db.batch(statements),
	};
}

const RETRY = /FROM account_deletions/;
const NONCES = /DELETE FROM auth_nonces/;
const SESSIONS = /DELETE FROM sessions/;

/** One stale and one live row in each table, plus a due Google deletion. */
async function seedAll(db: TestDatabase) {
	await consumeNonce(db, { nonceHash: "a".repeat(64), provider: "apple", expiresAt: 1, now: 1 });
	await consumeNonce(db, {
		nonceHash: "b".repeat(64),
		provider: "apple",
		expiresAt: NOW + 600,
		now: NOW,
	});
	const userId = await activeUser(db, "google-sessions");
	const stale = await sessionExpiringAt(db, userId, NOW - GRACE - 1);
	const live = await createSession(db, userId, { now: NOW });
	const deleting = await findOrCreateAccountForIdentity(
		db,
		{ provider: "google", subject: "google-deleting" },
		NOW - 10,
	);
	await requestAccountDeletion(db, deleting.user.id, NOW - 10);
	return { stale, live, deletingUserId: deleting.user.id };
}

describe("purgeExpiredSessions", () => {
	it("deletes at expires_at = now - grace and keeps one second later", async () => {
		const { db } = await setup();
		const userId = await activeUser(db, "google-a");
		const atBoundary = await sessionExpiringAt(db, userId, NOW - GRACE);
		const justInside = await sessionExpiringAt(db, userId, NOW - GRACE + 1);

		expect(await purgeExpiredSessions(db, NOW)).toBe(1);
		expect(await findSessionById(db, atBoundary.session.id)).toBeNull();
		expect(await findSessionById(db, justInside.session.id)).not.toBeNull();
		db.close();
	});

	it("never touches an active, unexpired session", async () => {
		const { db } = await setup();
		const userId = await activeUser(db, "google-a");
		const live = await createSession(db, userId, { now: NOW });

		expect(await purgeExpiredSessions(db, NOW)).toBe(0);
		expect(await findActiveSessionByToken(db, live.token, NOW)).not.toBeNull();
		db.close();
	});

	it("keeps a revoked session until its expiry plus grace, regardless of revoked_at", async () => {
		const { db } = await setup();
		const userId = await activeUser(db, "google-a");
		// Revoked long ago, but its absolute expiry is still within grace.
		const kept = await sessionExpiringAt(db, userId, NOW - GRACE + 1);
		await revokeSession(db, kept.session.id, NOW - SESSION_TTL_SECONDS);
		// Revoked, and past expiry plus grace.
		const swept = await sessionExpiringAt(db, userId, NOW - GRACE - 1);
		await revokeSession(db, swept.session.id, NOW - GRACE - 100);

		expect(await purgeExpiredSessions(db, NOW)).toBe(1);
		expect(await findSessionById(db, kept.session.id)).not.toBeNull();
		expect(await findSessionById(db, swept.session.id)).toBeNull();
		db.close();
	});

	it("removes at most the batch limit per call and carries the rest over", async () => {
		const { db } = await setup();
		const userId = await activeUser(db, "google-a");
		for (let i = 0; i < SESSION_PURGE_BATCH_LIMIT + 1; i += 1) {
			await sessionExpiringAt(db, userId, NOW - GRACE - 1_000 + i);
		}

		expect(await purgeExpiredSessions(db, NOW)).toBe(SESSION_PURGE_BATCH_LIMIT);
		const left = await db.prepare(`SELECT expires_at FROM sessions`).all<{ expires_at: number }>();
		// Oldest first: the newest stale row is the one carried over.
		expect(left.results).toEqual([{ expires_at: NOW - GRACE - 1_000 + SESSION_PURGE_BATCH_LIMIT }]);
		expect(await purgeExpiredSessions(db, NOW)).toBe(1);
		expect(await purgeExpiredSessions(db, NOW)).toBe(0);
		db.close();
	});

	it("leaves sign-in and logout running alongside it intact", async () => {
		const { db } = await setup();
		const userId = await activeUser(db, "google-a");
		await sessionExpiringAt(db, userId, NOW - GRACE - 1);
		const loggingOut = await createSession(db, userId, { now: NOW - 100 });

		const [, signedIn] = await Promise.all([
			purgeExpiredSessions(db, NOW),
			createSession(db, userId, { now: NOW }),
			revokeSession(db, loggingOut.session.id, NOW),
		]);

		expect(await findActiveSessionByToken(db, signedIn.token, NOW)).not.toBeNull();
		expect((await findSessionById(db, loggingOut.session.id))?.revoked_at).toBe(NOW);
		expect(await db.count("sessions")).toBe(2);
		db.close();
	});
});

describe("the scheduled run", () => {
	it("retries deletions and sweeps both tables in one run", async () => {
		const { db, env } = await setup();
		const { stale, live, deletingUserId } = await seedAll(db);
		vi.spyOn(console, "log").mockImplementation(() => {});

		await runCron(env, NOW);

		expect(await findUserById(db, deletingUserId)).toBeNull();
		expect(await db.count("auth_nonces")).toBe(1);
		expect(await findSessionById(db, stale.session.id)).toBeNull();
		expect(await findActiveSessionByToken(db, live.token, NOW)).not.toBeNull();
		db.close();
	});

	it("sweeps with the same skew-aware boundary the verifier uses", async () => {
		const { db, env } = await setup();
		await consumeNonce(db, {
			nonceHash: "c".repeat(64),
			provider: "apple",
			expiresAt: NOW - APPLE_CLOCK_SKEW_SECONDS + 1,
			now: NOW - 300,
		});
		vi.spyOn(console, "log").mockImplementation(() => {});

		await runCron(env, NOW);

		expect(await db.count("auth_nonces")).toBe(1);
		db.close();
	});

	it.each([
		["the deletion retry", [RETRY], "account_deletion_retry"],
		["the nonce sweep", [NONCES], "auth_nonce_cleanup"],
		["the session sweep", [SESSIONS], "auth_session_cleanup"],
	])("still runs every other step when %s fails, then fails the run", async (_, broken, category) => {
		const { db, env } = await setup();
		const { stale, deletingUserId } = await seedAll(db);
		const log = vi.spyOn(console, "log").mockImplementation(() => {});
		const error = vi.spyOn(console, "error").mockImplementation(() => {});

		await expect(
			runCron({ ...env, DB: faultyDb(db, broken) } as unknown as ApiEnv, NOW),
		).rejects.toThrow("scheduled run failed");

		const retried = (await findUserById(db, deletingUserId)) === null;
		const noncesSwept = (await db.count("auth_nonces")) === 1;
		const sessionsSwept = (await findSessionById(db, stale.session.id)) === null;
		expect({ retried, noncesSwept, sessionsSwept }).toEqual({
			retried: category !== "account_deletion_retry",
			noncesSwept: category !== "auth_nonce_cleanup",
			sessionsSwept: category !== "auth_session_cleanup",
		});
		expect(error.mock.calls.map((call) => JSON.parse(String(call[0])).category)).toEqual([category]);
		expect(log).toHaveBeenCalledTimes(2);
		db.close();
	});

	it("attempts every step even when all of them fail", async () => {
		const { db, env } = await setup();
		await seedAll(db);
		const error = vi.spyOn(console, "error").mockImplementation(() => {});

		await expect(
			runCron({ ...env, DB: faultyDb(db, [RETRY, NONCES, SESSIONS]) } as unknown as ApiEnv, NOW),
		).rejects.toThrow("scheduled run failed");

		expect(error.mock.calls.map((call) => JSON.parse(String(call[0])).category)).toEqual([
			"account_deletion_retry",
			"auth_nonce_cleanup",
			"auth_session_cleanup",
		]);
		db.close();
	});

	it("is idempotent: a second run changes nothing", async () => {
		const { db, env } = await setup();
		await seedAll(db);
		vi.spyOn(console, "log").mockImplementation(() => {});

		await runCron(env, NOW);
		const after = {
			nonces: await db.count("auth_nonces"),
			sessions: await db.count("sessions"),
			users: await db.count("users"),
		};
		await runCron(env, NOW);

		expect({
			nonces: await db.count("auth_nonces"),
			sessions: await db.count("sessions"),
			users: await db.count("users"),
		}).toEqual(after);
		db.close();
	});

	it("does not change a pending Apple deletion's outcome or its credential", async () => {
		const { db, cipher, env } = await setup();
		const account = await findOrCreateAccountForIdentity(
			db,
			{ provider: "apple", subject: "apple-a" },
			NOW - SESSION_TTL_SECONDS - GRACE - 10,
		);
		await (
			await prepareCredentialUpsert(
				db,
				cipher,
				{ authIdentityId: account.identity.id, provider: "apple", refreshToken: "refresh-apple-a" },
				NOW - 10,
			)
		).run();
		// A session old enough to be swept in this very run.
		const stale = await sessionExpiringAt(db, account.user.id, NOW - GRACE - 1);
		await requestAccountDeletion(db, account.user.id, NOW - 10);
		const apple = fakeAppleEndpoint(() => new Response("", { status: 503 }));
		vi.stubGlobal("fetch", apple.fetchImpl);
		vi.spyOn(console, "log").mockImplementation(() => {});
		vi.spyOn(console, "warn").mockImplementation(() => {});

		await runCron(env, NOW);

		expect(apple.requests).toHaveLength(1);
		expect(apple.requests[0]?.form.token).toBe("refresh-apple-a");
		expect(await findSessionById(db, stale.session.id)).toBeNull();
		expect((await findUserById(db, account.user.id))?.state).toBe("deleting");
		expect((await findAccountDeletion(db, account.user.id))?.attempts).toBe(1);
		expect(await findCredentialForIdentity(db, account.identity.id)).not.toBeNull();
		db.close();
	});

	it("logs aggregate counts with a shared run id and nothing identifying", async () => {
		const { db, env } = await setup();
		const { stale, live, deletingUserId } = await seedAll(db);
		const log = vi.spyOn(console, "log").mockImplementation(() => {});

		await runCron(env, NOW);

		const lines = log.mock.calls.map((call) => JSON.parse(String(call[0])));
		expect(lines).toEqual([
			{
				event: "account_deletion_retry_run",
				category: "account_deletion_retry",
				runId: expect.any(String),
				completed: 1,
				stillPending: 0,
				failed: 0,
			},
			{ event: "auth_nonce_cleanup_run", category: "auth_nonce_cleanup", runId: expect.any(String), deleted: 1 },
			{ event: "auth_session_cleanup_run", category: "auth_session_cleanup", runId: expect.any(String), deleted: 1 },
		]);
		expect(new Set(lines.map((line) => line.runId)).size).toBe(1);
		const written = JSON.stringify(log.mock.calls);
		for (const secret of [
			deletingUserId,
			stale.session.id,
			live.session.id,
			live.token,
			"a".repeat(64),
			"google-deleting",
		]) {
			expect(written).not.toContain(secret);
		}
		db.close();
	});

	it("logs a failure without the original error, SQL or identifiers", async () => {
		const { db, env } = await setup();
		const { deletingUserId } = await seedAll(db);
		vi.spyOn(console, "log").mockImplementation(() => {});
		const error = vi.spyOn(console, "error").mockImplementation(() => {});

		await expect(
			runCron({ ...env, DB: faultyDb(db, [RETRY, NONCES, SESSIONS]) } as unknown as ApiEnv, NOW),
		).rejects.toThrow(/^scheduled run failed$/);

		for (const call of error.mock.calls) {
			expect(Object.keys(JSON.parse(String(call[0]))).sort()).toEqual([
				"category",
				"code",
				"event",
				"runId",
			]);
		}
		const written = JSON.stringify(error.mock.calls);
		expect(written).not.toContain("D1 failed");
		expect(written).not.toContain("DELETE");
		expect(written).not.toContain(deletingUserId);
		db.close();
	});
});
