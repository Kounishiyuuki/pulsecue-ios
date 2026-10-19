/**
 * The per-user storage quota (migration 0006).
 *
 * The quota is enforced by the database — a counter moved by triggers and
 * guarded by a CHECK — so most of these tests drive real uploads through the
 * real route and then look at the rows, the counter and the sequence together.
 * A quota that refused the request but left half a batch behind, or a counter
 * that drifted from the rows, would be worse than no quota at all.
 *
 * Boundaries are tested with real rows, not a hand-set counter: the fill
 * helpers insert genuine rows so the triggers count them exactly as they would
 * count an upload.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { Hono } from "hono";
import { describe, expect, it } from "vitest";
import { hardDeleteUser } from "../../src/api/db/accountDeletion";
import { findOrCreateAccountForIdentity } from "../../src/api/db/accounts";
import { createSession } from "../../src/api/db/sessions";
import {
	SyncStorageQuotaExceededError,
	uploadWorkoutData,
} from "../../src/api/db/workoutSync";
import { requireSession } from "../../src/api/middleware/requireSession";
import { makeUploadWorkoutsHandler } from "../../src/api/routes/syncWorkouts";
import type { AuthedEnv } from "../../src/api/types";
import { type TestDatabase, createTestDatabase } from "./support/sqliteD1";

const NOW = 1_800_000_100;
const SESSION_LIMIT = 10_000;
const STEP_RESULT_LIMIT = 100_000;

async function signedIn(db: TestDatabase, subject: string) {
	const account = await findOrCreateAccountForIdentity(
		db,
		{ provider: "apple", subject },
		NOW,
	);
	const issued = await createSession(db, account.user.id, { now: NOW });
	return { userId: account.user.id, token: issued.token };
}

function makeApp(db: TestDatabase) {
	const app = new Hono<AuthedEnv>();
	app.post(
		"/v1/sync/workouts",
		requireSession({ now: () => NOW }),
		makeUploadWorkoutsHandler({ now: () => NOW }),
	);
	return (token: string, body: unknown) =>
		app.request(
			"/v1/sync/workouts",
			{
				method: "POST",
				headers: {
					authorization: `Bearer ${token}`,
					"content-type": "application/json",
				},
				body: JSON.stringify(body),
			},
			{ DB: db } as unknown as AuthedEnv["Bindings"],
		);
}

function session(id: string, extra: Record<string, unknown> = {}) {
	return { id, startedAt: NOW, ...extra };
}

function step(id: string, sessionId: string, extra: Record<string, unknown> = {}) {
	return { id, sessionId, exerciseName: "Squat", orderIndex: 0, ...extra };
}

async function usage(db: TestDatabase, userId: string) {
	return db
		.prepare(
			`SELECT session_count, step_result_count FROM user_storage_usage WHERE user_id = ?`,
		)
		.bind(userId)
		.first<{ session_count: number; step_result_count: number }>();
}

async function rowCount(
	db: TestDatabase,
	table: "workout_sessions" | "step_results",
	userId: string,
) {
	const row = await db
		.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE user_id = ?`)
		.bind(userId)
		.first<{ n: number }>();
	return row?.n ?? 0;
}

async function seq(db: TestDatabase, userId: string) {
	const row = await db
		.prepare(`SELECT seq FROM user_change_seq WHERE user_id = ?`)
		.bind(userId)
		.first<{ seq: number }>();
	return row?.seq;
}

/** Inserts `n` real session rows in one statement; the triggers count them. */
async function fillSessions(db: TestDatabase, userId: string, n: number) {
	await db
		.prepare(
			`WITH RECURSIVE k(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM k WHERE i < ?)
			 INSERT INTO workout_sessions (id, user_id, started_at, change_seq, updated_at)
			 SELECT 'fill-' || i, ?, 1, 0, 1 FROM k`,
		)
		.bind(n, userId)
		.run();
}

