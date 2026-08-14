import { describe, expect, it } from "vitest";
import { findOrCreateAccountForIdentity } from "../../src/api/db/accounts";
import {
	SESSION_TTL_SECONDS,
	createSession,
	findActiveSessionByToken,
	generateSessionToken,
	hashSessionToken,
	revokeAllSessionsForUser,
	revokeSession,
	shouldRotate,
	touchSession,
} from "../../src/api/db/sessions";
import { createTestDatabase } from "./support/sqliteD1";

async function makeUser(db: Awaited<ReturnType<typeof createTestDatabase>>) {
	const account = await findOrCreateAccountForIdentity(db, {
		provider: "apple",
		subject: `sub-${Math.random()}`,
	});
	return account.user.id;
}

describe("session tokens", () => {
	it("mints unguessable, distinct tokens", () => {
		const tokens = new Set(
			Array.from({ length: 200 }, () => generateSessionToken()),
		);
		expect(tokens.size).toBe(200);
		for (const token of tokens) {
			// 256 bits, base64url, unpadded.
			expect(token).toMatch(/^[A-Za-z0-9_-]{43}$/);
		}
	});

	it("stores only the hash, never the token", async () => {
		const db = await createTestDatabase();
		const userId = await makeUser(db);
		const { token, session } = await createSession(db, userId);

		expect(session.token_sha256).toBe(await hashSessionToken(token));
		expect(session.token_sha256).not.toBe(token);

		const dump = await db
			.prepare(`SELECT * FROM sessions`)
			.all<Record<string, unknown>>();
		expect(JSON.stringify(dump)).not.toContain(token);
		db.close();
	});
});

describe("session lifecycle", () => {
	it("resolves a live token to its session", async () => {
		const db = await createTestDatabase();
		const userId = await makeUser(db);
		const { token, session } = await createSession(db, userId, { now: 1000 });

		const found = await findActiveSessionByToken(db, token, 1001);
		expect(found?.id).toBe(session.id);
		expect(found?.user_id).toBe(userId);
		db.close();
	});

	it("expires at exactly 60 days and not before", async () => {
		const db = await createTestDatabase();
		const userId = await makeUser(db);
		const { token } = await createSession(db, userId, { now: 1000 });

		expect(SESSION_TTL_SECONDS).toBe(60 * 24 * 60 * 60);
		const justBefore = 1000 + SESSION_TTL_SECONDS - 1;
		expect(await findActiveSessionByToken(db, token, justBefore)).not.toBeNull();
		expect(
			await findActiveSessionByToken(db, token, 1000 + SESSION_TTL_SECONDS),
		).toBeNull();
		db.close();
	});

	it("stops resolving once revoked", async () => {
		const db = await createTestDatabase();
		const userId = await makeUser(db);
		const { token, session } = await createSession(db, userId, { now: 1000 });

		await revokeSession(db, session.id, 1500);

		expect(await findActiveSessionByToken(db, token, 1600)).toBeNull();
		db.close();
	});

	it("keeps the original revocation time if revoked twice", async () => {
		const db = await createTestDatabase();
		const userId = await makeUser(db);
		const { session } = await createSession(db, userId, { now: 1000 });

		await revokeSession(db, session.id, 1500);
		await revokeSession(db, session.id, 9999);

		const row = await db
			.prepare(`SELECT revoked_at FROM sessions WHERE id = ?`)
			.bind(session.id)
			.first<{ revoked_at: number }>();
		expect(row?.revoked_at).toBe(1500);
		db.close();
	});

	it("revokes every session for a user at once", async () => {
		// What unlink and account deletion rely on: no session may survive.
		const db = await createTestDatabase();
		const userId = await makeUser(db);
		const a = await createSession(db, userId, { now: 1000 });
		const b = await createSession(db, userId, { now: 1000 });
		const otherUser = await makeUser(db);
		const other = await createSession(db, otherUser, { now: 1000 });

		await revokeAllSessionsForUser(db, userId, 2000);

		expect(await findActiveSessionByToken(db, a.token, 2001)).toBeNull();
		expect(await findActiveSessionByToken(db, b.token, 2001)).toBeNull();
		// Another user's session is untouched.
		expect(await findActiveSessionByToken(db, other.token, 2001)).not.toBeNull();
		db.close();
	});

	it("does not resolve an unknown token", async () => {
		const db = await createTestDatabase();
		expect(
			await findActiveSessionByToken(db, generateSessionToken()),
		).toBeNull();
		db.close();
	});

	it("records last use without extending expiry", async () => {
		const db = await createTestDatabase();
		const userId = await makeUser(db);
		const { token, session } = await createSession(db, userId, { now: 1000 });

		await touchSession(db, session.id, 5000);

		const found = await findActiveSessionByToken(db, token, 5001);
		expect(found?.last_used_at).toBe(5000);
		expect(found?.expires_at).toBe(session.expires_at);
		db.close();
	});
});

describe("rotation", () => {
	it("asks for a new session once half the life is gone", async () => {
		const db = await createTestDatabase();
		const userId = await makeUser(db);
		const { session } = await createSession(db, userId, { now: 0 });
		const half = SESSION_TTL_SECONDS / 2;

		expect(shouldRotate(session, half - 1)).toBe(false);
		expect(shouldRotate(session, half)).toBe(true);
		db.close();
	});
});
