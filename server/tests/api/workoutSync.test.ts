import { Hono } from "hono";
import { describe, expect, it } from "vitest";
import { findOrCreateAccountForIdentity } from "../../src/api/db/accounts";
import { createSession } from "../../src/api/db/sessions";
import {
	SyncOwnershipError,
	currentChangeSeq,
	pullWorkoutData,
	uploadWorkoutData,
} from "../../src/api/db/workoutSync";
import { requireSession } from "../../src/api/middleware/requireSession";
import {
	handlePullWorkouts,
	makeUploadWorkoutsHandler,
} from "../../src/api/routes/syncWorkouts";
import type { AuthedEnv } from "../../src/api/types";
import { type TestDatabase, createTestDatabase } from "./support/sqliteD1";

const NOW = 1_800_000_100;

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
		upload: (token: string | undefined, body: unknown) =>
			app.request(
				"/v1/sync/workouts",
				{
					method: "POST",
					headers: token
						? { authorization: `Bearer ${token}`, "content-type": "application/json" }
						: { "content-type": "application/json" },
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

const session = (id: string) => ({
	id,
	startedAt: NOW - 3600,
	endedAt: NOW - 1800,
	title: "Push day",
});

const stepResult = (id: string, sessionId: string, order = 0) => ({
	id,
	sessionId,
	exerciseName: "Bench Press",
	orderIndex: order,
	reps: 8,
	weightKg: 60,
	completedAt: NOW - 3000,
});

describe("uploading a guest's workouts", () => {
	it("stores nothing and does not move the cursor for an empty upload", async () => {
		// Advancing the sequence with no rows behind it would hand other
		// devices a cursor move that returns nothing.
		const db = await createTestDatabase();
		const { userId } = await signedIn(db);

		const result = await uploadWorkoutData(db, userId, { sessions: [], stepResults: [] }, NOW);

		expect(result).toEqual({ changeSeq: 0, sessions: 0, stepResults: 0 });
		expect(await currentChangeSeq(db, userId)).toBe(0);
		db.close();
	});

	it("writes sessions and their step results at one sequence", async () => {
		const db = await createTestDatabase();
		const { userId } = await signedIn(db);

		const result = await uploadWorkoutData(
			db,
			userId,
			{
				sessions: [session("s1"), session("s2")],
				stepResults: [stepResult("r1", "s1"), stepResult("r2", "s1", 1)],
			},
			NOW,
		);

		expect(result).toMatchObject({ changeSeq: 1, sessions: 2, stepResults: 2 });
		expect(await db.count("workout_sessions")).toBe(2);
		expect(await db.count("step_results")).toBe(2);

		// Every row carries the sequence the batch published.
		const rows = await db
			.prepare(`SELECT change_seq FROM workout_sessions UNION SELECT change_seq FROM step_results`)
			.all<{ change_seq: number }>();
		expect(rows.results.map((row) => row.change_seq)).toEqual([1]);
		db.close();
	});

	it("advances the sequence once per upload, not once per row", async () => {
		const db = await createTestDatabase();
		const { userId } = await signedIn(db);

		await uploadWorkoutData(db, userId, { sessions: [session("s1")], stepResults: [] }, NOW);
		await uploadWorkoutData(db, userId, { sessions: [session("s2")], stepResults: [] }, NOW);

		expect(await currentChangeSeq(db, userId)).toBe(2);
		db.close();
	});
});

describe("the sequence and the rows move together", () => {
	it("leaves the cursor untouched when the batch fails", async () => {
		// The failure this guards: a published sequence with no rows behind
		// it, or rows a pull will never return because the cursor never moved.
		const db = await createTestDatabase();
		const { userId } = await signedIn(db);
		await uploadWorkoutData(db, userId, { sessions: [session("s1")], stepResults: [] }, NOW);
		expect(await currentChangeSeq(db, userId)).toBe(1);

		await expect(
			uploadWorkoutData(
				db,
				userId,
				{
					sessions: [session("s2")],
					// `exerciseName` violates NOT NULL, so the batch rolls back.
					stepResults: [
						{ ...stepResult("r1", "s2"), exerciseName: null as unknown as string },
					],
				},
				NOW,
			),
		).rejects.toThrow();

		expect(await currentChangeSeq(db, userId)).toBe(1);
		expect(await db.count("workout_sessions")).toBe(1);
		expect(await db.count("step_results")).toBe(0);
		db.close();
	});

	it("never publishes a sequence a pull cannot reach", async () => {
		const db = await createTestDatabase();
		const { userId } = await signedIn(db);
		await uploadWorkoutData(
			db,
			userId,
			{ sessions: [session("s1")], stepResults: [stepResult("r1", "s1")] },
			NOW,
		);

		const seq = await currentChangeSeq(db, userId);
		const pulled = await pullWorkoutData(db, userId, seq - 1);

		expect(pulled.sessions).toHaveLength(1);
		expect(pulled.stepResults).toHaveLength(1);
		expect(pulled.changeSeq).toBe(seq);
		db.close();
	});
});

describe("retrying an upload", () => {
	it("does not duplicate anything", async () => {
		// The guest migration will be retried over flaky networks. A retry has
		// to converge, not accumulate.
		const db = await createTestDatabase();
		const { userId } = await signedIn(db);
		const payload = {
			sessions: [session("s1")],
			stepResults: [stepResult("r1", "s1")],
		};

		await uploadWorkoutData(db, userId, payload, NOW);
		await uploadWorkoutData(db, userId, payload, NOW);
		await uploadWorkoutData(db, userId, payload, NOW);

		expect(await db.count("workout_sessions")).toBe(1);
		expect(await db.count("step_results")).toBe(1);
		db.close();
	});

	it("converges on the newest content for the same id", async () => {
		const db = await createTestDatabase();
		const { userId } = await signedIn(db);

		await uploadWorkoutData(
			db, userId, { sessions: [{ ...session("s1"), title: "First" }], stepResults: [] }, NOW,
		);
		await uploadWorkoutData(
			db, userId, { sessions: [{ ...session("s1"), title: "Second" }], stepResults: [] }, NOW,
		);

		const row = await db
			.prepare(`SELECT title, change_seq FROM workout_sessions WHERE id = 's1'`)
			.first<{ title: string; change_seq: number }>();
		expect(row?.title).toBe("Second");
		// The rows really were written again, so the cursor must move past
		// them or a pull would skip the update.
		expect(row?.change_seq).toBe(2);
		db.close();
	});

	it("marks a delete rather than removing the row, so other devices see it", async () => {
		const db = await createTestDatabase();
		const { userId } = await signedIn(db);
		await uploadWorkoutData(db, userId, { sessions: [session("s1")], stepResults: [] }, NOW);

		await uploadWorkoutData(
			db, userId, { sessions: [{ ...session("s1"), deleted: true }], stepResults: [] }, NOW,
		);

		const row = await db
			.prepare(`SELECT deleted_at FROM workout_sessions WHERE id = 's1'`)
			.first<{ deleted_at: number | null }>();
		expect(row?.deleted_at).toBe(NOW);
		// A pull still returns it, flagged, so the other device learns of it.
		const pulled = await pullWorkoutData(db, userId, 1);
		expect(pulled.sessions).toHaveLength(1);
		db.close();
	});
});

describe("ownership", () => {
	it("gives two users their own row for the same UUID", async () => {
		// With a bare `id` primary key, a replayed UUID would land on the
		// other user's row. `(user_id, id)` makes that unrepresentable.
		const db = await createTestDatabase();
		const alice = await signedIn(db, "apple-alice");
		const bob = await signedIn(db, "apple-bob");

		await uploadWorkoutData(
			db, alice.userId, { sessions: [{ ...session("shared-uuid"), title: "Alice" }], stepResults: [] }, NOW,
		);
		await uploadWorkoutData(
			db, bob.userId, { sessions: [{ ...session("shared-uuid"), title: "Bob" }], stepResults: [] }, NOW,
		);

        expect(await db.count("workout_sessions")).toBe(2);
		const forAlice = await pullWorkoutData(db, alice.userId, 0);
		const forBob = await pullWorkoutData(db, bob.userId, 0);
		expect(forAlice.sessions.map((s) => s.title)).toEqual(["Alice"]);
		expect(forBob.sessions.map((s) => s.title)).toEqual(["Bob"]);
		db.close();
	});

	it("never returns another user's rows", async () => {
		const db = await createTestDatabase();
		const alice = await signedIn(db, "apple-alice");
		const bob = await signedIn(db, "apple-bob");
		await uploadWorkoutData(
			db, alice.userId, { sessions: [session("s1")], stepResults: [stepResult("r1", "s1")] }, NOW,
		);

		const forBob = await pullWorkoutData(db, bob.userId, 0);

		expect(forBob.sessions).toHaveLength(0);
		expect(forBob.stepResults).toHaveLength(0);
		db.close();
	});

	it("refuses a step result that names a session belonging to someone else", async () => {
		const db = await createTestDatabase();
		const alice = await signedIn(db, "apple-alice");
		const bob = await signedIn(db, "apple-bob");
		await uploadWorkoutData(db, alice.userId, { sessions: [session("alice-session")], stepResults: [] }, NOW);

		await expect(
			uploadWorkoutData(
				db, bob.userId, { sessions: [], stepResults: [stepResult("r1", "alice-session")] }, NOW,
			),
		).rejects.toBeInstanceOf(SyncOwnershipError);

		expect(await db.count("step_results")).toBe(0);
		db.close();
	});

	it("refuses a step result whose session does not exist at all", async () => {
		const db = await createTestDatabase();
		const { userId } = await signedIn(db);

		await expect(
			uploadWorkoutData(
				db, userId, { sessions: [], stepResults: [stepResult("r1", "no-such-session")] }, NOW,
			),
		).rejects.toBeInstanceOf(SyncOwnershipError);
		db.close();
	});

	it("accepts a step result for a session already stored", async () => {
		const db = await createTestDatabase();
		const { userId } = await signedIn(db);
		await uploadWorkoutData(db, userId, { sessions: [session("s1")], stepResults: [] }, NOW);

		await uploadWorkoutData(db, userId, { sessions: [], stepResults: [stepResult("r1", "s1")] }, NOW);

		expect(await db.count("step_results")).toBe(1);
		db.close();
	});

	it("goes away with the account", async () => {
		const db = await createTestDatabase();
		const { userId } = await signedIn(db);
		await uploadWorkoutData(
			db, userId, { sessions: [session("s1")], stepResults: [stepResult("r1", "s1")] }, NOW,
		);

		await db.prepare(`DELETE FROM users WHERE id = ?`).bind(userId).run();

		expect(await db.count("workout_sessions")).toBe(0);
		expect(await db.count("step_results")).toBe(0);
		db.close();
	});
});

describe("the sync endpoints", () => {
	it("uploads and pulls back for the authenticated user", async () => {
		const db = await createTestDatabase();
		const { token } = await signedIn(db);
		const app = makeApp(db);

		const uploaded = await app.upload(token, {
			sessions: [session("s1")],
			stepResults: [stepResult("r1", "s1")],
		});
		expect(uploaded.status).toBe(200);
		expect(await uploaded.json()).toMatchObject({
			changeSeq: 1,
			sessions: 1,
			stepResults: 1,
		});

		const pulled = await app.pull(token, 0);
		const body = (await pulled.json()) as {
			sessions: Array<{ id: string; deleted: boolean }>;
			stepResults: Array<{ id: string }>;
		};
		expect(body.sessions.map((s) => s.id)).toEqual(["s1"]);
		expect(body.stepResults.map((r) => r.id)).toEqual(["r1"]);
		db.close();
	});

	it("requires a session", async () => {
		const db = await createTestDatabase();
		const app = makeApp(db);

		const response = await app.upload(undefined, { sessions: [session("s1")], stepResults: [] });

		expect(response.status).toBe(401);
		expect(await db.count("workout_sessions")).toBe(0);
		db.close();
	});

	it("shows one user nothing of another's", async () => {
		const db = await createTestDatabase();
		const alice = await signedIn(db, "apple-alice");
		const bob = await signedIn(db, "apple-bob");
		const app = makeApp(db);
		await app.upload(alice.token, { sessions: [session("s1")], stepResults: [] });

		const body = (await (await app.pull(bob.token, 0)).json()) as {
			sessions: unknown[];
		};

		expect(body.sessions).toHaveLength(0);
		db.close();
	});

	it("rejects a malformed payload without writing anything", async () => {
		const db = await createTestDatabase();
		const { token } = await signedIn(db);
		const app = makeApp(db);

		for (const body of [
			{ sessions: [{ id: "", startedAt: 1 }], stepResults: [] },
			{ sessions: [{ id: "s1" }], stepResults: [] },
			{ sessions: "not an array", stepResults: [] },
			{ sessions: [], stepResults: [{ id: "r1", sessionId: "s1" }] },
		]) {
			const response = await app.upload(token, body);
			expect(response.status).toBe(400);
		}
		expect(await db.count("workout_sessions")).toBe(0);
		db.close();
	});

	it("caps how much one request may write", async () => {
		const db = await createTestDatabase();
		const { token } = await signedIn(db);
		const app = makeApp(db);

		const response = await app.upload(token, {
			sessions: Array.from({ length: 501 }, (_, i) => session(`s${i}`)),
			stepResults: [],
		});

		expect(response.status).toBe(400);
		db.close();
	});

	it("does not echo record ids or exercise names when refusing", async () => {
		const db = await createTestDatabase();
		const { token } = await signedIn(db);
		const app = makeApp(db);

		const lines: string[] = [];
		const original = console.warn;
		console.warn = (...args: unknown[]) => lines.push(args.join(" "));
		let text: string;
		try {
			text = await (
				await app.upload(token, {
					sessions: [],
					stepResults: [stepResult("secret-record-id", "secret-session-id")],
				})
			).text();
		} finally {
			console.warn = original;
		}

		const logged = lines.join("\n");
		for (const secret of ["secret-record-id", "secret-session-id", "Bench Press"]) {
			expect(text).not.toContain(secret);
			expect(logged).not.toContain(secret);
		}
		db.close();
	});

	it("rejects a nonsense cursor", async () => {
		const db = await createTestDatabase();
		const { token } = await signedIn(db);
		const app = makeApp(db);

		for (const since of ["-1", "abc", "1.5"]) {
			const response = await app.pull(token, since as unknown as number);
			expect(response.status).toBe(400);
		}
		db.close();
	});
});