/** Inserts `n` real step results under `sessionId`, which must exist. */
async function fillStepResults(
	db: TestDatabase,
	userId: string,
	sessionId: string,
	n: number,
) {
	await db
		.prepare(
			`WITH RECURSIVE k(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM k WHERE i < ?)
			 INSERT INTO step_results
			   (id, user_id, session_id, exercise_name, order_index, change_seq, updated_at)
			 SELECT 'fill-' || i, ?, ?, 'x', 0, 0, 1 FROM k`,
		)
		.bind(n, userId, sessionId)
		.run();
}

async function expectQuotaRejection(response: Response, resource: string) {
	expect(response.status).toBe(409);
	const text = await response.text();
	const body = JSON.parse(text) as {
		error: Record<string, unknown>;
	};
	expect(body.error.code).toBe("storage_quota_exceeded");
	expect(body.error.resource).toBe(resource);
	expect(Object.keys(body.error).sort()).toEqual([
		"code",
		"correlationId",
		"message",
		"resource",
	]);
	// No counts, limits or SQL leak into the body.
	expect(text).not.toMatch(/10000|100000|CHECK|SQLITE|user_storage_usage/);
}

describe("storage usage bookkeeping", () => {
	it("creates a 0/0 usage row in the same batch as the account", async () => {
		const db = await createTestDatabase();
		const { userId } = await signedIn(db, "a");
		expect(await usage(db, userId)).toEqual({
			session_count: 0,
			step_result_count: 0,
		});
		db.close();
	});

	it("counts new inserts once and updates or retries not at all", async () => {
		const db = await createTestDatabase();
		const upload = makeApp(db);
		const { userId, token } = await signedIn(db, "a");
		const body = {
			sessions: [session("s1"), session("s2")],
			stepResults: [step("r1", "s1"), step("r2", "s1"), step("r3", "s2")],
		};

		expect((await upload(token, body)).status).toBe(200);
		expect(await usage(db, userId)).toEqual({
			session_count: 2,
			step_result_count: 3,
		});

		// Same payload again: a sync retry.
		expect((await upload(token, body)).status).toBe(200);
		// Edits to existing records, plus one genuinely new step result.
		expect(
			(
				await upload(token, {
					sessions: [session("s1", { title: "edited" })],
					stepResults: [step("r1", "s1", { reps: 5 }), step("r4", "s2")],
				})
			).status,
		).toBe(200);

		expect(await usage(db, userId)).toEqual({
			session_count: 2,
			step_result_count: 4,
		});
		expect(await rowCount(db, "workout_sessions", userId)).toBe(2);
		expect(await rowCount(db, "step_results", userId)).toBe(4);
		db.close();
	});

	it("keeps counting tombstones, which are still stored rows", async () => {
		const db = await createTestDatabase();
		const upload = makeApp(db);
		const { userId, token } = await signedIn(db, "a");
		await upload(token, { sessions: [session("s1")], stepResults: [step("r1", "s1")] });
		await upload(token, {
			sessions: [session("s1", { deleted: true })],
			stepResults: [step("r1", "s1", { deleted: true })],
		});
		expect(await usage(db, userId)).toEqual({
			session_count: 1,
			step_result_count: 1,
		});
		db.close();
	});

	it("still rejects duplicate ids in one request as malformed, consuming nothing", async () => {
		const db = await createTestDatabase();
		const upload = makeApp(db);
		const { userId, token } = await signedIn(db, "a");
		const response = await upload(token, {
			sessions: [session("s1"), session("s1")],
		});
		expect(response.status).toBe(400);
		expect(await usage(db, userId)).toEqual({
			session_count: 0,
			step_result_count: 0,
		});
		db.close();
	});

	it("removes the usage row with the account and leaves other users alone", async () => {
		const db = await createTestDatabase();
		const upload = makeApp(db);
		const a = await signedIn(db, "a");
		const b = await signedIn(db, "b");
		await upload(a.token, { sessions: [session("s1")], stepResults: [step("r1", "s1")] });
		await upload(b.token, { sessions: [session("s1")], stepResults: [step("r1", "s1")] });

		await hardDeleteUser(db, a.userId);

		expect(await usage(db, a.userId)).toBeNull();
		expect(await usage(db, b.userId)).toEqual({
			session_count: 1,
			step_result_count: 1,
		});
		expect(await rowCount(db, "workout_sessions", b.userId)).toBe(1);
		db.close();
	});
});

