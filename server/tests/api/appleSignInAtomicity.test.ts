/**
 * The two half-states an Apple sign-in must never leave behind.
 *
 *   A credential stored with no session — the account exists and holds an
 *   Apple grant, but nobody is signed in and nothing reported a failure.
 *
 *   An Apple refresh token that was issued and never stored — live at Apple,
 *   invisible here, and impossible to revoke at account deletion.
 *
 * Both used to be reachable. The first because a guarded `INSERT … WHERE
 * EXISTS` writes zero rows and *succeeds*, so the batch committed the
 * credential anyway; the second because a database failure after a successful
 * exchange simply dropped the token on the floor.
 *
 * These tests are written so that restoring either bug fails them.
 */

import { Hono } from "hono";
import { describe, expect, it } from "vitest";
import { TokenCipher } from "../../src/api/crypto/tokenCipher";
import {
	AccountUnavailableError,
	findOrCreateAccountForIdentity,
	markUserDeleting,
} from "../../src/api/db/accounts";
import {
	findCredentialForIdentity,
	prepareCredentialUpsert,
	readRefreshToken,
	saveCredentialAndIssueSession,
} from "../../src/api/db/providerCredentials";
import { createSession } from "../../src/api/db/sessions";
import { makeAppleAuthHandler } from "../../src/api/routes/authApple";
import type { ApiEnv, SqlDatabase, SqlStatement } from "../../src/api/types";
import {
	TEST_AUDIENCE,
	appleClaims,
	createTestSigner,
	hashedNonce,
} from "./support/appleTokens";
import {
	appleTokenResponseFor,
	createTestAppleSigningKey,
	fakeAppleEndpoint,
	testEncryptionKey,
} from "./support/appleProduction";
import { type TestDatabase, createTestDatabase } from "./support/sqliteD1";

const NOW = 1_800_000_100;
const RAW_NONCE = "atomicity-nonce";
const SUBJECT = "apple-sub-1";

function cipher(): TokenCipher {
	return new TokenCipher({ version: 1, material: testEncryptionKey() });
}

async function appleAccount(db: TestDatabase, subject = SUBJECT) {
	return findOrCreateAccountForIdentity(db, { provider: "apple", subject }, NOW);
}

// MARK: - The repository invariant

