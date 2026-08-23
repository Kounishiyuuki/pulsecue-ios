/**
 * The ways this sync slice can lose data, and the guarantees that stop it.
 *
 * Every test here is about a silent failure rather than a loud one. Sync bugs
 * are not usually crashes — they are a cursor that moved one row too far, a
 * response that reported someone else's sequence, a delete that undid itself.
 * The user finds out weeks later, when the data is gone and there is nothing
 * left to reconstruct it from.
 *
 * So the assertions are deliberately about *exact* numbers: this request's own
 * sequence, this snapshot's rows, this many bind parameters. "Roughly right"
 * is the failure mode.
 */

import { Hono } from "hono";
import { describe, expect, it } from "vitest";
import { findOrCreateAccountForIdentity } from "../../src/api/db/accounts";
import { processAccountDeletion } from "../../src/api/auth/accountDeletionService";
import { TokenCipher } from "../../src/api/crypto/tokenCipher";
import {
	findUserForDeletion,
	requestAccountDeletion,
} from "../../src/api/db/accountDeletion";
import { createSession } from "../../src/api/db/sessions";
import {
	MAX_SYNC_MUTATIONS_PER_REQUEST,
	MAX_SYNC_ROWS_PER_SEQUENCE,
	SYNC_ID_CHUNK_SIZE,
	SyncAccountNotActiveError,
	SyncCorruptSequenceError,
	SyncDuplicateIdError,
	SyncPayloadTooLargeError,
	SyncTombstonedError,
	pullWorkoutData,
	uploadWorkoutData,
} from "../../src/api/db/workoutSync";
import { requireSession } from "../../src/api/middleware/requireSession";
import {
	handlePullWorkouts,
	makeUploadWorkoutsHandler,
} from "../../src/api/routes/syncWorkouts";
import type { AuthedEnv, SqlStatement } from "../../src/api/types";
import { testEncryptionKey } from "./support/appleProduction";
import { type TestDatabase, createTestDatabase } from "./support/sqliteD1";

const NOW = 1_800_000_100;

/** D1's published per-invocation and per-query ceilings. */
const D1_MAX_QUERIES_PER_INVOCATION = 1000;
const D1_MAX_BINDINGS_PER_QUERY = 100;

async function signedIn(db: TestDatabase, subject = "apple-sub-1") {
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
	app.get("/v1/sync/workouts", requireSession({ now: () => NOW }), handlePullWorkouts);

	return {
		upload: (token: string, body: unknown) =>
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
			),
		pull: (token: string, since = 0) =>
			app.request(
				`/v1/sync/workouts?since=${since}`,
				{ method: "GET", headers: { authorization: `Bearer ${token}` } },
				{ DB: db } as unknown as AuthedEnv["Bindings"],
			),
	};
}

function session(id: string, extra: Record<string, unknown> = {}) {
	return { id, startedAt: NOW, endedAt: NOW + 60, title: "s", ...extra };
}

function step(id: string, sessionId: string, extra: Record<string, unknown> = {}) {
	return {
		id,
		sessionId,
		exerciseName: "bench",
		orderIndex: 0,
		reps: 8,
		...extra,
	};
}

// ---------------------------------------------------------------------------
// A. The response must carry this request's own sequence
// ---------------------------------------------------------------------------

