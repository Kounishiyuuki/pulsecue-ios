import { describe, expect, it } from "vitest";
import {
	AccountUnavailableError,
	findOrCreateAccountForIdentity,
	markUserDeleting,
} from "../../src/api/db/accounts";
import {
	MissingChangeSequenceError,
	currentChangeSeq,
} from "../../src/api/db/changeSeq";
import { createSession } from "../../src/api/db/sessions";
import { type TestDatabase, createTestDatabase } from "./support/sqliteD1";

/**
 * Wraps a database so the *first* identity lookup finds nothing, even
 * though the row exists. That is the only way to drive
 * `findOrCreateAccountForIdentity` into its creation batch when the
 * identity has already been taken — the state a concurrent first sign-in
 * produces.
 */
function hideIdentityOnce(db: TestDatabase): TestDatabase {
	let hidden = false;
	return {
		...db,
		prepare: (sql: string) => {
			const statement = db.prepare(sql);
			if (hidden || !sql.includes("FROM auth_identities")) return statement;
			return {
				...statement,
				bind: (...values: unknown[]) => {
					const bound = statement.bind(...values);
					return {
						...bound,
						first: async () => {
							hidden = true;
							return null;
						},
					};
				},
			};
		},
	};
}

describe("the test double really is atomic", () => {
	// If this fails, every atomicity assertion below is meaningless.
	it("rolls a failing batch back completely", async () => {
		const db = await createTestDatabase();
		await expect(
			db.batch([
				db
					.prepare(
						`INSERT INTO users (id,state,created_at,updated_at) VALUES ('u1','active',1,1)`,
					)
					.bind(),
				// Violates the provider CHECK.
				db
					.prepare(
						`INSERT INTO auth_identities (id,user_id,provider,subject,email_verified,created_at,last_seen_at)
						 VALUES ('i1','u1','myspace','s',0,1,1)`,
					)
					.bind(),
			]),
		).rejects.toThrow();

		expect(await db.count("users")).toBe(0);
		expect(await db.count("auth_identities")).toBe(0);
		db.close();
	});

	it("commits a whole successful batch", async () => {
		const db = await createTestDatabase();
		await db.batch([
			db
				.prepare(
					`INSERT INTO users (id,state,created_at,updated_at) VALUES ('u1','active',1,1)`,
				)
				.bind(),
			db
				.prepare(`INSERT INTO user_change_seq (user_id,seq) VALUES ('u1',0)`)
				.bind(),
		]);
		expect(await db.count("users")).toBe(1);
		expect(await db.count("user_change_seq")).toBe(1);
		db.close();
	});
});

describe("account creation atomicity", () => {
	it("writes user, identity, profile and cursor together", async () => {
		const db = await createTestDatabase();
		const account = await findOrCreateAccountForIdentity(db, {
			provider: "apple",
			subject: "sub-1",
		});

		expect(await db.count("users")).toBe(1);
		expect(await db.count("auth_identities")).toBe(1);
		expect(await db.count("user_profiles")).toBe(1);
		expect(await db.count("user_change_seq")).toBe(1);
		expect(await currentChangeSeq(db, account.user.id)).toBe(0);
		db.close();
	});

	it("leaves nothing behind when a statement in the batch fails", async () => {
		// The earlier version of this test pre-inserted the conflicting
		// identity, so the lookup found it and the code returned before the
		// batch ever ran — it proved nothing about atomicity. Here the first
		// lookup is made to miss while the row really exists, which is the
		// actual race: two devices sign in, one wins, and the loser's batch
		// hits UNIQUE (provider, subject) partway through.
		const db = await createTestDatabase();
		await db
			.prepare(
				`INSERT INTO users (id,state,created_at,updated_at) VALUES ('winner','active',1,1)`,
			)
			.run();
		await db
			.prepare(
				`INSERT INTO auth_identities (id,user_id,provider,subject,email_verified,created_at,last_seen_at)
				 VALUES ('i-win','winner','apple','sub-1',0,1,1)`,
			)
			.run();
		await db
			.prepare(`INSERT INTO user_profiles (user_id,created_at,updated_at) VALUES ('winner',1,1)`)
			.run();
		await db
			.prepare(`INSERT INTO user_change_seq (user_id,seq) VALUES ('winner',0)`)
			.run();

		const usersBefore = await db.count("users");
		const profilesBefore = await db.count("user_profiles");
		const cursorsBefore = await db.count("user_change_seq");

		const account = await findOrCreateAccountForIdentity(
			hideIdentityOnce(db),
			{ provider: "apple", subject: "sub-1" },
		);

		// It went through createAccount, the batch failed on UNIQUE, and the
		// retry resolved onto the winner.
		expect(account.created).toBe(false);
		expect(account.user.id).toBe("winner");
		// Nothing partial survived the rolled-back batch.
		expect(await db.count("users")).toBe(usersBefore);
		expect(await db.count("user_profiles")).toBe(profilesBefore);
		expect(await db.count("user_change_seq")).toBe(cursorsBefore);
		expect(await db.count("auth_identities")).toBe(1);
		db.close();
	});

	it("survives a concurrent first sign-in with the same identity", async () => {
		const db = await createTestDatabase();
		const input = { provider: "apple" as const, subject: "race-sub" };

		const [a, b] = await Promise.all([
			findOrCreateAccountForIdentity(db, input),
			findOrCreateAccountForIdentity(db, input),
		]);

		// Exactly one account exists and both callers got it.
		expect(a.user.id).toBe(b.user.id);
		expect(await db.count("users")).toBe(1);
		expect(await db.count("auth_identities")).toBe(1);
		expect(await db.count("user_profiles")).toBe(1);
		expect(await db.count("user_change_seq")).toBe(1);
		db.close();
	});

	it("keeps distinct identities apart under concurrency", async () => {
		const db = await createTestDatabase();
		const results = await Promise.all(
			Array.from({ length: 5 }, (_, i) =>
				findOrCreateAccountForIdentity(db, {
					provider: "google",
					subject: `sub-${i}`,
				}),
			),
		);

		expect(new Set(results.map((r) => r.user.id)).size).toBe(5);
		expect(await db.count("users")).toBe(5);
		expect(await db.count("user_change_seq")).toBe(5);
		db.close();
	});
});