describe("session quota", () => {
	it("accepts the insert that reaches the limit exactly", async () => {
		const db = await createTestDatabase();
		const upload = makeApp(db);
		const { userId, token } = await signedIn(db, "a");
		await fillSessions(db, userId, SESSION_LIMIT - 1);

		expect((await upload(token, { sessions: [session("last")] })).status).toBe(200);
		expect(await usage(db, userId)).toMatchObject({ session_count: SESSION_LIMIT });
		db.close();
	});

	it("at the limit, accepts updates and refuses one new row with zero writes", async () => {
		const db = await createTestDatabase();
		const upload = makeApp(db);
		const { userId, token } = await signedIn(db, "a");
		await fillSessions(db, userId, SESSION_LIMIT);

		expect(
			(await upload(token, { sessions: [session("fill-1", { title: "edit" })] })).status,
		).toBe(200);
		const seqBefore = await seq(db, userId);

		await expectQuotaRejection(
			await upload(token, {
				sessions: [session("fill-2", { title: "edit" }), session("new")],
			}),
			"sessions",
		);

		expect(await seq(db, userId)).toBe(seqBefore);
		expect(await rowCount(db, "workout_sessions", userId)).toBe(SESSION_LIMIT);
		const edited = await db
			.prepare(`SELECT title FROM workout_sessions WHERE user_id = ? AND id = 'fill-2'`)
			.bind(userId)
			.first<{ title: string | null }>();
		expect(edited?.title).toBeNull();
		expect(await usage(db, userId)).toMatchObject({ session_count: SESSION_LIMIT });
		db.close();
	});

	it("rolls back the step results too when only the sessions are over", async () => {
		const db = await createTestDatabase();
		const upload = makeApp(db);
		const { userId, token } = await signedIn(db, "a");
		await fillSessions(db, userId, SESSION_LIMIT);

		await expectQuotaRejection(
			await upload(token, {
				sessions: [session("new")],
				// Under an existing session, so nothing but the quota can
				// stop these rows from landing.
				stepResults: [step("r1", "fill-1"), step("r2", "fill-2")],
			}),
			"sessions",
		);
		expect(await rowCount(db, "step_results", userId)).toBe(0);
		expect(await usage(db, userId)).toEqual({
			session_count: SESSION_LIMIT,
			step_result_count: 0,
		});
		db.close();
	});
});

describe("step result quota", () => {
	it("accepts the insert that reaches the limit exactly", async () => {
		const db = await createTestDatabase();
		const upload = makeApp(db);
		const { userId, token } = await signedIn(db, "a");
		await upload(token, { sessions: [session("s1")] });
		await fillStepResults(db, userId, "s1", STEP_RESULT_LIMIT - 1);

		expect((await upload(token, { stepResults: [step("last", "s1")] })).status).toBe(200);
		expect(await usage(db, userId)).toMatchObject({
			step_result_count: STEP_RESULT_LIMIT,
		});
		db.close();
	});

	it("at the limit, accepts updates and refuses one new row, sessions included", async () => {
		const db = await createTestDatabase();
		const upload = makeApp(db);
		const { userId, token } = await signedIn(db, "a");
		await upload(token, { sessions: [session("s1")] });
		await fillStepResults(db, userId, "s1", STEP_RESULT_LIMIT);

		expect(
			(await upload(token, { stepResults: [step("fill-1", "s1", { reps: 3 })] })).status,
		).toBe(200);
		const seqBefore = await seq(db, userId);

		await expectQuotaRejection(
			await upload(token, {
				sessions: [session("s2")],
				stepResults: [step("new", "s2")],
			}),
			"step_results",
		);

		expect(await seq(db, userId)).toBe(seqBefore);
		expect(await rowCount(db, "workout_sessions", userId)).toBe(1);
		expect(await rowCount(db, "step_results", userId)).toBe(STEP_RESULT_LIMIT);
		expect(await usage(db, userId)).toEqual({
			session_count: 1,
			step_result_count: STEP_RESULT_LIMIT,
		});
		db.close();
	});
});