describe("the sequence an upload reports", () => {
	it("is the one its own rows were written at, not whatever is current", async () => {
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);

			const first = await uploadWorkoutData(
				db,
				user.userId,
				{ sessions: [session("s1")], stepResults: [] },
				NOW,
			);
			const second = await uploadWorkoutData(
				db,
				user.userId,
				{ sessions: [session("s2")], stepResults: [] },
				NOW,
			);

			const rows = await db
				.prepare(
					`SELECT id, change_seq FROM workout_sessions WHERE user_id = ? ORDER BY id`,
				)
				.bind(user.userId)
				.all<{ id: string; change_seq: number }>();

			const seqById = new Map(rows.results.map((r) => [r.id, r.change_seq]));
			expect(first.changeSeq).toBe(seqById.get("s1"));
			expect(second.changeSeq).toBe(seqById.get("s2"));
			expect(first.changeSeq).toBeLessThan(second.changeSeq);
		} finally {
			db.close();
		}
	});

	it("does not report a later upload's sequence when one interleaves", async () => {
		// The concurrency this reproduces deterministically: B commits between
		// A's write and A reading its sequence back. The old code read the
		// sequence with a fresh SELECT after the batch, so A returned B's
		// number, and A's client stored a cursor past rows it never received.
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);

			let interleaved = false;
			const interleaving: TestDatabase = {
				...db,
				batch: async <T>(statements: SqlStatement[]) => {
					const result = await db.batch<T>(statements);
					if (!interleaved) {
						// Exactly at the moment A's batch has committed and A
						// has not yet produced its response.
						interleaved = true;
						await uploadWorkoutData(
							db,
							user.userId,
							{ sessions: [session("s-b")], stepResults: [] },
							NOW,
						);
					}
					return result;
				},
			};

			const a = await uploadWorkoutData(
				interleaving,
				user.userId,
				{ sessions: [session("s-a")], stepResults: [] },
				NOW,
			);

			const aRow = await db
				.prepare(
					`SELECT change_seq FROM workout_sessions WHERE user_id = ? AND id = 's-a'`,
				)
				.bind(user.userId)
				.first<{ change_seq: number }>();
			const bRow = await db
				.prepare(
					`SELECT change_seq FROM workout_sessions WHERE user_id = ? AND id = 's-b'`,
				)
				.bind(user.userId)
				.first<{ change_seq: number }>();

			expect(interleaved).toBe(true);
			expect(a.changeSeq).toBe(aRow?.change_seq);
			expect(a.changeSeq).not.toBe(bRow?.change_seq);
			expect(a.changeSeq).toBeLessThan(bRow?.change_seq ?? 0);
		} finally {
			db.close();
		}
	});
});

// ---------------------------------------------------------------------------
// B. A pull describes one instant
// ---------------------------------------------------------------------------

describe("a pull snapshot", () => {
	it("excludes a write that lands while the page is being read", async () => {
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);
			await uploadWorkoutData(
				db,
				user.userId,
				{ sessions: [session("s1")], stepResults: [] },
				NOW,
			);

			// Ordered, not raced: the concurrent upload is awaited *inside*
			// the snapshot query's resolution, so it is committed before the
			// first page query runs and after the snapshot was taken. A
			// fire-and-forget write here would simply never land in time and
			// the test would pass for the wrong reason.
			let injected = false;
			const injecting: TestDatabase = {
				...db,
				prepare: (sql: string) => {
					const statement = db.prepare(sql);
					if (injected || !sql.includes("user_change_seq AS s")) {
						return statement;
					}
					return {
						...statement,
						bind: (...values: unknown[]) => {
							const bound = statement.bind(...values);
							return {
								...bound,
								first: async <T>() => {
									const row = await bound.first<T>();
									injected = true;
									await uploadWorkoutData(
										db,
										user.userId,
										{ sessions: [session("s2")], stepResults: [] },
										NOW,
									);
									return row;
								},
							};
						},
					};
				},
			};

			const page = await pullWorkoutData(injecting, user.userId, 0, 500);
			const ids = page.sessions.map((row) => row.id);

			expect(ids).toContain("s1");
			expect(ids).not.toContain("s2");
			// And the cursor did not run past the row it withheld.
			const s2 = await db
				.prepare(
					`SELECT change_seq FROM workout_sessions WHERE user_id = ? AND id = 's2'`,
				)
				.bind(user.userId)
				.first<{ change_seq: number }>();
			expect(page.changeSeq).toBeLessThan(s2?.change_seq ?? 0);
		} finally {
			db.close();
		}
	});

	it("delivers the later write on the next pull", async () => {
		// Excluded once is fine; excluded forever is data loss.
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);
			const first = await uploadWorkoutData(
				db,
				user.userId,
				{ sessions: [session("s1")], stepResults: [] },
				NOW,
			);
			const page1 = await pullWorkoutData(db, user.userId, 0, 500);
			expect(page1.sessions.map((r) => r.id)).toEqual(["s1"]);

			await uploadWorkoutData(
				db,
				user.userId,
				{ sessions: [session("s2")], stepResults: [] },
				NOW,
			);

			const page2 = await pullWorkoutData(db, user.userId, page1.changeSeq, 500);
			expect(page2.sessions.map((r) => r.id)).toEqual(["s2"]);
			expect(page1.changeSeq).toBe(first.changeSeq);
		} finally {
			db.close();
		}
	});
});

