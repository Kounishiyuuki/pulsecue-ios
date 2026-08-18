import { describe, expect, it } from "vitest";
import { createTestDatabase } from "./support/sqliteD1";

describe("account schema", () => {
	it("creates exactly the expected tables", async () => {
		const db = await createTestDatabase();
		const { results } = await db
			.prepare(
				`SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name`,
			)
			.all<{ name: string }>();
		expect(results.map((r) => r.name)).toEqual([
			"account_deletions",
			"auth_identities",
			"auth_nonces",
			"provider_credentials",
			"sessions",
			"user_change_seq",
			"user_profiles",
			"users",
		]);
		db.close();
	});

	it("hangs every user-owned table off users with a cascade", async () => {
		// Account deletion is one `DELETE FROM users`. It stays correct only
		// because the database decides what belongs to a user — a hand-written
		// list of child tables is how a table added next year quietly survives
		// a deletion.
		const db = await createTestDatabase();
		const { results } = await db
			.prepare(
				`SELECT name, sql FROM sqlite_master
				  WHERE type='table' AND name NOT LIKE 'sqlite_%'`,
			)
			.all<{ name: string; sql: string }>();

		const userOwned = [
			"auth_identities",
			"user_profiles",
			"sessions",
			"user_change_seq",
			"account_deletions",
		];
		for (const table of userOwned) {
			const ddl = (results.find((r) => r.name === table)?.sql ?? "").toLowerCase();
			expect(ddl, `${table} must reference users`).toContain("references users(id)");
			expect(ddl, `${table} must cascade`).toContain("on delete cascade");
		}

		// `provider_credentials` reaches users through the identity — and does
		// so with a *composite* reference, so a credential cannot claim a
		// provider its identity does not have. Asserted on the pair rather than
		// on `id` alone, because the single-column form would satisfy the
		// cascade requirement while losing the provider binding.
		const credentials = (
			results.find((r) => r.name === "provider_credentials")?.sql ?? ""
		).toLowerCase();
		expect(credentials).toMatch(
			/references\s+auth_identities\s*\(\s*id\s*,\s*provider\s*\)/,
		);
		expect(credentials).toContain("on delete cascade");
		expect(credentials).toContain("foreign key (auth_identity_id, provider)");

		// `auth_nonces` is keyed by a nonce hash and has no owner, so there is
		// deliberately nothing there for a deletion to sweep.
		const nonces = (
			results.find((r) => r.name === "auth_nonces")?.sql ?? ""
		).toLowerCase();
		expect(nonces).not.toContain("user_id");
		db.close();
	});

	it("stores no plaintext provider credential anywhere", async () => {
		// The schema must not become a place where credentials accumulate.
		//
		// This test used to forbid `refresh_token` outright. That is no longer
		// the right invariant: Apple requires revocation at account deletion,
		// which needs a refresh token, and it can only be obtained during
		// sign-in. So exactly one refresh token column now exists — and the
		// invariant is tightened rather than dropped: it must be the encrypted
		// one, and every *other* provider credential is still forbidden.
		const db = await createTestDatabase();
		const { results } = await db
			.prepare(`SELECT sql FROM sqlite_master WHERE type='table'`)
			.all<{ sql: string }>();
		const ddl = results.map((r) => r.sql).join("\n").toLowerCase();

		for (const forbidden of [
			"access_token",
			"id_token",
			"identity_token",
			"authorization_code",
			"password",
		]) {
			expect(ddl).not.toContain(forbidden);
		}

		// The only refresh token column is the encrypted one.
		const refreshColumns = [...ddl.matchAll(/(\w*refresh_token\w*)/g)].map(
			(match) => match[1],
		);
		expect(new Set(refreshColumns)).toEqual(new Set(["encrypted_refresh_token"]));
		db.close();
	});

	it("keeps the encrypted credential's IV and key version beside it", async () => {
		// Without a stored IV the ciphertext cannot be opened; without a key
		// version a rotation would orphan every row. Both are part of what
		// makes the column safe to have at all.
		const db = await createTestDatabase();
		const row = await db
			.prepare(
				`SELECT sql FROM sqlite_master WHERE type='table' AND name='provider_credentials'`,
			)
			.first<{ sql: string }>();
		const ddl = (row?.sql ?? "").toLowerCase();

		expect(ddl).toContain("encrypted_refresh_token");
		expect(ddl).toContain("encryption_iv");
		expect(ddl).toContain("encryption_key_version");
		// And it disappears with its owner rather than outliving them.
		expect(ddl).toContain("on delete cascade");
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

describe("schema constraints", () => {
	it("enforces foreign keys and cascades on user delete", async () => {
		const db = await createTestDatabase();
		await db
			.prepare(`INSERT INTO users (id,state,created_at,updated_at) VALUES ('u1','active',1,1)`)
			.run();
		// A child row pointing at nobody is refused.
		await expect(
			db
				.prepare(
					`INSERT INTO user_profiles (user_id,created_at,updated_at) VALUES ('ghost',1,1)`,
				)
				.run(),
		).rejects.toThrow();

		for (const sql of [
			`INSERT INTO user_profiles (user_id,created_at,updated_at) VALUES ('u1',1,1)`,
			`INSERT INTO user_change_seq (user_id,seq) VALUES ('u1',0)`,
			`INSERT INTO auth_identities (id,user_id,provider,subject,email_verified,created_at,last_seen_at)
			 VALUES ('i1','u1','apple','s1',0,1,1)`,
			`INSERT INTO sessions (id,user_id,token_sha256,created_at,last_used_at,expires_at)
			 VALUES ('s1','u1','hash-1',1,1,999)`,
		]) {
			await db.prepare(sql).run();
		}

		await db.prepare(`DELETE FROM users WHERE id='u1'`).run();

		expect(await db.count("user_profiles")).toBe(0);
		expect(await db.count("user_change_seq")).toBe(0);
		expect(await db.count("auth_identities")).toBe(0);
		expect(await db.count("sessions")).toBe(0);
		db.close();
	});

	it("rejects a non-boolean email_verified", async () => {
		const db = await createTestDatabase();
		await db
			.prepare(`INSERT INTO users (id,state,created_at,updated_at) VALUES ('u1','active',1,1)`)
			.run();
		await expect(
			db
				.prepare(
					`INSERT INTO auth_identities (id,user_id,provider,subject,email_verified,created_at,last_seen_at)
					 VALUES ('i1','u1','apple','s1',2,1,1)`,
				)
				.run(),
		).rejects.toThrow();
		db.close();
	});

	it("rejects a duplicate session token hash", async () => {
		const db = await createTestDatabase();
		await db
			.prepare(`INSERT INTO users (id,state,created_at,updated_at) VALUES ('u1','active',1,1)`)
			.run();
		const insert = (id: string) =>
			db
				.prepare(
					`INSERT INTO sessions (id,user_id,token_sha256,created_at,last_used_at,expires_at)
					 VALUES (?, 'u1','same-hash',1,1,999)`,
				)
				.bind(id)
				.run();
		await insert("s1");
		await expect(insert("s2")).rejects.toThrow();
		db.close();
	});

	it("refuses impossible state / deleted_at combinations", async () => {
		const db = await createTestDatabase();
		// active must not carry a deletion timestamp…
		await expect(
			db
				.prepare(
					`INSERT INTO users (id,state,created_at,updated_at,deleted_at) VALUES ('u1','active',1,1,5)`,
				)
				.run(),
		).rejects.toThrow();
		// …and deleting must.
		await expect(
			db
				.prepare(
					`INSERT INTO users (id,state,created_at,updated_at) VALUES ('u2','deleting',1,1)`,
				)
				.run(),
		).rejects.toThrow();

		// Both valid shapes are accepted.
		await db
			.prepare(`INSERT INTO users (id,state,created_at,updated_at) VALUES ('u3','active',1,1)`)
			.run();
		await db
			.prepare(
				`INSERT INTO users (id,state,created_at,updated_at,deleted_at) VALUES ('u4','deleting',1,1,5)`,
			)
			.run();
		expect(await db.count("users")).toBe(2);

		// And the invariant holds through an UPDATE too.
		await expect(
			db.prepare(`UPDATE users SET state='deleting' WHERE id='u3'`).run(),
		).rejects.toThrow();
		db.close();
	});
});