describe("quota isolation and races", () => {
	it("one user's full quota does not affect another, even with the same ids", async () => {
		const db = await createTestDatabase();
		const upload = makeApp(db);
		const a = await signedIn(db, "a");
		const b = await signedIn(db, "b");
		await fillSessions(db, a.userId, SESSION_LIMIT);

		await expectQuotaRejection(
			await upload(a.token, { sessions: [session("shared")] }),
			"sessions",
		);
		// "fill-1" exists for A. For B it is new, and must be counted as new.
		expect(
			(await upload(b.token, { sessions: [session("fill-1"), session("shared")] })).status,
		).toBe(200);
		expect(await usage(db, b.userId)).toMatchObject({ session_count: 2 });
		expect(await usage(db, a.userId)).toMatchObject({ session_count: SESSION_LIMIT });
		db.close();
	});

	it("an id that only another user holds still consumes quota at the limit", async () => {
		const db = await createTestDatabase();
		const upload = makeApp(db);
		const a = await signedIn(db, "a");
		const b = await signedIn(db, "b");
		await upload(b.token, { sessions: [session("theirs")] });
		await fillSessions(db, a.userId, SESSION_LIMIT);

		await expectQuotaRejection(
			await upload(a.token, { sessions: [session("theirs")] }),
			"sessions",
		);
		db.close();
	});

	it("concurrent uploads cannot both pass the last free slot", async () => {
		const db = await createTestDatabase();
		const { userId, token } = await signedIn(db, "a");
		await fillSessions(db, userId, SESSION_LIMIT - 1);

		// Holds every write batch until all three requests have reached one,
		// so each has finished whatever it reads before anyone writes — the
		// worst interleaving, forced rather than hoped for. A check-then-write
		// quota lets all three through here; one enforced on the write cannot.
		let waiting = 3;
		let release!: () => void;
		const allArrived = new Promise<void>((resolve) => {
			release = resolve;
		});
		const barrier: TestDatabase = {
			...db,
			batch: async (statements) => {
				if (--waiting === 0) release();
				await allArrived;
				return db.batch(statements);
			},
		};
		const upload = makeApp(barrier);

		const responses = await Promise.all([
			upload(token, { sessions: [session("race-1")] }),
			upload(token, { sessions: [session("race-2")] }),
			upload(token, { sessions: [session("race-3")] }),
		]);

		expect(responses.map((r) => r.status).sort()).toEqual([200, 409, 409]);
		expect(await rowCount(db, "workout_sessions", userId)).toBe(SESSION_LIMIT);
		expect(await usage(db, userId)).toMatchObject({ session_count: SESSION_LIMIT });
		db.close();
	});

	it("a database error mid-batch leaves neither rows nor counter behind", async () => {
		const db = await createTestDatabase();
		const { userId } = await signedIn(db, "a");
		const failing: TestDatabase = {
			...db,
			batch: (statements) =>
				db.batch([
					...statements.slice(0, -1),
					db.prepare(`INSERT INTO no_such_table VALUES (1)`),
				]),
		};

		await expect(
			uploadWorkoutData(
				failing,
				userId,
				{ sessions: [{ id: "s1", startedAt: NOW }], stepResults: [] },
				NOW,
			),
		).rejects.toThrow();
		expect(await rowCount(db, "workout_sessions", userId)).toBe(0);
		expect(await usage(db, userId)).toEqual({
			session_count: 0,
			step_result_count: 0,
		});
		db.close();
	});

	it("surfaces the quota as a typed error from the repository", async () => {
		const db = await createTestDatabase();
		const { userId } = await signedIn(db, "a");
		await fillSessions(db, userId, SESSION_LIMIT);
		await expect(
			uploadWorkoutData(
				db,
				userId,
				{ sessions: [{ id: "new", startedAt: NOW }], stepResults: [] },
				NOW,
			),
		).rejects.toBeInstanceOf(SyncStorageQuotaExceededError);
		db.close();
	});
});