// ---------------------------------------------------------------------------
// C/D/E. Size and D1 budget
// ---------------------------------------------------------------------------

describe("upload size limits", () => {
	it("are enforced by the repository, not only by the route", async () => {
		// An internal caller that wrote an oversized sequence would create data
		// the pull path refuses to deliver — permanent loss for that user.
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);
			const sessions = Array.from(
				{ length: MAX_SYNC_MUTATIONS_PER_REQUEST + 1 },
				(_, i) => session(`s${i}`),
			);

			await expect(
				uploadWorkoutData(db, user.userId, { sessions, stepResults: [] }, NOW),
			).rejects.toBeInstanceOf(SyncPayloadTooLargeError);

			expect(await db.count("workout_sessions")).toBe(0);
		} finally {
			db.close();
		}
	});

	it("counts sessions and step results together", async () => {
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);
			// Each array is individually acceptable; together they are one
			// over the cap, which is the case a per-array limit would miss.
			const sessionCount = Math.ceil(MAX_SYNC_MUTATIONS_PER_REQUEST / 2) + 1;
			const stepCount =
				MAX_SYNC_MUTATIONS_PER_REQUEST + 1 - sessionCount;
			const sessions = Array.from({ length: sessionCount }, (_, i) =>
				session(`s${i}`),
			);
			const stepResults = Array.from({ length: stepCount }, (_, i) =>
				step(`r${i}`, "s0"),
			);

			await expect(
				uploadWorkoutData(db, user.userId, { sessions, stepResults }, NOW),
			).rejects.toBeInstanceOf(SyncPayloadTooLargeError);
		} finally {
			db.close();
		}
	});

	it("never let a sequence exceed what the pull path can deliver", () => {
		// The two numbers are coupled, so the coupling is pinned rather than
		// described in a comment somebody later edits one half of.
		expect(MAX_SYNC_MUTATIONS_PER_REQUEST).toBeLessThanOrEqual(
			MAX_SYNC_ROWS_PER_SEQUENCE,
		);
	});
});

describe("the D1 budget for the largest valid upload", () => {
	it("stays inside the query and parameter limits", async () => {
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);

			// The worst shape: every step result points at a session that is
			// already stored, so every id has to be looked up.
			await uploadWorkoutData(
				db,
				user.userId,
				{ sessions: [session("host")], stepResults: [] },
				NOW,
			);

			const stepResults = Array.from(
				{ length: MAX_SYNC_MUTATIONS_PER_REQUEST },
				(_, i) => step(`r${i}`, "host"),
			);

			const app = makeApp(db);
			db.resetRecording();
			const response = await app.upload(user.token, { sessions: [], stepResults });
			expect(response.status).toBe(200);

			const recorded = db.recorded();
			const worstBindings = Math.max(...recorded.map((q) => q.bindings));

			expect(recorded.length).toBeLessThan(D1_MAX_QUERIES_PER_INVOCATION);
			expect(worstBindings).toBeLessThanOrEqual(D1_MAX_BINDINGS_PER_QUERY);
		} finally {
			db.close();
		}
	});

	it("chunks id lookups so no single query overruns the parameter limit", async () => {
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);
			const sessions = Array.from({ length: 200 }, (_, i) => session(`s${i}`));
			await uploadWorkoutData(db, user.userId, { sessions, stepResults: [] }, NOW);

			// 200 step results against 200 already-stored sessions: the lookup
			// has 200 ids to resolve and must not bind them in one query.
			const stepResults = Array.from({ length: 200 }, (_, i) =>
				step(`r${i}`, `s${i}`),
			);

			db.resetRecording();
			await uploadWorkoutData(db, user.userId, { sessions: [], stepResults }, NOW);

			const lookups = db
				.recorded()
				.filter((q) => q.sql.includes("IN ("));
			expect(lookups.length).toBeGreaterThan(1);
			for (const query of lookups) {
				expect(query.bindings).toBeLessThanOrEqual(D1_MAX_BINDINGS_PER_QUERY);
				expect(query.bindings).toBeLessThanOrEqual(SYNC_ID_CHUNK_SIZE + 1);
			}
		} finally {
			db.close();
		}
	});
});