describe("credential and session commit together, or not at all", () => {
	it("commits both for an active user", async () => {
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
			now: NOW,
		});

		expect(issued.token).toBeTruthy();
		expect(await db.count("sessions")).toBe(1);
		expect(await readRefreshToken(db, c, account.identity.id)).toBe(
			"apple-refresh-token",
		);
		db.close();
	});

	it("rolls the credential back when the user is deleting", async () => {
		// THE regression. The session INSERT used to be
		// `INSERT … SELECT … WHERE EXISTS (… active …)`, which writes zero rows
		// for a deleting user and *succeeds* — so D1 committed the batch and
		// the credential landed with no session beside it. Nothing raised, and
		// a test that only checked "no session exists" passed happily.
		//
		// Now a trigger makes it a statement failure. Restore the guarded
		// INSERT and this fails on the credential assertions below.
		const db = await createTestDatabase();
		const account = await appleAccount(db);
		const c = cipher();

		// A credential already on file, as a returning user would have.
		await (
			await prepareCredentialUpsert(
				db,
				c,
				{
					authIdentityId: account.identity.id,
					provider: "apple",
					refreshToken: "original-refresh-token",
				},
				NOW,
			)
		).run();
		await markUserDeleting(db, account.user.id, NOW);

		await expect(
			saveCredentialAndIssueSession(db, c, {
				userId: account.user.id,
				credential: {
					authIdentityId: account.identity.id,
					provider: "apple",
					refreshToken: "replacement-refresh-token",
				},
				now: NOW,
			}),
		).rejects.toBeInstanceOf(AccountUnavailableError);

		// No session…
		expect(await db.count("sessions")).toBe(0);
		// …and, the part the old code got wrong, the credential is untouched.
		expect(await readRefreshToken(db, c, account.identity.id)).toBe(
			"original-refresh-token",
		);
		db.close();
	});

	it("writes no credential at all when a deleting user has none yet", async () => {
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

		expect(await db.count("provider_credentials")).toBe(0);
		expect(await db.count("sessions")).toBe(0);
		db.close();
	});

	it("refuses a plain session insert for a deleting user, as a failure", async () => {
		// The guard is the database's, so it holds for every caller — not just
		// the batched Apple path.
		const db = await createTestDatabase();
		const account = await appleAccount(db);
		await markUserDeleting(db, account.user.id, NOW);

		await expect(
			createSession(db, account.user.id, { now: NOW }),
		).rejects.toBeInstanceOf(AccountUnavailableError);
		expect(await db.count("sessions")).toBe(0);
		db.close();
	});

	it("loses the credential too when the session statement fails for any reason", async () => {
		// Not about deletion: any statement failure in the batch must take the
		// credential with it.
		const db = await createTestDatabase();
		const account = await appleAccount(db);
		const c = cipher();

		await expect(
			saveCredentialAndIssueSession(db, c, {
				userId: "no-such-user",
				credential: {
					authIdentityId: account.identity.id,
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

	it("survives the race where the account starts deleting mid-request", async () => {
		// Resolving the account first proves it was active; this covers the
		// window between that check and the write.
		const db = await createTestDatabase();
		const account = await appleAccount(db);
		const c = cipher();

		// The account was active when resolved…
		expect(account.user.state).toBe("active");
		// …and deletion lands before the credential/session batch runs.
		await markUserDeleting(db, account.user.id, NOW);

		await expect(
			saveCredentialAndIssueSession(db, c, {
				userId: account.user.id,
				credential: {
					authIdentityId: account.identity.id,
					provider: "apple",
					refreshToken: "apple-refresh-token",
				},
				now: NOW,
			}),
		).rejects.toBeInstanceOf(AccountUnavailableError);

		expect(await db.count("provider_credentials")).toBe(0);
		expect(await db.count("sessions")).toBe(0);
		db.close();
	});
});

// MARK: - Provider consistency

describe("a credential cannot claim a provider its identity does not have", () => {
	it("refuses an Apple credential on a Google identity", async () => {
		// Storing an Apple refresh token against a Google identity would break
		// two things at once: deletion would try to revoke the wrong provider,
		// and the ciphertext's AAD — which binds the provider name — would no
		// longer open. The composite foreign key makes the pair
		// unrepresentable.
		const db = await createTestDatabase();
		const google = await findOrCreateAccountForIdentity(
			db,
			{ provider: "google", subject: "google-sub-1" },
			NOW,
		);

		await expect(
			(
				await prepareCredentialUpsert(
					db,
					cipher(),
					{
						authIdentityId: google.identity.id,
						provider: "apple",
						refreshToken: "apple-refresh-token",
					},
					NOW,
				)
			).run(),
		).rejects.toThrow();

		expect(await db.count("provider_credentials")).toBe(0);
		db.close();
	});

	it("accepts a matching provider", async () => {
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

		expect(await readRefreshToken(db, c, account.identity.id)).toBe(
			"apple-refresh-token",
		);
		db.close();
	});

	it("does not destroy an existing credential when a mismatch is attempted", async () => {
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
					refreshToken: "original-refresh-token",
				},
				NOW,
			)
		).run();

		await expect(
			(
				await prepareCredentialUpsert(
					db,
					c,
					{
						authIdentityId: account.identity.id,
						provider: "google",
						refreshToken: "wrong-provider-token",
					},
					NOW,
				)
			).run(),
		).rejects.toThrow();

		const row = await findCredentialForIdentity(db, account.identity.id);
		expect(row?.provider).toBe("apple");
		expect(await readRefreshToken(db, c, account.identity.id)).toBe(
			"original-refresh-token",
		);
		db.close();
	});

	it("keeps the stored provider consistent with the AAD that opens it", async () => {
		// The row's provider is what `readRefreshToken` feeds the AAD, so a row
		// whose provider disagreed with its identity would be undecryptable.
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
		expect(row?.provider).toBe("apple");
		expect(await readRefreshToken(db, c, account.identity.id)).toBe(
			"apple-refresh-token",
		);
		db.close();
	});
});

// MARK: - Compensation

/** A database that fails the credential/session batch on demand. */
function databaseWithFailingBatch(db: TestDatabase): SqlDatabase & {
	close(): void;
	count(table: string): Promise<number>;
	prepare(sql: string): SqlStatement;
} {
	return {
		prepare: (sql: string) => db.prepare(sql),
		batch: async () => {
			throw new Error("d1 unavailable");
		},
		count: (table: string) => db.count(table),
		close: () => db.close(),
	};
}

describe("an exchanged refresh token is never left orphaned", () => {
	/**
	 * Signs in against a database whose batches fail.
	 *
	 * The account is created up front on the *real* database, so
	 * `findOrCreateAccountForIdentity` takes its existing-account path and
	 * needs no batch. The only batch left is the credential + session one —
	 * which is precisely the failure this suite is about, and it happens
	 * strictly after the Apple exchange has handed us a live refresh token.
	 */
	async function signIn(
		db: SqlDatabase,
		options: {
			revokeResponder?: () => Response;
			subject?: string;
		} = {},
	) {
		const signer = await createTestSigner();
		const key = await createTestAppleSigningKey();
		const subject = options.subject ?? SUBJECT;

		const endpoint = fakeAppleEndpoint(async (request) => {
			if (request.url.endsWith("/auth/revoke")) {
				return (
					options.revokeResponder?.() ?? new Response("", { status: 200 })
				);
			}
			return appleTokenResponseFor(signer, {
				sub: subject,
				audience: key.config.clientId,
				now: NOW,
			});
		});

		const app = new Hono<{ Bindings: ApiEnv }>();
		app.post(
			"/v1/auth/apple",
			makeAppleAuthHandler({
				jwks: signer.jwks,
				audience: TEST_AUDIENCE,
				clientSecret: key.config,
				cipher: cipher(),
				fetchImpl: endpoint.fetchImpl,
				now: () => NOW,
			}),
		);

		const identityToken = await signer.sign(
			await appleClaims({ sub: subject, nonce: await hashedNonce(RAW_NONCE) }),
		);
		const response = await app.request(
			"/v1/auth/apple",
			{
				method: "POST",
				headers: { "content-type": "application/json" },
				body: JSON.stringify({
					identityToken,
					authorizationCode: "test-authorization-code",
					rawNonce: RAW_NONCE,
				}),
			},
			{ DB: db, APPLE_AUDIENCE: TEST_AUDIENCE } as unknown as ApiEnv,
		);
		return { response, endpoint };
	}

	it("revokes the token at Apple when persistence fails", async () => {
		// Without compensation the token stays live at Apple with nothing on
		// our side pointing at it: unrevokable at deletion, and invisible.
		const base = await createTestDatabase();
		await appleAccount(base);
		const db = databaseWithFailingBatch(base);

		const { response, endpoint } = await signIn(db);

		expect(response.status).toBe(503);
		const revokes = endpoint.requests.filter((r) =>
			r.url.endsWith("/auth/revoke"),
		);
		expect(revokes).toHaveLength(1);
		expect(revokes[0]?.form.token).toBe("test-refresh-token");
		expect(revokes[0]?.form.token_type_hint).toBe("refresh_token");
		base.close();
	});

	it("issues no session when persistence fails, compensated or not", async () => {
		for (const revokeResponder of [
			() => new Response("", { status: 200 }),
			() => new Response("", { status: 400 }),
			() => new Response("", { status: 503 }),
		]) {
			const base = await createTestDatabase();
			await appleAccount(base);
			const db = databaseWithFailingBatch(base);

			const { response } = await signIn(db, { revokeResponder });
			const text = await response.text();

			expect(response.status).toBe(503);
			expect(text).not.toContain("sessionToken");
			expect(await base.count("sessions")).toBe(0);
			expect(await base.count("provider_credentials")).toBe(0);
			base.close();
		}
	});

	it("still fails the request when compensation itself fails", async () => {
		// A failed compensation must never be reported as success, and must
		// never be recorded as a revocation that happened.
		const base = await createTestDatabase();
		await appleAccount(base);
		const db = databaseWithFailingBatch(base);

		const { response } = await signIn(db, {
			revokeResponder: () => new Response("", { status: 500 }),
		});

		expect(response.status).toBe(503);
		const body = (await response.json()) as { error: { code: string } };
		expect(body.error.code).toBe("service_unavailable");
		base.close();
	});

	it("leaks nothing about the token in the response or the log", async () => {
		const base = await createTestDatabase();
		await appleAccount(base, "000123.secret.subject");
		const db = databaseWithFailingBatch(base);

		const lines: string[] = [];
		const originalWarn = console.warn;
		const originalError = console.error;
		console.warn = (...args: unknown[]) => lines.push(args.join(" "));
		console.error = (...args: unknown[]) => lines.push(args.join(" "));
		let text: string;
		try {
			const { response } = await signIn(db, { subject: "000123.secret.subject" });
			text = await response.text();
		} finally {
			console.warn = originalWarn;
			console.error = originalError;
		}

		const logged = lines.join("\n");
		for (const secret of [
			"test-refresh-token",
			"test-authorization-code",
			"000123.secret.subject",
		]) {
			expect(text, secret).not.toContain(secret);
			expect(logged, secret).not.toContain(secret);
		}
		base.close();
	});

	it("does not call revoke at all when persistence succeeds", async () => {
		const db = await createTestDatabase();

		const { response, endpoint } = await signIn(db);

		expect(response.status).toBe(200);
		expect(
			endpoint.requests.filter((r) => r.url.endsWith("/auth/revoke")),
		).toHaveLength(0);
		db.close();
	});
});