describe("migration 0006 on existing data", () => {
	const migrationsBefore = [
		"0001_user_auth_foundation.sql",
		"0002_auth_nonces.sql",
		"0003_provider_credentials.sql",
		"0004_account_deletions.sql",
		"0005_workout_sync.sql",
	];
	const read = (name: string) =>
		readFileSync(
			fileURLToPath(new URL(`../../migrations/${name}`, import.meta.url).href),
			"utf8",
		);

	async function historicalDatabase() {
		const { DatabaseSync } = (await import("node:sqlite")) as unknown as {
			DatabaseSync: new (path: string) => {
				exec(sql: string): void;
				prepare(sql: string): { all(...p: unknown[]): unknown[] };
				close(): void;
			};
		};
		const db = new DatabaseSync(":memory:");
		db.exec(migrationsBefore.map(read).join("\n"));
		db.exec(`
			INSERT INTO users (id, state, created_at, updated_at, deleted_at) VALUES
			  ('busy', 'active', 1, 1, NULL), ('empty', 'active', 1, 1, NULL),
			  ('leaving', 'deleting', 1, 1, 1);
			INSERT INTO workout_sessions (id, user_id, started_at, change_seq, updated_at, deleted_at) VALUES
			  ('s1', 'busy', 1, 1, 1, NULL), ('s2', 'busy', 1, 1, 1, 5);
			INSERT INTO step_results (id, user_id, session_id, exercise_name, order_index, change_seq, updated_at) VALUES
			  ('r1', 'busy', 's1', 'x', 0, 1, 1), ('r2', 'busy', 's1', 'x', 1, 1, 1), ('r3', 'busy', 's2', 'x', 0, 1, 1);
		`);
		return db;
	}

	it("backfills every user, including those with no rows, counting tombstones", async () => {
		const db = await historicalDatabase();
		db.exec(read("0006_sync_storage_quota.sql"));
		const rows = db
			.prepare(
				`SELECT user_id, session_count, step_result_count FROM user_storage_usage ORDER BY user_id`,
			)
			.all()
			.map((row) => ({ ...(row as object) }));
		expect(rows).toEqual([
			{ user_id: "busy", session_count: 2, step_result_count: 3 },
			{ user_id: "empty", session_count: 0, step_result_count: 0 },
			{ user_id: "leaving", session_count: 0, step_result_count: 0 },
		]);
		db.close();
	});

	it("fails rather than clamping when an existing user is already over quota", async () => {
		const db = await historicalDatabase();
		db.exec(`
			WITH RECURSIVE k(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM k WHERE i < ${SESSION_LIMIT + 1})
			INSERT INTO workout_sessions (id, user_id, started_at, change_seq, updated_at)
			SELECT 'over-' || i, 'empty', 1, 1, 1 FROM k;
		`);
		// In a transaction so the assertion below can show nothing survives.
		db.exec("BEGIN");
		expect(() => db.exec(read("0006_sync_storage_quota.sql"))).toThrow(
			/storage_quota_sessions/,
		);
		db.exec("ROLLBACK");
		expect(
			db.prepare(`SELECT name FROM sqlite_master WHERE name = 'user_storage_usage'`).all(),
		).toEqual([]);
		db.close();
	});
});