describe("a malformed account is reported, not papered over", () => {
	it("raises when the sync cursor row is missing", async () => {
		const db = await createTestDatabase();
		const account = await findOrCreateAccountForIdentity(db, {
			provider: "apple",
			subject: "sub-1",
		});
		await db
			.prepare(`DELETE FROM user_change_seq WHERE user_id = ?`)
			.bind(account.user.id)
			.run();

		await expect(currentChangeSeq(db, account.user.id)).rejects.toBeInstanceOf(
			MissingChangeSequenceError,
		);
		db.close();
	});

	it("still reports a freshly created cursor as 0", async () => {
		const db = await createTestDatabase();
		const account = await findOrCreateAccountForIdentity(db, {
			provider: "apple",
			subject: "sub-1",
		});
		expect(await currentChangeSeq(db, account.user.id)).toBe(0);
		db.close();
	});
});

describe("deleting accounts fail closed", () => {
	it("revokes every session in the same step as the state change", async () => {
		const db = await createTestDatabase();
		const account = await findOrCreateAccountForIdentity(db, {
			provider: "apple",
			subject: "sub-1",
		});
		await createSession(db, account.user.id, { now: 1000 });
		await createSession(db, account.user.id, { now: 1000 });

		const user = await markUserDeleting(db, account.user.id, 2000);

		expect(user.state).toBe("deleting");
		expect(user.deleted_at).toBe(2000);
		const live = await db
			.prepare(
				`SELECT COUNT(*) AS n FROM sessions WHERE user_id = ? AND revoked_at IS NULL`,
			)
			.bind(account.user.id)
			.first<{ n: number }>();
		expect(live?.n).toBe(0);
		db.close();
	});

	it("refuses to issue a session", async () => {
		const db = await createTestDatabase();
		const account = await findOrCreateAccountForIdentity(db, {
			provider: "apple",
			subject: "sub-1",
		});
		await markUserDeleting(db, account.user.id, 2000);

		await expect(
			createSession(db, account.user.id, { now: 2100 }),
		).rejects.toBeInstanceOf(AccountUnavailableError);
		expect(await db.count("sessions")).toBe(0);
		db.close();
	});

	it("refuses to resolve the identity as a normal account", async () => {
		const db = await createTestDatabase();
		const account = await findOrCreateAccountForIdentity(db, {
			provider: "apple",
			subject: "sub-1",
		});
		await markUserDeleting(db, account.user.id, 2000);

		await expect(
			findOrCreateAccountForIdentity(db, { provider: "apple", subject: "sub-1" }),
		).rejects.toBeInstanceOf(AccountUnavailableError);
		// And no replacement account was quietly created.
		expect(await db.count("users")).toBe(1);
		db.close();
	});

	it("leaves an active account completely normal", async () => {
		const db = await createTestDatabase();
		const account = await findOrCreateAccountForIdentity(db, {
			provider: "apple",
			subject: "sub-1",
		});
		const issued = await createSession(db, account.user.id, { now: 1000 });

		const again = await findOrCreateAccountForIdentity(db, {
			provider: "apple",
			subject: "sub-1",
		});
		expect(again.user.id).toBe(account.user.id);
		expect(issued.session.revoked_at).toBeNull();
		db.close();
	});
});