// ---------------------------------------------------------------------------
// F. An impossible sequence must fail loudly
// ---------------------------------------------------------------------------

describe("a stored sequence larger than any upload could write", () => {
	it("fails the pull instead of truncating it and advancing the cursor", async () => {
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);
			// Written behind the repository's back, which is the only way this
			// state can exist at all.
			for (let i = 0; i < MAX_SYNC_ROWS_PER_SEQUENCE + 1; i += 1) {
				await db
					.prepare(
						`INSERT INTO workout_sessions
						   (id, user_id, started_at, ended_at, title, change_seq, updated_at, deleted_at)
						 VALUES (?, ?, ?, ?, ?, 1, ?, NULL)`,
					)
					.bind(`s${i}`, user.userId, NOW, NOW + 1, "s", NOW)
					.run();
			}
			// Publish the sequence, or the snapshot bound excludes these rows
			// and the pull is trivially empty for an unrelated reason.
			await db
				.prepare(`UPDATE user_change_seq SET seq = 1 WHERE user_id = ?`)
				.bind(user.userId)
				.run();

			await expect(
				pullWorkoutData(db, user.userId, 0, 10),
			).rejects.toBeInstanceOf(SyncCorruptSequenceError);

			// The cursor is a client-side value; what matters is that no page
			// was produced that would move it. Nothing was deleted either.
			expect(await db.count("workout_sessions")).toBe(
				MAX_SYNC_ROWS_PER_SEQUENCE + 1,
			);
		} finally {
			db.close();
		}
	});

	it("cannot be produced through the repository", async () => {
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);
			const sessions = Array.from(
				{ length: MAX_SYNC_MUTATIONS_PER_REQUEST },
				(_, i) => session(`s${i}`),
			);
			const result = await uploadWorkoutData(
				db,
				user.userId,
				{ sessions, stepResults: [] },
				NOW,
			);

			const row = await db
				.prepare(
					`SELECT COUNT(*) AS n FROM workout_sessions WHERE user_id = ? AND change_seq = ?`,
				)
				.bind(user.userId, result.changeSeq)
				.first<{ n: number }>();

			expect(row?.n).toBeLessThanOrEqual(MAX_SYNC_ROWS_PER_SEQUENCE);
		} finally {
			db.close();
		}
	});
});

// ---------------------------------------------------------------------------
// G. A tombstone is terminal
// ---------------------------------------------------------------------------

