import { describe, expect, it } from "vitest";
import {
	TokenCipher,
	TokenDecryptError,
} from "../../src/api/crypto/tokenCipher";
import { findOrCreateAccountForIdentity, markUserDeleting } from "../../src/api/db/accounts";
import {
	deleteCredentialsForIdentity,
	findCredentialForIdentity,
	markCredentialRevoked,
	prepareCredentialUpsert,
	readRefreshToken,
	saveCredentialAndIssueSession,
} from "../../src/api/db/providerCredentials";
import { findActiveSessionByToken } from "../../src/api/db/sessions";
import { AccountUnavailableError } from "../../src/api/db/accounts";
import { testEncryptionKey } from "./support/appleProduction";
import { type TestDatabase, createTestDatabase } from "./support/sqliteD1";

const NOW = 1_800_000_100;

function cipher(): TokenCipher {
	return new TokenCipher({ version: 1, material: testEncryptionKey() });
}

async function appleAccount(db: TestDatabase, subject = "apple-sub-1") {
	return findOrCreateAccountForIdentity(
		db,
		{ provider: "apple", subject },
		NOW,
	);
}

describe("storing a provider credential", () => {
	it("writes ciphertext, never the token", async () => {
		const db = await createTestDatabase();
		const account = await appleAccount(db);
		const c = cipher();

		await (
			await prepareCredentialUpsert(
				db,
				c,
				{
					authIdentityId: account.identity.id,
					provider: "apple",
					refreshToken: "apple-refresh-token",
				},
				NOW,
			)
		).run();

		const row = await findCredentialForIdentity(db, account.identity.id);
		expect(row?.encrypted_refresh_token).not.toContain("apple-refresh-token");
		expect(row?.encryption_iv.length).toBeGreaterThan(0);
		expect(row?.encryption_key_version).toBe(1);
		// And it reads back.
		expect(await readRefreshToken(db, c, account.identity.id)).toBe(
			"apple-refresh-token",
		);
		db.close();
	});

	it("replaces on a repeat sign-in rather than accumulating rows", async () => {
		const db = await createTestDatabase();
		const account = await appleAccount(db);
		const c = cipher();

		for (const token of ["first-token", "second-token"]) {
			await (
				await prepareCredentialUpsert(
					db,
					c,
					{
						authIdentityId: account.identity.id,
						provider: "apple",
						refreshToken: token,
					},
					NOW,
				)
			).run();
		}

		expect(await db.count("provider_credentials")).toBe(1);
		expect(await readRefreshToken(db, c, account.identity.id)).toBe(
			"second-token",
		);
		db.close();
	});

	it("re-encrypts with a fresh IV on every write", async () => {
		const db = await createTestDatabase();
		const account = await appleAccount(db);
		const c = cipher();
		const ivs = new Set<string>();

		for (let i = 0; i < 5; i += 1) {
			await (
				await prepareCredentialUpsert(
					db,
					c,
					{
						authIdentityId: account.identity.id,
						provider: "apple",
						refreshToken: "same-token",
					},
					NOW,
				)
			).run();
			const row = await findCredentialForIdentity(db, account.identity.id);
			ivs.add(row?.encryption_iv ?? "");
		}

		expect(ivs.size).toBe(5);
		db.close();
	});

	it("keeps two users' credentials separate and unreadable across identities", async () => {
		const db = await createTestDatabase();
		const a = await appleAccount(db, "apple-sub-a");
		const b = await appleAccount(db, "apple-sub-b");
		const c = cipher();

		for (const [account, token] of [
			[a, "token-a"],
			[b, "token-b"],
		] as const) {
			await (
				await prepareCredentialUpsert(
					db,
					c,
					{
						authIdentityId: account.identity.id,
						provider: "apple",
						refreshToken: token,
					},
					NOW,
				)
			).run();
		}

		expect(await readRefreshToken(db, c, a.identity.id)).toBe("token-a");
		expect(await readRefreshToken(db, c, b.identity.id)).toBe("token-b");

		// Move A's ciphertext onto B's row: it must not open. Otherwise
		// deletion could revoke the wrong person's Apple account.
		const rowA = await findCredentialForIdentity(db, a.identity.id);
		await db
			.prepare(
				`UPDATE provider_credentials
				    SET encrypted_refresh_token = ?, encryption_iv = ?
				  WHERE auth_identity_id = ?`,
			)
			.bind(rowA?.encrypted_refresh_token, rowA?.encryption_iv, b.identity.id)
			.run();

		await expect(
			readRefreshToken(db, c, b.identity.id),
		).rejects.toBeInstanceOf(TokenDecryptError);
		db.close();
	});
});

