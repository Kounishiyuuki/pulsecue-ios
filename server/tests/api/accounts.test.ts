import { describe, expect, it } from "vitest";
import {
	IdentityAlreadyLinkedError,
	UserNotFoundError,
	findOrCreateAccountForIdentity,
	linkIdentityToUser,
	listIdentities,
	markUserDeleting,
} from "../../src/api/db/accounts";
import { currentChangeSeq, nextChangeSeq } from "../../src/api/db/changeSeq";
import { createTestDatabase } from "./support/sqliteD1";

describe("findOrCreateAccountForIdentity", () => {
	it("creates a user, profile and cursor on first sign-in", async () => {
		const db = await createTestDatabase();
		const result = await findOrCreateAccountForIdentity(db, {
			provider: "apple",
			subject: "apple-sub-1",
			email: "a@example.com",
			emailVerified: true,
			displayName: "Yuuki",
		});

		expect(result.created).toBe(true);
		expect(result.user.state).toBe("active");
		expect(result.identity.subject).toBe("apple-sub-1");

		const profile = await db
			.prepare(`SELECT display_name FROM user_profiles WHERE user_id = ?`)
			.bind(result.user.id)
			.first<{ display_name: string }>();
		expect(profile?.display_name).toBe("Yuuki");
		expect(await currentChangeSeq(db, result.user.id)).toBe(0);
		db.close();
	});

	it("returns the same user on a repeat sign-in", async () => {
		const db = await createTestDatabase();
		const first = await findOrCreateAccountForIdentity(db, {
			provider: "google",
			subject: "google-sub-1",
		});
		const second = await findOrCreateAccountForIdentity(db, {
			provider: "google",
			subject: "google-sub-1",
		});

		expect(second.created).toBe(false);
		expect(second.user.id).toBe(first.user.id);
		const { results } = await db
			.prepare(`SELECT id FROM users`)
			.all<{ id: string }>();
		expect(results).toHaveLength(1);
		db.close();
	});

	it("never merges two identities that share an email", async () => {
		// The rule that keeps an address from becoming an account takeover.
		const db = await createTestDatabase();
		const apple = await findOrCreateAccountForIdentity(db, {
			provider: "apple",
			subject: "apple-sub-1",
			email: "same@example.com",
		});
		const google = await findOrCreateAccountForIdentity(db, {
			provider: "google",
			subject: "google-sub-1",
			email: "same@example.com",
		});

		expect(google.user.id).not.toBe(apple.user.id);
		expect(google.created).toBe(true);
		db.close();
	});

	it("keeps a stored email when the provider stops sending one", async () => {
		// Apple returns the address only on the first authorization.
		const db = await createTestDatabase();
		const first = await findOrCreateAccountForIdentity(db, {
			provider: "apple",
			subject: "apple-sub-1",
			email: "a@example.com",
			emailVerified: true,
		});
		const second = await findOrCreateAccountForIdentity(db, {
			provider: "apple",
			subject: "apple-sub-1",
		});

		expect(second.identity.email).toBe("a@example.com");
		expect(second.identity.email_verified).toBe(1);
		expect(second.identity.last_seen_at).toBeGreaterThanOrEqual(
			first.identity.created_at,
		);
		db.close();
	});
});

describe("linkIdentityToUser", () => {
	it("attaches a second provider to the signed-in account", async () => {
		const db = await createTestDatabase();
		const account = await findOrCreateAccountForIdentity(db, {
			provider: "apple",
			subject: "apple-sub-1",
		});

		await linkIdentityToUser(db, account.user.id, {
			provider: "google",
			subject: "google-sub-1",
		});

		const identities = await listIdentities(db, account.user.id);
		expect(identities.map((i) => i.provider).sort()).toEqual([
			"apple",
			"google",
		]);
		db.close();
	});

	it("refuses an identity that already belongs to someone else", async () => {
		const db = await createTestDatabase();
		const first = await findOrCreateAccountForIdentity(db, {
			provider: "apple",
			subject: "apple-sub-1",
		});
		const second = await findOrCreateAccountForIdentity(db, {
			provider: "google",
			subject: "google-sub-1",
		});

		await expect(
			linkIdentityToUser(db, first.user.id, {
				provider: "google",
				subject: "google-sub-1",
			}),
		).rejects.toBeInstanceOf(IdentityAlreadyLinkedError);

		// The victim keeps their identity.
		expect(await listIdentities(db, second.user.id)).toHaveLength(1);
		db.close();
	});

	it("rejects linking to a user that does not exist", async () => {
		const db = await createTestDatabase();
		await expect(
			linkIdentityToUser(db, "no-such-user", {
				provider: "apple",
				subject: "apple-sub-1",
			}),
		).rejects.toBeInstanceOf(UserNotFoundError);
		db.close();
	});
});

describe("markUserDeleting", () => {
	it("soft deletes without removing the row", async () => {
		const db = await createTestDatabase();
		const account = await findOrCreateAccountForIdentity(db, {
			provider: "apple",
			subject: "apple-sub-1",
		});

		const deleted = await markUserDeleting(db, account.user.id, 1_800_000_000);

		expect(deleted.state).toBe("deleting");
		expect(deleted.deleted_at).toBe(1_800_000_000);
		db.close();
	});
});

describe("change sequence", () => {
	it("increases by one and never repeats a number", async () => {
		const db = await createTestDatabase();
		const account = await findOrCreateAccountForIdentity(db, {
			provider: "apple",
			subject: "apple-sub-1",
		});

		const seqs: number[] = [];
		for (let i = 0; i < 5; i += 1) {
			seqs.push(await nextChangeSeq(db, account.user.id));
		}

		expect(seqs).toEqual([1, 2, 3, 4, 5]);
		expect(await currentChangeSeq(db, account.user.id)).toBe(5);
		db.close();
	});

	it("keeps each user's cursor independent", async () => {
		const db = await createTestDatabase();
		const a = await findOrCreateAccountForIdentity(db, {
			provider: "apple",
			subject: "a",
		});
		const b = await findOrCreateAccountForIdentity(db, {
			provider: "google",
			subject: "b",
		});

		await nextChangeSeq(db, a.user.id);
		await nextChangeSeq(db, a.user.id);
		await nextChangeSeq(db, b.user.id);

		expect(await currentChangeSeq(db, a.user.id)).toBe(2);
		expect(await currentChangeSeq(db, b.user.id)).toBe(1);
		db.close();
	});
});