describe("a deleted record", () => {
	it("is not brought back by a stale live upload of the same session", async () => {
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);
			await uploadWorkoutData(
				db,
				user.userId,
				{ sessions: [session("s1")], stepResults: [] },
				NOW,
			);
			await uploadWorkoutData(
				db,
				user.userId,
				{ sessions: [session("s1", { deleted: true })], stepResults: [] },
				NOW,
			);

			await expect(
				uploadWorkoutData(
					db,
					user.userId,
					{ sessions: [session("s1")], stepResults: [] },
					NOW,
				),
			).rejects.toBeInstanceOf(SyncTombstonedError);

			const row = await db
				.prepare(
					`SELECT deleted_at FROM workout_sessions WHERE user_id = ? AND id = 's1'`,
				)
				.bind(user.userId)
				.first<{ deleted_at: number | null }>();
			expect(row?.deleted_at).not.toBeNull();

			const page = await pullWorkoutData(db, user.userId, 0, 500);
			expect(page.sessions.find((r) => r.id === "s1")?.deleted_at).not.toBeNull();
		} finally {
			db.close();
		}
	});

	it("is not brought back by a stale live upload of the same step result", async () => {
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);
			await uploadWorkoutData(
				db,
				user.userId,
				{ sessions: [session("s1")], stepResults: [step("r1", "s1")] },
				NOW,
			);
			await uploadWorkoutData(
				db,
				user.userId,
				{ sessions: [], stepResults: [step("r1", "s1", { deleted: true })] },
				NOW,
			);

			await expect(
				uploadWorkoutData(
					db,
					user.userId,
					{ sessions: [], stepResults: [step("r1", "s1")] },
					NOW,
				),
			).rejects.toBeInstanceOf(SyncTombstonedError);

			const row = await db
				.prepare(
					`SELECT deleted_at FROM step_results WHERE user_id = ? AND id = 'r1'`,
				)
				.bind(user.userId)
				.first<{ deleted_at: number | null }>();
			expect(row?.deleted_at).not.toBeNull();
		} finally {
			db.close();
		}
	});

	it("accepts the same delete again", async () => {
		// Retrying a delete is normal and must stay idempotent.
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);
			await uploadWorkoutData(
				db,
				user.userId,
				{ sessions: [session("s1")], stepResults: [] },
				NOW,
			);
			await uploadWorkoutData(
				db,
				user.userId,
				{ sessions: [session("s1", { deleted: true })], stepResults: [] },
				NOW,
			);
			await expect(
				uploadWorkoutData(
					db,
					user.userId,
					{ sessions: [session("s1", { deleted: true })], stepResults: [] },
					NOW,
				),
			).resolves.toMatchObject({ sessions: 1 });
		} finally {
			db.close();
		}
	});

	it("is refused with a 409 through the route", async () => {
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);
			const app = makeApp(db);
			await app.upload(user.token, { sessions: [session("s1")], stepResults: [] });
			await app.upload(user.token, {
				sessions: [session("s1", { deleted: true })],
				stepResults: [],
			});

			const response = await app.upload(user.token, {
				sessions: [session("s1")],
				stepResults: [],
			});

			expect(response.status).toBe(409);
			const body = (await response.json()) as { error: { code: string } };
			expect(body.error.code).toBe("record_deleted");
		} finally {
			db.close();
		}
	});
});

// ---------------------------------------------------------------------------
// H/I/L. An account that stops being active mid-request
// ---------------------------------------------------------------------------

describe("an account that starts deleting after the request was authenticated", () => {
	it("cannot have new sync rows written for it", async () => {
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);

			// The window: authenticated, then the account changes underneath.
			await requestAccountDeletion(db, user.userId, NOW);

			await expect(
				uploadWorkoutData(
					db,
					user.userId,
					{ sessions: [session("s1")], stepResults: [] },
					NOW,
				),
			).rejects.toBeInstanceOf(SyncAccountNotActiveError);

			expect(await db.count("workout_sessions")).toBe(0);
		} finally {
			db.close();
		}
	});

	it("does not advance the sequence on a refused write", async () => {
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);
			const before = await db
				.prepare(`SELECT seq FROM user_change_seq WHERE user_id = ?`)
				.bind(user.userId)
				.first<{ seq: number }>();

			await requestAccountDeletion(db, user.userId, NOW);
			await expect(
				uploadWorkoutData(
					db,
					user.userId,
					{ sessions: [session("s1")], stepResults: [] },
					NOW,
				),
			).rejects.toBeInstanceOf(SyncAccountNotActiveError);

			const after = await db
				.prepare(`SELECT seq FROM user_change_seq WHERE user_id = ?`)
				.bind(user.userId)
				.first<{ seq: number }>();
			expect(after?.seq).toBe(before?.seq);
		} finally {
			db.close();
		}
	});

	it("is not served any sync rows on pull", async () => {
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);
			await uploadWorkoutData(
				db,
				user.userId,
				{ sessions: [session("s1")], stepResults: [step("r1", "s1")] },
				NOW,
			);

			await requestAccountDeletion(db, user.userId, NOW);

			await expect(
				pullWorkoutData(db, user.userId, 0, 500),
			).rejects.toBeInstanceOf(SyncAccountNotActiveError);
		} finally {
			db.close();
		}
	});

	it("cannot write even through an empty upload", async () => {
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);
			await requestAccountDeletion(db, user.userId, NOW);

			await expect(
				uploadWorkoutData(
					db,
					user.userId,
					{ sessions: [], stepResults: [] },
					NOW,
				),
			).rejects.toBeInstanceOf(SyncAccountNotActiveError);
		} finally {
			db.close();
		}
	});

	it("gets no sync endpoint access at all once deleting", async () => {
		// The session was revoked by the deletion, so the middleware refuses
		// first — and the repository would refuse anyway. Both layers hold.
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);
			const app = makeApp(db);
			await requestAccountDeletion(db, user.userId, NOW);

			const upload = await app.upload(user.token, {
				sessions: [session("s1")],
				stepResults: [],
			});
			const pull = await app.pull(user.token);

			expect(upload.status).toBe(401);
			expect(pull.status).toBe(401);
			expect(await db.count("workout_sessions")).toBe(0);
		} finally {
			db.close();
		}
	});
});