describe("credential and session commit together", () => {
	it("issues a session and stores the credential in one batch", async () => {
		const db = await createTestDatabase();
		const account = await appleAccount(db);
		const c = cipher();

		const issued = await saveCredentialAndIssueSession(db, c, {
			userId: account.user.id,
			credential: {
				authIdentityId: account.identity.id,
				provider: "apple",
				refreshToken: "apple-refresh-token",
			},
			deviceName: "iPhone",
			now: NOW,
		});

		expect(await findActiveSessionByToken(db, issued.token, NOW + 1)).not.toBeNull();
		expect(await readRefreshToken(db, c, account.identity.id)).toBe(
			"apple-refresh-token",
		);
		db.close();
	});

	it("issues no session when the credential cannot be written", async () => {
		// The invariant: never a live session for an account whose refresh
		// token was not stored, because that account could not be deleted the
		// way Apple requires.
		const db = await createTestDatabase();
		const account = await appleAccount(db);
		const c = cipher();

		await expect(
			saveCredentialAndIssueSession(db, c, {
				userId: account.user.id,
				credential: {
					// No such identity: the FK rejects it, rolling the batch back.
					authIdentityId: "identity-that-does-not-exist",
					provider: "apple",
					refreshToken: "apple-refresh-token",
				},
				now: NOW,
			}),
		).rejects.toThrow();

		expect(await db.count("sessions")).toBe(0);
		expect(await db.count("provider_credentials")).toBe(0);
		db.close();
	});

	it("stores no credential when the session is refused", async () => {
		const db = await createTestDatabase();
		const account = await appleAccount(db);
		await markUserDeleting(db, account.user.id, NOW);

		await expect(
			saveCredentialAndIssueSession(db, cipher(), {
				userId: account.user.id,
				credential: {
					authIdentityId: account.identity.id,
					provider: "apple",
					refreshToken: "apple-refresh-token",
				},
				now: NOW,
			}),
		).rejects.toBeInstanceOf(AccountUnavailableError);

		expect(await db.count("sessions")).toBe(0);
		db.close();
	});
});

describe("revoking and erasing", () => {
	it("blanks the material and marks the row revoked", async () => {
		const db = await createTestDatabase();
		const account = await appleAccount(db);
		const c = cipher();
		await saveCredentialAndIssueSession(db, c, {
			userId: account.user.id,
			credential: {
				authIdentityId: account.identity.id,
				provider: "apple",
				refreshToken: "apple-refresh-token",
			},
			now: NOW,
		});

		await markCredentialRevoked(db, account.identity.id, NOW);

		const row = await findCredentialForIdentity(db, account.identity.id);
		expect(row?.revoked_at).toBe(NOW);
		expect(row?.encrypted_refresh_token).toBe("");
		// Nothing left to read, and no error either — there is simply no
		// credential now.
		expect(await readRefreshToken(db, c, account.identity.id)).toBeNull();
		db.close();
	});

	it("is idempotent, keeping the first revocation time", async () => {
		const db = await createTestDatabase();
		const account = await appleAccount(db);
		await (
			await prepareCredentialUpsert(
				db,
				cipher(),
				{
					authIdentityId: account.identity.id,
					provider: "apple",
					refreshToken: "t",
				},
				NOW,
			)
		).run();

		await markCredentialRevoked(db, account.identity.id, NOW);
		await markCredentialRevoked(db, account.identity.id, NOW + 500);

		const row = await findCredentialForIdentity(db, account.identity.id);
		expect(row?.revoked_at).toBe(NOW);
		db.close();
	});

	it("un-revokes on a fresh sign-in, because there is a live credential again", async () => {
		const db = await createTestDatabase();
		const account = await appleAccount(db);
		const c = cipher();
		await (
			await prepareCredentialUpsert(
				db,
				c,
				{ authIdentityId: account.identity.id, provider: "apple", refreshToken: "old" },
				NOW,
			)
		).run();
		await markCredentialRevoked(db, account.identity.id, NOW);

		await (
			await prepareCredentialUpsert(
				db,
				c,
				{ authIdentityId: account.identity.id, provider: "apple", refreshToken: "new" },
				NOW + 100,
			)
		).run();

		const row = await findCredentialForIdentity(db, account.identity.id);
		expect(row?.revoked_at).toBeNull();
		expect(await readRefreshToken(db, c, account.identity.id)).toBe("new");
		db.close();
	});

	it("deletes outright when asked", async () => {
		const db = await createTestDatabase();
		const account = await appleAccount(db);
		await (
			await prepareCredentialUpsert(
				db,
				cipher(),
				{ authIdentityId: account.identity.id, provider: "apple", refreshToken: "t" },
				NOW,
			)
		).run();

		await deleteCredentialsForIdentity(db, account.identity.id);
		expect(await db.count("provider_credentials")).toBe(0);
		db.close();
	});

	it("goes away with the user, so deletion cannot leave one behind", async () => {
		const db = await createTestDatabase();
		const account = await appleAccount(db);
		await (
			await prepareCredentialUpsert(
				db,
				cipher(),
				{ authIdentityId: account.identity.id, provider: "apple", refreshToken: "t" },
				NOW,
			)
		).run();

		await db.prepare(`DELETE FROM users WHERE id = ?`).bind(account.user.id).run();

		// ON DELETE CASCADE through auth_identities.
		expect(await db.count("provider_credentials")).toBe(0);
		db.close();
	});
});