describe("sync row ownership is immutable", () => {
	async function twoUsersWithRows(db: TestDatabase) {
		const upload = makeApp(db);
		const a = await signedIn(db, "a");
		const b = await signedIn(db, "b");
		await upload(a.token, { sessions: [session("s1")], stepResults: [step("r1", "s1")] });
		await upload(b.token, { sessions: [session("t1")] });
		return { upload, a, b };
	}

	async function snapshot(db: TestDatabase, a: string, b: string) {
		return {
			aUsage: await usage(db, a),
			bUsage: await usage(db, b),
			aSessions: await rowCount(db, "workout_sessions", a),
			bSessions: await rowCount(db, "workout_sessions", b),
			aSteps: await rowCount(db, "step_results", a),
			bSteps: await rowCount(db, "step_results", b),
		};
	}

	it("refuses moving a session to another user, leaving rows and counters alone", async () => {
		const db = await createTestDatabase();
		const { a, b } = await twoUsersWithRows(db);
		const before = await snapshot(db, a.userId, b.userId);

		// The step result's foreign key would also refuse this move. Remove it
		// first so the trigger is the only thing that can stop the transfer.
		await db.prepare(`DELETE FROM step_results WHERE user_id = ?`).bind(a.userId).run();
		const mid = await snapshot(db, a.userId, b.userId);
		await expect(
			db
				.prepare(`UPDATE workout_sessions SET user_id = ? WHERE user_id = ? AND id = 's1'`)
				.bind(b.userId, a.userId)
				.run(),
		).rejects.toThrow(/sync_owner_is_immutable/);

		expect(await snapshot(db, a.userId, b.userId)).toEqual(mid);
		expect(mid.aSessions).toBe(before.aSessions);
		db.close();
	});

	it("refuses moving a step result to another user, leaving rows and counters alone", async () => {
		const db = await createTestDatabase();
		const { a, b } = await twoUsersWithRows(db);
		const before = await snapshot(db, a.userId, b.userId);

		await expect(
			db
				.prepare(
					`UPDATE step_results SET user_id = ?, session_id = 't1' WHERE user_id = ? AND id = 'r1'`,
				)
				.bind(b.userId, a.userId)
				.run(),
		).rejects.toThrow(/sync_owner_is_immutable/);

		expect(await snapshot(db, a.userId, b.userId)).toEqual(before);
		db.close();
	});

	it("does not touch same-owner updates and retries", async () => {
		const db = await createTestDatabase();
		const { upload, a, b } = await twoUsersWithRows(db);
		const before = await snapshot(db, a.userId, b.userId);

		const edit = {
			sessions: [session("s1", { title: "edited" })],
			stepResults: [step("r1", "s1", { reps: 8 })],
		};
		expect((await upload(a.token, edit)).status).toBe(200);
		expect((await upload(a.token, edit)).status).toBe(200);
		// Setting user_id to its own value is not a transfer.
		await db
			.prepare(`UPDATE workout_sessions SET user_id = user_id WHERE user_id = ?`)
			.bind(a.userId)
			.run();

		expect(await snapshot(db, a.userId, b.userId)).toEqual(before);
		db.close();
	});
});

describe("usage table constraints", () => {
	it("refuses a negative count under its own name, not as a quota", async () => {
		const db = await createTestDatabase();
		const { userId } = await signedIn(db, "a");
		await expect(
			db
				.prepare(`UPDATE user_storage_usage SET session_count = -1 WHERE user_id = ?`)
				.bind(userId)
				.run(),
		).rejects.toThrow(/storage_usage_sessions_nonnegative/);
		await expect(
			db
				.prepare(`UPDATE user_storage_usage SET step_result_count = -1 WHERE user_id = ?`)
				.bind(userId)
				.run(),
		).rejects.toThrow(/storage_usage_step_results_nonnegative/);
		db.close();
	});

	it("fails a sync write closed when the usage row is missing", async () => {
		const db = await createTestDatabase();
		const { userId } = await signedIn(db, "a");
		await db.prepare(`DELETE FROM user_storage_usage WHERE user_id = ?`).bind(userId).run();
		await expect(
			uploadWorkoutData(
				db,
				userId,
				{ sessions: [{ id: "s1", startedAt: NOW }], stepResults: [] },
				NOW,
			),
		).rejects.toThrow(/storage_usage_missing/);
		expect(await rowCount(db, "workout_sessions", userId)).toBe(0);
		db.close();
	});
});
