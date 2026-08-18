import { describe, expect, it } from "vitest";
import { revokeAppleIdentityCredential } from "../../src/api/auth/appleRevocation";
import { TokenCipher } from "../../src/api/crypto/tokenCipher";
import { findOrCreateAccountForIdentity } from "../../src/api/db/accounts";
import {
	findCredentialForIdentity,
	prepareCredentialUpsert,
} from "../../src/api/db/providerCredentials";
import {
	appleErrorResponse,
	createTestAppleSigningKey,
	fakeAppleEndpoint,
	testEncryptionKey,
} from "./support/appleProduction";
import { type TestDatabase, createTestDatabase } from "./support/sqliteD1";

const NOW = 1_800_000_100;

async function withStoredCredential(cipher: TokenCipher, db: TestDatabase) {
	const account = await findOrCreateAccountForIdentity(
		db,
		{ provider: "apple", subject: "apple-sub-1" },
		NOW,
	);
	await (
		await prepareCredentialUpsert(
			db,
			cipher,
			{
				authIdentityId: account.identity.id,
				provider: "apple",
				refreshToken: "stored-refresh-token",
			},
			NOW,
		)
	).run();
	return account;
}

describe("revoking an identity's Apple credential", () => {
	it("revokes at Apple and erases the material", async () => {
		const db = await createTestDatabase();
		const cipher = new TokenCipher({ version: 1, material: testEncryptionKey() });
		const account = await withStoredCredential(cipher, db);
		const key = await createTestAppleSigningKey();
		const endpoint = fakeAppleEndpoint(() => new Response("", { status: 200 }));

		const outcome = await revokeAppleIdentityCredential({
			db,
			cipher,
			config: key.config,
			authIdentityId: account.identity.id,
			fetchImpl: endpoint.fetchImpl,
			now: NOW,
		});

		expect(outcome).toEqual({ status: "revoked" });
		// The decrypted token really was the one sent to Apple.
		expect(endpoint.requests[0]?.form.token).toBe("stored-refresh-token");
		const row = await findCredentialForIdentity(db, account.identity.id);
		expect(row?.revoked_at).toBe(NOW);
		expect(row?.encrypted_refresh_token).toBe("");
		db.close();
	});

	it("treats a token Apple already forgot as revoked, and still erases it", async () => {
		const db = await createTestDatabase();
		const cipher = new TokenCipher({ version: 1, material: testEncryptionKey() });
		const account = await withStoredCredential(cipher, db);
		const key = await createTestAppleSigningKey();
		const endpoint = fakeAppleEndpoint(() => appleErrorResponse("invalid_grant"));

		const outcome = await revokeAppleIdentityCredential({
			db,
			cipher,
			config: key.config,
			authIdentityId: account.identity.id,
			fetchImpl: endpoint.fetchImpl,
			now: NOW,
		});

		expect(outcome).toEqual({ status: "revoked" });
		expect(
			(await findCredentialForIdentity(db, account.identity.id))?.revoked_at,
		).toBe(NOW);
		db.close();
	});

	it("keeps the credential and reports retryable when Apple is down", async () => {
		// A retry needs the material, and an outage must never be recorded as
		// a revocation that happened.
		const db = await createTestDatabase();
		const cipher = new TokenCipher({ version: 1, material: testEncryptionKey() });
		const account = await withStoredCredential(cipher, db);
		const key = await createTestAppleSigningKey();
		const endpoint = fakeAppleEndpoint(() => new Response("", { status: 503 }));

		const outcome = await revokeAppleIdentityCredential({
			db,
			cipher,
			config: key.config,
			authIdentityId: account.identity.id,
			fetchImpl: endpoint.fetchImpl,
			now: NOW,
		});

		expect(outcome).toEqual({
			status: "retryable",
			reason: "providerUnavailable",
		});
		const row = await findCredentialForIdentity(db, account.identity.id);
		expect(row?.revoked_at).toBeNull();
		expect(row?.encrypted_refresh_token).not.toBe("");
		db.close();
	});

	it("has nothing to do when no credential was ever stored", async () => {
		const db = await createTestDatabase();
		const cipher = new TokenCipher({ version: 1, material: testEncryptionKey() });
		const account = await findOrCreateAccountForIdentity(
			db,
			{ provider: "google", subject: "google-sub-1" },
			NOW,
		);
		const key = await createTestAppleSigningKey();
		const endpoint = fakeAppleEndpoint(() => new Response("", { status: 200 }));

		const outcome = await revokeAppleIdentityCredential({
			db,
			cipher,
			config: key.config,
			authIdentityId: account.identity.id,
			fetchImpl: endpoint.fetchImpl,
			now: NOW,
		});

		expect(outcome).toEqual({ status: "nothingToRevoke" });
		// Apple was never contacted for an account that has no Apple credential.
		expect(endpoint.requests).toHaveLength(0);
		db.close();
	});

	it("is idempotent: a second call has nothing left to revoke", async () => {
		const db = await createTestDatabase();
		const cipher = new TokenCipher({ version: 1, material: testEncryptionKey() });
		const account = await withStoredCredential(cipher, db);
		const key = await createTestAppleSigningKey();
		const endpoint = fakeAppleEndpoint(() => new Response("", { status: 200 }));

		const input = {
			db,
			cipher,
			config: key.config,
			authIdentityId: account.identity.id,
			fetchImpl: endpoint.fetchImpl,
			now: NOW,
		};
		expect(await revokeAppleIdentityCredential(input)).toEqual({
			status: "revoked",
		});
		expect(await revokeAppleIdentityCredential(input)).toEqual({
			status: "nothingToRevoke",
		});
		// Apple was asked exactly once.
		expect(endpoint.requests).toHaveLength(1);
		db.close();
	});

	it("reports a credential it cannot decrypt rather than pretending it revoked one", async () => {
		const db = await createTestDatabase();
		const writer = new TokenCipher({ version: 1, material: testEncryptionKey() });
		const account = await withStoredCredential(writer, db);
		// A deployment carrying a different key.
		const reader = new TokenCipher({ version: 1, material: testEncryptionKey() });
		const key = await createTestAppleSigningKey();
		const endpoint = fakeAppleEndpoint(() => new Response("", { status: 200 }));

		const outcome = await revokeAppleIdentityCredential({
			db,
			cipher: reader,
			config: key.config,
			authIdentityId: account.identity.id,
			fetchImpl: endpoint.fetchImpl,
			now: NOW,
		});

		expect(outcome).toEqual({ status: "unrevocable", reason: "decryptFailed" });
		expect(endpoint.requests).toHaveLength(0);
		db.close();
	});
});