// ---------------------------------------------------------------------------
// K. Duplicate ids in one request
// ---------------------------------------------------------------------------

describe("a request that names the same record twice", () => {
	it("is refused rather than resolved by statement order", async () => {
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);
			await expect(
				uploadWorkoutData(
					db,
					user.userId,
					{
						sessions: [session("s1"), session("s1", { title: "other" })],
						stepResults: [],
					},
					NOW,
				),
			).rejects.toBeInstanceOf(SyncDuplicateIdError);
			expect(await db.count("workout_sessions")).toBe(0);
		} finally {
			db.close();
		}
	});

	it("is refused for duplicate step results too", async () => {
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);
			await expect(
				uploadWorkoutData(
					db,
					user.userId,
					{
						sessions: [session("s1")],
						stepResults: [step("r1", "s1"), step("r1", "s1", { reps: 9 })],
					},
					NOW,
				),
			).rejects.toBeInstanceOf(SyncDuplicateIdError);
		} finally {
			db.close();
		}
	});

	it("still allows a session and a step result to share an id", async () => {
		// Separate id spaces. Refusing this would reject legitimate payloads.
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);
			await expect(
				uploadWorkoutData(
					db,
					user.userId,
					{ sessions: [session("x")], stepResults: [step("x", "x")] },
					NOW,
				),
			).resolves.toMatchObject({ sessions: 1, stepResults: 1 });
		} finally {
			db.close();
		}
	});

	it("is a 400 through the route", async () => {
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);
			const app = makeApp(db);
			const response = await app.upload(user.token, {
				sessions: [session("s1"), session("s1")],
				stepResults: [],
			});
			expect(response.status).toBe(400);
		} finally {
			db.close();
		}
	});
});

// ---------------------------------------------------------------------------
// J. Deleting the account really removes the synced data
// ---------------------------------------------------------------------------

//  The schema's cascade is only half the guarantee. What matters is that the
//  *deletion service* — the code that actually runs when a user asks to be
//  forgotten — reaches these tables. A foreign key proves the database would
//  cascade if someone deleted the user row; it proves nothing about whether
//  anybody does.

