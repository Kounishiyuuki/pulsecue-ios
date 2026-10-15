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
			new Request("https://api.test/v1/me", { method: "DELETE" }),
			env,
			ctx,
		);
		expect(unauthenticated.status).toBe(401);
		db.close();
	});
});

describe("processDueAccountDeletions isolates a throwing account", () => {
	it("still finishes the others and counts the failure", async () => {
		const { db, cipher, key } = await setup();
		const broken = await deletingAppleUser(db, cipher, "apple-broken", NOW - 10);
		const healthy = await deletingAppleUser(db, cipher, "apple-healthy", NOW);
		const apple = fakeAppleEndpoint(ok);
		// Any statement bound to the broken user throws, as a D1 fault would.
		const faulty: SqlDatabase = {
			prepare(query) {
				const statement = db.prepare(query);
				const bind = statement.bind.bind(statement);
				statement.bind = (...values: unknown[]) => {
					if (values.includes(broken)) throw new Error(`D1 failed for ${broken}`);
					return bind(...values);
				};
				return statement;
			},
			batch: (statements) => db.batch(statements),
		};

		const result = await processDueAccountDeletions(
			{ db: faulty, appleConfig: key.config, cipher, fetchImpl: apple.fetchImpl },
			NOW,
		);

		expect(result).toEqual({ completed: 1, stillPending: 0, failed: 1 });
		expect(await findUserById(db, healthy)).toBeNull();
		expect((await findUserById(db, broken))?.state).toBe("deleting");
		// Still due, so the next run retries it.
		expect((await findAccountDeletion(db, broken))?.next_attempt_at).toBeLessThanOrEqual(NOW);
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
