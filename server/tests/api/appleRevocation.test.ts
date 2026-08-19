import { describe, expect, it } from "vitest";
import { revokeAppleIdentityCredential } from "../../src/api/auth/appleRevocation";
import { TokenCipher } from "../../src/api/crypto/tokenCipher";
import { findOrCreateAccountForIdentity } from "../../src/api/db/accounts";
import {
	findCredentialForIdentity,
	prepareCredentialUpsert,
	readRefreshToken,
} from "../../src/api/db/providerCredentials";
import {
	appleErrorResponse,
	createTestAppleSigningKey,
	fakeAppleEndpoint,
	testEncryptionKey,
} from "./support/appleProduction";
import { type TestDatabase, createTestDatabase } from "./support/sqliteD1";

const NOW = 1_800_000_100;

async function withStoredCredential(
	cipher: TokenCipher,
	db: TestDatabase,
	subject = "apple-sub-1",
) {
	const account = await findOrCreateAccountForIdentity(
		db,
		{ provider: "apple", subject },
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

	it("does NOT erase the credential when Apple answers 400 invalid_grant", async () => {
		// The regression that matters: a non-2xx is never evidence the token
		// is gone, so the material must survive for a retry. Restore the old
		// "invalid_grant means already revoked" path and this fails.
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

		expect(outcome).toEqual({
			status: "retryable",
			reason: "providerRejected",
		});
		const row = await findCredentialForIdentity(db, account.identity.id);
		expect(row?.revoked_at).toBeNull();
		expect(row?.encrypted_refresh_token).not.toBe("");
		// Still decryptable, so a retry can actually use it.
		expect(await readRefreshToken(db, cipher, account.identity.id)).toBe(
			"stored-refresh-token",
		);
		db.close();
	});

	it("keeps the credential for every non-2xx status", async () => {
		const db = await createTestDatabase();
		const cipher = new TokenCipher({ version: 1, material: testEncryptionKey() });
		const key = await createTestAppleSigningKey();

		for (const status of [400, 401, 403, 429, 500, 503]) {
			const account = await withStoredCredential(cipher, db, `apple-sub-${status}`);
			const endpoint = fakeAppleEndpoint(
				() =>
					new Response(JSON.stringify({ error: "invalid_grant" }), { status }),
			);

			const outcome = await revokeAppleIdentityCredential({
				db,
				cipher,
				config: key.config,
				authIdentityId: account.identity.id,
				fetchImpl: endpoint.fetchImpl,
				now: NOW,
			});

			expect(outcome.status, `status ${status}`).toBe("retryable");
			const row = await findCredentialForIdentity(db, account.identity.id);
			expect(row?.revoked_at, `status ${status}`).toBeNull();
			expect(row?.encrypted_refresh_token, `status ${status}`).not.toBe("");
		}
		db.close();
	});

	it("distinguishes an outage from a rejection, for the operator", async () => {
		const db = await createTestDatabase();
		const cipher = new TokenCipher({ version: 1, material: testEncryptionKey() });
		const key = await createTestAppleSigningKey();

		const outage = await withStoredCredential(cipher, db, "apple-sub-outage");
		const rejected = await withStoredCredential(cipher, db, "apple-sub-rejected");

		const run = (identityId: string, responder: () => Response) =>
			revokeAppleIdentityCredential({
				db,
				cipher,
				config: key.config,
				authIdentityId: identityId,
				fetchImpl: fakeAppleEndpoint(responder).fetchImpl,
				now: NOW,
			});

		expect(
			await run(outage.identity.id, () => new Response("", { status: 503 })),
		).toEqual({ status: "retryable", reason: "providerUnavailable" });
		expect(
			await run(rejected.identity.id, () => appleErrorResponse("invalid_client")),
		).toEqual({ status: "retryable", reason: "providerRejected" });
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
