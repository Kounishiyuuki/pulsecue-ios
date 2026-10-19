/**
 * The production entrypoint for account deletion retries.
 *
 * `processDueAccountDeletions` existed and was tested long before anything
 * called it, so an account whose Apple revocation failed once stayed
 * `deleting` forever. These tests go through the exported Worker — the
 * object Cloudflare actually invokes — and the wrangler config that schedules
 * it, so that regression cannot come back unnoticed.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import ts from "typescript";
import { afterEach, describe, expect, it, vi } from "vitest";
import { processDueAccountDeletions } from "../../src/api/auth/accountDeletionService";
import { TokenCipher } from "../../src/api/crypto/tokenCipher";
import {
	DELETION_RETRY_BACKOFF_SECONDS,
	findAccountDeletion,
	listDueAccountDeletions,
	recordDeletionAttempt,
	requestAccountDeletion,
} from "../../src/api/db/accountDeletion";
import { findOrCreateAccountForIdentity, findUserById } from "../../src/api/db/accounts";
import { prepareCredentialUpsert } from "../../src/api/db/providerCredentials";
import worker from "../../src/api/index";
import type { ApiEnv, SqlDatabase } from "../../src/api/types";
import {
	type RecordedRequest,
	createTestAppleSigningKey,
	fakeAppleEndpoint,
	testEncryptionKey,
} from "./support/appleProduction";
import { fakeRateLimiters } from "./support/rateLimiters";
import { type TestDatabase, createTestDatabase } from "./support/sqliteD1";

const NOW = 1_800_000_100;

afterEach(() => {
	vi.unstubAllGlobals();
	vi.restoreAllMocks();
});

/** A fully configured deployment, built from env exactly as production is. */
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
	return { db, cipher, key, env };
}

/** An Apple user whose deletion was requested at `requestedAt`. */
async function deletingAppleUser(
	db: TestDatabase,
	cipher: TokenCipher,
	subject: string,
	requestedAt = NOW,
) {
	const account = await findOrCreateAccountForIdentity(
		db,
		{ provider: "apple", subject },
		requestedAt,
	);
	await (
		await prepareCredentialUpsert(
			db,
			cipher,
			{
				authIdentityId: account.identity.id,
				provider: "apple",
				refreshToken: `refresh-${subject}`,
			},
			requestedAt,
		)
	).run();
	await requestAccountDeletion(db, account.user.id, requestedAt);
	return account.user.id;
}