describe("finishing an account deletion", () => {
	it("removes the user's synced workouts and step results", async () => {
		const db = await createTestDatabase();
		try {
			const c = new TokenCipher({ version: 1, material: testEncryptionKey() });
			const account = await findOrCreateAccountForIdentity(
				db,
				{ provider: "google", subject: "google-sub-1" },
				NOW,
			);
			await createSession(db, account.user.id, { now: NOW });

			await uploadWorkoutData(
				db,
				account.user.id,
				{
					sessions: [session("s1"), session("s2")],
					stepResults: [step("r1", "s1"), step("r2", "s2")],
				},
				NOW,
			);
			expect(await db.count("workout_sessions")).toBe(2);
			expect(await db.count("step_results")).toBe(2);

			await requestAccountDeletion(db, account.user.id, NOW);
			const outcome = await processAccountDeletion(
				{ db, appleConfig: null, cipher: c },
				account.user.id,
				NOW,
			);

			expect(outcome.status).toBe("completed");
			expect(await findUserForDeletion(db, account.user.id)).toBeNull();
			expect(await db.count("workout_sessions")).toBe(0);
			expect(await db.count("step_results")).toBe(0);
		} finally {
			db.close();
		}
	});
});

// ---------------------------------------------------------------------------
// The database itself enforces the two write rules
// ---------------------------------------------------------------------------

//  These bypass the repository entirely and write raw SQL, which is the point:
//  the application checks are a courtesy that produces good error messages,
//  and the triggers are what make the rule true for every caller — including
//  a future endpoint, a migration script, or a console session.

describe("the migration's write triggers", () => {
	it("refuse a direct insert for an account that is deleting", async () => {
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);
			await requestAccountDeletion(db, user.userId, NOW);

			await expect(
				db
					.prepare(
						`INSERT INTO workout_sessions
						   (id, user_id, started_at, ended_at, title, change_seq, updated_at, deleted_at)
						 VALUES ('s1', ?, ?, ?, 's', 1, ?, NULL)`,
					)
					.bind(user.userId, NOW, NOW + 1, NOW)
					.run(),
			).rejects.toThrow(/sync_user_not_active/);
		} finally {
			db.close();
		}
	});

	it("refuse a direct update that clears a tombstone", async () => {
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);
			await uploadWorkoutData(
				db,
				user.userId,
				{ sessions: [session("s1", { deleted: true })], stepResults: [] },
				NOW,
			);

			await expect(
				db
					.prepare(
						`UPDATE workout_sessions SET deleted_at = NULL
						  WHERE user_id = ? AND id = 's1'`,
					)
					.bind(user.userId)
					.run(),
			).rejects.toThrow(/sync_tombstone_is_terminal/);
		} finally {
			db.close();
		}
	});

	it("still allow a tombstone to be written and rewritten", async () => {
		const db = await createTestDatabase();
		try {
			const user = await signedIn(db);
			await uploadWorkoutData(
				db,
				user.userId,
				{ sessions: [session("s1")], stepResults: [] },
				NOW,
			);
			await expect(
				db
					.prepare(
						`UPDATE workout_sessions SET deleted_at = ?
						  WHERE user_id = ? AND id = 's1'`,
					)
					.bind(NOW, user.userId)
					.run(),
			).resolves.toBeDefined();
		} finally {
			db.close();
		}
	});

	it("keep one user out of another's rows", async () => {
		// The ownership guarantee this slice is built on, re-pinned after the
		// trigger changes: same UUID, different user, no interference.
		const db = await createTestDatabase();
		try {
			const a = await signedIn(db, "apple-sub-a");
			const b = await signedIn(db, "apple-sub-b");

			await uploadWorkoutData(
				db,
				a.userId,
				{ sessions: [session("shared")], stepResults: [] },
				NOW,
			);
			await uploadWorkoutData(
				db,
				b.userId,
				{ sessions: [session("shared", { title: "b" })], stepResults: [] },
				NOW,
			);

			const aPage = await pullWorkoutData(db, a.userId, 0, 500);
			expect(aPage.sessions).toHaveLength(1);
			expect(aPage.sessions[0]?.title).toBe("s");

			// B tombstoning its own copy leaves A's alone.
			await uploadWorkoutData(
				db,
				b.userId,
				{ sessions: [session("shared", { deleted: true })], stepResults: [] },
				NOW,
			);
			const aAfter = await pullWorkoutData(db, a.userId, 0, 500);
			expect(aAfter.sessions[0]?.deleted_at).toBeNull();
		} finally {
			db.close();
		}
	});
});
