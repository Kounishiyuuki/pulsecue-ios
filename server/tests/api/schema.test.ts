import { describe, expect, it } from "vitest";
import { createTestDatabase } from "./support/sqliteD1";

describe("0001_user_auth_foundation", () => {
	it("creates exactly the foundation tables", async () => {
		const db = await createTestDatabase();
		const { results } = await db
			.prepare(
				`SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name`,
			)
			.all<{ name: string }>();
		expect(results.map((r) => r.name)).toEqual([
			"auth_identities",
			"sessions",
			"user_change_seq",
			"user_profiles",
			"users",
		]);
		db.close();
	});

	it("stores no provider token column anywhere", async () => {
		// The schema must not become a place where credentials accumulate.
		const db = await createTestDatabase();
		const { results } = await db
			.prepare(`SELECT sql FROM sqlite_master WHERE type='table'`)
			.all<{ sql: string }>();
		const ddl = results.map((r) => r.sql).join("\n").toLowerCase();
		for (const forbidden of [
			"access_token",
			"refresh_token",
			"id_token",
			"identity_token",
			"authorization_code",
			"password",
		]) {
			expect(ddl).not.toContain(forbidden);
		}
		db.close();
	});

	it("only stores a hash of the session token", async () => {
		const db = await createTestDatabase();
		const row = await db
			.prepare(`SELECT sql FROM sqlite_master WHERE name='sessions'`)
			.first<{ sql: string }>();
		expect(row?.sql).toContain("token_sha256");
		db.close();
	});

	it("refuses a second identity for the same provider subject", async () => {
		const db = await createTestDatabase();
		await db
			.prepare(`INSERT INTO users (id, state, created_at, updated_at) VALUES ('u1','active',1,1)`)
			.run();
		await db
			.prepare(`INSERT INTO users (id, state, created_at, updated_at) VALUES ('u2','active',1,1)`)
			.run();
		const insert = (id: string, user: string) =>
			db
				.prepare(
					`INSERT INTO auth_identities (id,user_id,provider,subject,email_verified,created_at,last_seen_at)
					 VALUES (?,?, 'apple','sub-1',0,1,1)`,
				)
				.bind(id, user)
				.run();
		await insert("i1", "u1");
		await expect(insert("i2", "u2")).rejects.toThrow();
		db.close();
	});

	it("allows one user to hold both an Apple and a Google identity", async () => {
		const db = await createTestDatabase();
		await db
			.prepare(`INSERT INTO users (id, state, created_at, updated_at) VALUES ('u1','active',1,1)`)
			.run();
		for (const [id, provider] of [["i1", "apple"], ["i2", "google"]]) {
			await db
				.prepare(
					`INSERT INTO auth_identities (id,user_id,provider,subject,email_verified,created_at,last_seen_at)
					 VALUES (?, 'u1', ?, 'sub-1', 0, 1, 1)`,
				)
				.bind(id, provider)
				.run();
		}
		const { results } = await db
			.prepare(`SELECT provider FROM auth_identities WHERE user_id='u1' ORDER BY provider`)
			.all<{ provider: string }>();
		expect(results.map((r) => r.provider)).toEqual(["apple", "google"]);
		db.close();
	});

	it("rejects an unknown user state and an unknown provider", async () => {
		const db = await createTestDatabase();
		await expect(
			db
				.prepare(`INSERT INTO users (id,state,created_at,updated_at) VALUES ('u1','zombie',1,1)`)
				.run(),
		).rejects.toThrow();
		await db
			.prepare(`INSERT INTO users (id,state,created_at,updated_at) VALUES ('u1','active',1,1)`)
			.run();
		await expect(
			db
				.prepare(
					`INSERT INTO auth_identities (id,user_id,provider,subject,email_verified,created_at,last_seen_at)
					 VALUES ('i1','u1','facebook','s',0,1,1)`,
				)
				.run(),
		).rejects.toThrow();
		db.close();
	});
});