/** Production code reads the global `fetch`; Apple is never contacted. */
function stubApple(responder: (request: RecordedRequest) => Response) {
	const endpoint = fakeAppleEndpoint(responder);
	vi.stubGlobal("fetch", endpoint.fetchImpl);
	return endpoint;
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

const ok = () => new Response("", { status: 200 });
const down = () => new Response("", { status: 503 });

describe("the exported Worker's scheduled handler", () => {
	it("completes a due deletion through the real entrypoint", async () => {
		const { db, cipher, env } = await setup();
		const userId = await deletingAppleUser(db, cipher, "apple-a");
		const apple = stubApple(ok);
		vi.spyOn(console, "log").mockImplementation(() => {});

		await runCron(env, NOW);

		expect(apple.requests).toHaveLength(1);
		expect(apple.requests[0]?.form.token).toBe("refresh-apple-a");
		expect(await findUserById(db, userId)).toBeNull();
		db.close();
	});

	it("leaves a deletion that is not yet due untouched", async () => {
		const { db, cipher, env } = await setup();
		const userId = await deletingAppleUser(db, cipher, "apple-a");
		const apple = stubApple(down);
		vi.spyOn(console, "log").mockImplementation(() => {});
		vi.spyOn(console, "warn").mockImplementation(() => {});

		await runCron(env, NOW); // fails, schedules a retry
		const before = await findAccountDeletion(db, userId);
		await runCron(env, NOW + 60); // too early

		expect(apple.requests).toHaveLength(1);
		expect(await findAccountDeletion(db, userId)).toEqual(before);
		expect((await findUserById(db, userId))?.state).toBe("deleting");
		db.close();
	});

	it("retries after a failed revoke and finishes once Apple recovers", async () => {
		const { db, cipher, env } = await setup();
		const userId = await deletingAppleUser(db, cipher, "apple-a");
		let appleUp = false;
		const apple = stubApple(() => (appleUp ? ok() : down()));
		vi.spyOn(console, "log").mockImplementation(() => {});

		await runCron(env, NOW);
		const pending = await findAccountDeletion(db, userId);
		expect(pending?.attempts).toBe(1);
		expect(pending?.next_attempt_at).toBe(NOW + DELETION_RETRY_BACKOFF_SECONDS);
		expect((await findUserById(db, userId))?.state).toBe("deleting");

		appleUp = true;
		await runCron(env, NOW + DELETION_RETRY_BACKOFF_SECONDS);

		expect(apple.requests).toHaveLength(2);
		expect(await findUserById(db, userId)).toBeNull();
		expect(await findAccountDeletion(db, userId)).toBeNull();
		db.close();
	});

	it("does not let one account's revoke failure hold up the others", async () => {
		const { db, cipher, env } = await setup();
		// Requested first, so it is processed first.
		const stuck = await deletingAppleUser(db, cipher, "apple-stuck", NOW - 10);
		const other = await deletingAppleUser(db, cipher, "apple-other", NOW);
		stubApple((request) =>
			request.form.token === "refresh-apple-stuck" ? down() : ok(),
		);
		vi.spyOn(console, "log").mockImplementation(() => {});

		await runCron(env, NOW);

		expect((await findUserById(db, stuck))?.state).toBe("deleting");
		expect(await findUserById(db, other)).toBeNull();
		db.close();
	});

	it("is idempotent across repeated runs", async () => {
		const { db, cipher, env } = await setup();
		const userId = await deletingAppleUser(db, cipher, "apple-a");
		const apple = stubApple(ok);
		vi.spyOn(console, "log").mockImplementation(() => {});

		await runCron(env, NOW);
		await runCron(env, NOW);
		await runCron(env, NOW + DELETION_RETRY_BACKOFF_SECONDS);

		expect(apple.requests).toHaveLength(1);
		expect(await findUserById(db, userId)).toBeNull();
		db.close();
	});

	it("logs aggregate counts only — no ids, tokens or subjects", async () => {
		const { db, cipher, env } = await setup();
		const userId = await deletingAppleUser(db, cipher, "apple-a");
		stubApple(down);
		const log = vi.spyOn(console, "log").mockImplementation(() => {});

		await runCron(env, NOW);

		const written = JSON.stringify(log.mock.calls);
		expect(written).not.toContain(userId);
		expect(written).not.toContain("refresh-apple-a");
		expect(written).not.toContain("apple-a");
		expect(JSON.parse(String(log.mock.calls[0]?.[0]))).toEqual({
			event: "account_deletion_retry_run",
			completed: 0,
			stillPending: 1,
			failed: 0,
		});
		db.close();
	});

	it("fails the run with a fixed error that carries nothing from the cause", async () => {
		const { db, env } = await setup();
		db.close(); // every query now throws
		const error = vi.spyOn(console, "error").mockImplementation(() => {});

		await expect(runCron(env, NOW)).rejects.toThrow(
			"account deletion retry run failed",
		);
		expect(JSON.parse(String(error.mock.calls[0]?.[0]))).toEqual({
			event: "account_deletion_retry_run_failed",
			code: "internal_error",
		});
	});

	it("leaves the HTTP API intact", async () => {
		const { db, env } = await setup();
		const ctx = {} as ExecutionContext;

		const health = await worker.fetch(new Request("https://api.test/health"), env, ctx);
		expect(health.status).toBe(200);
		expect(await health.json()).toEqual({ status: "ok", service: "pulsecue-api" });

		const unauthenticated = await worker.fetch(
			new Request("https://api.test/v1/me", {
				method: "DELETE",
				headers: { "cf-connecting-ip": "203.0.113.1" },
			}),
			env,
			ctx,
		);
		expect(unauthenticated.status).toBe(401);
		db.close();
	});
});

/**
 * A database on which every statement bound to one of `broken` throws, as a
 * D1 fault would. The deferral UPDATE is let through unless `failDeferral`.
 */
function faultyDb(
	db: TestDatabase,
	broken: string[],
	options: { failDeferral?: boolean } = {},
): SqlDatabase {
	return {
		prepare(query) {
			const statement = db.prepare(query);
			const isDeferral = /SET attempts\s*=\s*attempts \+ 1,\s*last_attempt_at = \?,\s*next_attempt_at/.test(
				query,
			);
			if (isDeferral && !options.failDeferral) return statement;
			const bind = statement.bind.bind(statement);
			statement.bind = (...values: unknown[]) => {
				if (values.some((v) => broken.includes(v as string))) {
					throw new Error(`D1 failed for ${String(values)}`);
				}
				return bind(...values);
			};
			return statement;
		},
		batch: (statements) => db.batch(statements),
	};
}

/** A Google-only user (no credential to revoke) whose deletion is requested. */
async function deletingGoogleUser(db: TestDatabase, subject: string, requestedAt: number) {
	const account = await findOrCreateAccountForIdentity(
		db,
		{ provider: "google", subject },
		requestedAt,
	);
	await requestAccountDeletion(db, account.user.id, requestedAt);
	return account.user.id;
}

describe("processDueAccountDeletions isolates a throwing account", () => {
	it("still finishes the others, counts the failure and defers the row", async () => {
		const { db, cipher, key } = await setup();
		const broken = await deletingAppleUser(db, cipher, "apple-broken", NOW - 10);
		const healthy = await deletingAppleUser(db, cipher, "apple-healthy", NOW);
		const apple = fakeAppleEndpoint(ok);

		const result = await processDueAccountDeletions(
			{ db: faultyDb(db, [broken]), appleConfig: key.config, cipher, fetchImpl: apple.fetchImpl },
			NOW,
		);

		expect(result).toEqual({ completed: 1, stillPending: 0, failed: 1 });
		expect(await findUserById(db, healthy)).toBeNull();
		expect((await findUserById(db, broken))?.state).toBe("deleting");
		db.close();
	});

	it("records the attempt without inventing an error code", async () => {
		const { db, cipher, key } = await setup();
		const broken = await deletingAppleUser(db, cipher, "apple-broken", NOW - 1_000);
		// An earlier, genuine provider failure.
		await recordDeletionAttempt(db, broken, "provider_rejected", NOW - 1_000, 0);
		const deps = { db: faultyDb(db, [broken]), appleConfig: key.config, cipher };

		await processDueAccountDeletions(deps, NOW);

		const row = await findAccountDeletion(db, broken);
		expect(row?.attempts).toBe(2);
		expect(row?.last_attempt_at).toBe(NOW);
		expect(row?.next_attempt_at).toBe(NOW + DELETION_RETRY_BACKOFF_SECONDS);
		expect(row?.last_error_code).toBe("provider_rejected");
		db.close();
	});

	it("keeps a first-time throw's error code empty rather than guessing one", async () => {
		const { db } = await setup();
		const broken = await deletingGoogleUser(db, "google-broken", NOW);

		await processDueAccountDeletions(
			{ db: faultyDb(db, [broken]), appleConfig: null, cipher: null },
			NOW,
		);

		const row = await findAccountDeletion(db, broken);
		expect(row?.attempts).toBe(1);
		expect(row?.last_error_code).toBeNull();
		db.close();
	});

	it("defers again on a repeat throw instead of hot-looping", async () => {
		const { db } = await setup();
		const broken = await deletingGoogleUser(db, "google-broken", NOW);
		const deps = { db: faultyDb(db, [broken]), appleConfig: null, cipher: null };
		const later = NOW + DELETION_RETRY_BACKOFF_SECONDS;

		await processDueAccountDeletions(deps, NOW);
		// Not due yet: the next cron tick inside the backoff does nothing.
		expect(await processDueAccountDeletions(deps, NOW + 60)).toEqual({
			completed: 0,
			stillPending: 0,
			failed: 0,
		});
		expect(await processDueAccountDeletions(deps, later)).toEqual({
			completed: 0,
			stillPending: 0,
			failed: 1,
		});

		const row = await findAccountDeletion(db, broken);
		expect(row?.attempts).toBe(2);
		expect(row?.last_attempt_at).toBe(later);
		expect(row?.next_attempt_at).toBe(later + DELETION_RETRY_BACKOFF_SECONDS);
		db.close();
	});

	it("fails the run when the deferral itself cannot be written", async () => {
		const { db, env } = await setup();
		const broken = await deletingGoogleUser(db, "google-broken", NOW - 10);
		const faulty = faultyDb(db, [broken], { failDeferral: true });

		await expect(
			processDueAccountDeletions({ db: faulty, appleConfig: null, cipher: null }, NOW),
		).rejects.toThrow();
		// And through the Worker, as the fixed Cron failure.
		const error = vi.spyOn(console, "error").mockImplementation(() => {});
		await expect(
			runCron({ ...env, DB: faulty } as unknown as ApiEnv, NOW),
		).rejects.toThrow("account deletion retry run failed");
		expect(JSON.stringify(error.mock.calls)).not.toContain(broken);
		expect((await findUserById(db, broken))?.state).toBe("deleting");
		db.close();
	});
});

describe("fair selection of due deletions", () => {
	it("a newer deletion is not starved by 50+ rows that always throw", async () => {
		const { db } = await setup();
		const broken: string[] = [];
		for (let i = 0; i < 55; i += 1) {
			broken.push(await deletingGoogleUser(db, `google-broken-${i}`, NOW - 1_000 + i));
		}
		const healthy = await deletingGoogleUser(db, "google-healthy", NOW);
		const deps = { db: faultyDb(db, broken), appleConfig: null, cipher: null };

		// First run: the 50 oldest fill the batch, throw, and are deferred.
		expect(await processDueAccountDeletions(deps, NOW, 50)).toEqual({
			completed: 0,
			stillPending: 0,
			failed: 50,
		});
		// Next cron tick at the backoff: everything is due again, but the
		// healthy row has waited longest and is taken ahead of them.
		const next = await processDueAccountDeletions(
			deps,
			NOW + DELETION_RETRY_BACKOFF_SECONDS,
			50,
		);

		expect(next.completed).toBe(1);
		expect(await findUserById(db, healthy)).toBeNull();
		db.close();
	});

	it("a newer deletion is not starved by rows pending on a provider error", async () => {
		const { db, cipher, key } = await setup();
		const old = await deletingAppleUser(db, cipher, "apple-old", NOW - 1_000);
		const fresh = await deletingAppleUser(db, cipher, "apple-new", NOW);
		const apple = fakeAppleEndpoint((request) =>
			request.form.token === "refresh-apple-old" ? new Response("", { status: 400 }) : ok(),
		);
		const deps = { db, appleConfig: key.config, cipher, fetchImpl: apple.fetchImpl };

		// Batch of one: the old row is taken first and stays pending.
		expect(await processDueAccountDeletions(deps, NOW, 1)).toEqual({
			completed: 0,
			stillPending: 1,
			failed: 0,
		});
		expect((await findAccountDeletion(db, old))?.last_error_code).toBe("provider_rejected");
		// Both due again; the new one has waited longer.
		expect(
			await processDueAccountDeletions(deps, NOW + DELETION_RETRY_BACKOFF_SECONDS, 1),
		).toEqual({ completed: 1, stillPending: 0, failed: 0 });
		expect(await findUserById(db, fresh)).toBeNull();
		db.close();
	});

	it("orders by next_attempt_at, then requested_at", async () => {
		const { db } = await setup();
		const oldLate = await deletingGoogleUser(db, "old-late", NOW - 1_000);
		const newEarly = await deletingGoogleUser(db, "new-early", NOW - 100);
		const tieOld = await deletingGoogleUser(db, "tie-old", NOW - 900);
		const tieNew = await deletingGoogleUser(db, "tie-new", NOW - 800);
		await recordDeletionAttempt(db, oldLate, "credential_unreadable", NOW - 50, 0);
		await recordDeletionAttempt(db, tieOld, "provider_unavailable", NOW - 200, 0);
		await recordDeletionAttempt(db, tieNew, "provider_unavailable", NOW - 200, 0);

		const due = await listDueAccountDeletions(db, NOW, 10);

		expect(due.map((row) => row.user_id)).toEqual([tieOld, tieNew, newEarly, oldLate]);
		db.close();
	});

	it("parallel runs leave the account deleted, never resurrected", async () => {
		const { db, cipher, key } = await setup();
		const userId = await deletingAppleUser(db, cipher, "apple-a");
		const apple = fakeAppleEndpoint(ok);
		const deps = { db, appleConfig: key.config, cipher, fetchImpl: apple.fetchImpl };

		const results = await Promise.all([
			processDueAccountDeletions(deps, NOW),
			processDueAccountDeletions(deps, NOW),
		]);

		expect(results.every((r) => r.failed === 0)).toBe(true);
		expect(await findUserById(db, userId)).toBeNull();
		expect(await findAccountDeletion(db, userId)).toBeNull();
		db.close();
	});
});

describe("wrangler.api.jsonc", () => {
	it("schedules the Worker whose module exports the scheduled handler", () => {
		const text = readFileSync(
			fileURLToPath(new URL("../../wrangler.api.jsonc", import.meta.url).href),
			"utf8",
		);
		const parsed = ts.parseConfigFileTextToJson("wrangler.api.jsonc", text);
		expect(parsed.error).toBeUndefined();
		const config = parsed.config as {
			main?: string;
			triggers?: { crons?: unknown };
		};

		expect(config.main).toBe("src/api/index.ts");
		const crons = config.triggers?.crons;
		expect(Array.isArray(crons) && crons.length > 0).toBe(true);
		for (const cron of crons as unknown[]) {
			expect(typeof cron).toBe("string");
			expect((cron as string).trim().split(/\s+/)).toHaveLength(5);
		}
		expect(typeof worker.scheduled).toBe("function");
	});
});
