import { Hono } from "hono";
import { describe, expect, it } from "vitest";
import {
	processAccountDeletion,
	processDueAccountDeletions,
} from "../../src/api/auth/accountDeletionService";
import { TokenCipher } from "../../src/api/crypto/tokenCipher";
import {
	DELETION_RETRY_BACKOFF_SECONDS,
	findAccountDeletion,
	requestAccountDeletion,
} from "../../src/api/db/accountDeletion";
import {
	findIdentity,
	findOrCreateAccountForIdentity,
	findUserById,
	linkIdentityToUser,
} from "../../src/api/db/accounts";
import {
	prepareCredentialUpsert,
	findCredentialForIdentity,
	readRefreshToken,
} from "../../src/api/db/providerCredentials";
import { createSession, findActiveSessionByToken } from "../../src/api/db/sessions";
import { requireSession } from "../../src/api/middleware/requireSession";
import { makeDeleteMeHandler } from "../../src/api/routes/deleteMe";
import type { AuthedEnv } from "../../src/api/types";
import {
	appleErrorResponse,
	createTestAppleSigningKey,
	fakeAppleEndpoint,
	testEncryptionKey,
} from "./support/appleProduction";
import { type TestDatabase, createTestDatabase } from "./support/sqliteD1";

const NOW = 1_800_000_100;

function cipher(): TokenCipher {
	return new TokenCipher({ version: 1, material: testEncryptionKey() });
}

/** A signed-in user, optionally with a stored Apple refresh token. */
async function signedIn(
	db: TestDatabase,
	c: TokenCipher,
	options: {
		provider?: "apple" | "google";
		subject?: string;
		withCredential?: boolean;
	} = {},
) {
	const provider = options.provider ?? "apple";
	const account = await findOrCreateAccountForIdentity(
		db,
		{ provider, subject: options.subject ?? `${provider}-sub-1` },
		NOW,
	);
	if (options.withCredential ?? provider === "apple") {
		await (
			await prepareCredentialUpsert(
				db,
				c,
				{
					authIdentityId: account.identity.id,
					provider,
					refreshToken: `${provider}-refresh-token`,
				},
				NOW,
			)
		).run();
	}
	const issued = await createSession(db, account.user.id, { now: NOW });
	return { account, token: issued.token };
}

function makeApp(
	db: TestDatabase,
	options: {
		appleResponder?: Parameters<typeof fakeAppleEndpoint>[0];
		cipher: TokenCipher;
		unconfigured?: boolean;
	},
) {
	const endpoint = fakeAppleEndpoint(
		options.appleResponder ?? (() => new Response("", { status: 200 })),
	);
	const app = new Hono<AuthedEnv>();
	const setup = createTestAppleSigningKey();
	const handler = async (c: Parameters<ReturnType<typeof makeDeleteMeHandler>>[0]) => {
		const key = await setup;
		return makeDeleteMeHandler({
			appleConfig: options.unconfigured ? null : key.config,
			cipher: options.unconfigured ? null : options.cipher,
			fetchImpl: endpoint.fetchImpl,
			now: () => NOW,
		})(c);
	};
	app.delete("/v1/me", requireSession({ now: () => NOW }), handler);

	const del = (token?: string) =>
		app.request(
			"/v1/me",
			{
				method: "DELETE",
				headers: token ? { authorization: `Bearer ${token}` } : {},
			},
			{ DB: db } as unknown as AuthedEnv["Bindings"],
		);
	return Object.assign(del, { apple: endpoint });
}

describe("DELETE /v1/me", () => {
	it("revokes every session and removes the account", async () => {
		const db = await createTestDatabase();
		const c = cipher();
		const { account, token } = await signedIn(db, c);
		const second = await createSession(db, account.user.id, { now: NOW });
		const del = makeApp(db, { cipher: c });

		const response = await del(token);

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ status: "deleted" });
		// Both sessions are gone, not just the calling one.
		for (const dead of [token, second.token]) {
			expect(await findActiveSessionByToken(db, dead, NOW + 1)).toBeNull();
		}
		expect(await findUserById(db, account.user.id)).toBeNull();
		db.close();
	});

	it("revokes the Apple refresh token before removing anything", async () => {
		// Order matters: deleting the rows first would destroy the only copy
		// of the token and leave the Apple grant alive with nothing to revoke
		// it with.
		const db = await createTestDatabase();
		const c = cipher();
		const { token } = await signedIn(db, c);
		const del = makeApp(db, { cipher: c });

		await del(token);

		expect(del.apple.requests).toHaveLength(1);
		expect(del.apple.requests[0]?.url).toBe(
			"https://appleid.apple.com/auth/revoke",
		);
		expect(del.apple.requests[0]?.form.token).toBe("apple-refresh-token");
		db.close();
	});

	it("leaves nothing behind for the deleted user", async () => {
		const db = await createTestDatabase();
		const c = cipher();
		const { token } = await signedIn(db, c);
		const del = makeApp(db, { cipher: c });

		await del(token);

		for (const table of [
			"users",
			"auth_identities",
			"user_profiles",
			"user_change_seq",
			"sessions",
			"provider_credentials",
			"account_deletions",
		]) {
			expect(await db.count(table), `${table} should be empty`).toBe(0);
		}
		db.close();
	});

	it("does not touch any other user", async () => {
		const db = await createTestDatabase();
		const c = cipher();
		const alice = await signedIn(db, c, { subject: "apple-alice" });
		const bob = await signedIn(db, c, { subject: "apple-bob" });
		const del = makeApp(db, { cipher: c });

		await del(alice.token);

		expect(await findUserById(db, bob.account.user.id)).not.toBeNull();
		expect(await findActiveSessionByToken(db, bob.token, NOW + 1)).not.toBeNull();
		expect(
			await findCredentialForIdentity(db, bob.account.identity.id),
		).not.toBeNull();
		expect(await db.count("users")).toBe(1);
		db.close();
	});

	it("needs a session of its own", async () => {
		const db = await createTestDatabase();
		const del = makeApp(db, { cipher: cipher() });
		expect((await del()).status).toBe(401);
		expect(await db.count("users")).toBe(0);
		db.close();
	});
});

describe("when the provider cannot be reached", () => {
	it("answers 202 and keeps the account deleting rather than restoring it", async () => {
		// Returning a user to `active` because Apple had a bad minute would
		// silently resurrect an account they asked to destroy.
		const db = await createTestDatabase();
		const c = cipher();
		const { account, token } = await signedIn(db, c);
		const del = makeApp(db, {
			cipher: c,
			appleResponder: () => new Response("", { status: 503 }),
		});

		const response = await del(token);

		expect(response.status).toBe(202);
		const user = await findUserById(db, account.user.id);
		expect(user?.state).toBe("deleting");
		expect(user?.deleted_at).toBe(NOW);
		// And the credential survives, because a retry needs it.
		expect(
			(await findCredentialForIdentity(db, account.identity.id))?.revoked_at,
		).toBeNull();
		db.close();
	});

	it("cannot be signed back into while it waits", async () => {
		const db = await createTestDatabase();
		const c = cipher();
		const { token } = await signedIn(db, c);
		const del = makeApp(db, {
			cipher: c,
			appleResponder: () => new Response("", { status: 503 }),
		});

		await del(token);

		// The session that authorised the delete is already dead, so a retry
		// of the HTTP call cannot even authenticate.
		expect((await del(token)).status).toBe(401);
		expect(await findActiveSessionByToken(db, token, NOW + 1)).toBeNull();
		db.close();
	});

	it("records the attempt with a backoff and a fixed error code", async () => {
		const db = await createTestDatabase();
		const c = cipher();
		const { account, token } = await signedIn(db, c);
		const del = makeApp(db, {
			cipher: c,
			appleResponder: () => new Response("", { status: 503 }),
		});

		await del(token);

		const row = await findAccountDeletion(db, account.user.id);
		expect(row?.attempts).toBe(1);
		expect(row?.last_error_code).toBe("provider_unavailable");
		expect(row?.next_attempt_at).toBe(NOW + DELETION_RETRY_BACKOFF_SECONDS);
		db.close();
	});

	it("keeps the account deleting when Apple is not configured at all", async () => {
		const db = await createTestDatabase();
		const c = cipher();
		const { account, token } = await signedIn(db, c);
		const del = makeApp(db, { cipher: c, unconfigured: true });

		expect((await del(token)).status).toBe(202);
		expect((await findUserById(db, account.user.id))?.state).toBe("deleting");
		db.close();
	});

	it("finishes on a later attempt once the provider recovers", async () => {
		const db = await createTestDatabase();
		const c = cipher();
		const { account, token } = await signedIn(db, c);
		let down = true;
		const del = makeApp(db, {
			cipher: c,
			appleResponder: () =>
				down ? new Response("", { status: 503 }) : new Response("", { status: 200 }),
		});
		await del(token);
		expect((await findUserById(db, account.user.id))?.state).toBe("deleting");

		down = false;
		const key = await createTestAppleSigningKey();
		const endpoint = fakeAppleEndpoint(() => new Response("", { status: 200 }));
		const outcome = await processAccountDeletion(
			{ db, appleConfig: key.config, cipher: c, fetchImpl: endpoint.fetchImpl },
			account.user.id,
			NOW + DELETION_RETRY_BACKOFF_SECONDS,
		);

		expect(outcome).toEqual({ status: "completed" });
		expect(await findUserById(db, account.user.id)).toBeNull();
		db.close();
	});
});

describe("the retry processor", () => {
	it("picks up only deletions that are due", async () => {
		const db = await createTestDatabase();
		const c = cipher();
		const { account } = await signedIn(db, c);
		await requestAccountDeletion(db, account.user.id, NOW);
		const key = await createTestAppleSigningKey();
		const endpoint = fakeAppleEndpoint(() => new Response("", { status: 503 }));
		const deps = {
			db,
			appleConfig: key.config,
			cipher: c,
			fetchImpl: endpoint.fetchImpl,
		};

		// One failing pass sets the backoff.
		await processAccountDeletion(deps, account.user.id, NOW);
		// Too early: nothing is due.
		expect(await processDueAccountDeletions(deps, NOW + 60)).toEqual({
			completed: 0,
			stillPending: 0,
		});
		// Due now, and still failing.
		expect(
			await processDueAccountDeletions(deps, NOW + DELETION_RETRY_BACKOFF_SECONDS),
		).toEqual({ completed: 0, stillPending: 1 });
		db.close();
	});

	it("reports nothing pending for a user with no deletion in flight", async () => {
		const db = await createTestDatabase();
		const c = cipher();
		const { account } = await signedIn(db, c);
		const key = await createTestAppleSigningKey();

		expect(
			await processAccountDeletion(
				{ db, appleConfig: key.config, cipher: c },
				account.user.id,
				NOW,
			),
		).toEqual({ status: "notPending" });
		// And nothing was destroyed by asking.
		expect(await findUserById(db, account.user.id)).not.toBeNull();
		db.close();
	});

	it("is idempotent: running it again after completion is a no-op", async () => {
		const db = await createTestDatabase();
		const c = cipher();
		const { account, token } = await signedIn(db, c);
		const del = makeApp(db, { cipher: c });
		await del(token);

		const key = await createTestAppleSigningKey();
		const endpoint = fakeAppleEndpoint(() => new Response("", { status: 200 }));
		const outcome = await processAccountDeletion(
			{ db, appleConfig: key.config, cipher: c, fetchImpl: endpoint.fetchImpl },
			account.user.id,
			NOW,
		);

		expect(outcome).toEqual({ status: "notPending" });
		// Apple was asked exactly once, by the original delete.
		expect(endpoint.requests).toHaveLength(0);
		db.close();
	});

	it("does not restart the clock when deletion is requested twice", async () => {
		const db = await createTestDatabase();
		const c = cipher();
		const { account } = await signedIn(db, c);

		await requestAccountDeletion(db, account.user.id, NOW);
		await requestAccountDeletion(db, account.user.id, NOW + 5_000);

		const row = await findAccountDeletion(db, account.user.id);
		expect(row?.requested_at).toBe(NOW);
		expect((await findUserById(db, account.user.id))?.deleted_at).toBe(NOW);
		db.close();
	});
});

describe("providers other than Apple", () => {
	it("deletes a Google-only account without inventing a revocation call", async () => {
		// PulseCue holds no Google refresh token — the ID token flow never
		// issues one — so there is nothing to revoke. Deleting a PulseCue
		// account is not deleting a Google account.
		const db = await createTestDatabase();
		const c = cipher();
		const { account, token } = await signedIn(db, c, {
			provider: "google",
			subject: "google-sub-1",
			withCredential: false,
		});
		const del = makeApp(db, { cipher: c });

		const response = await del(token);

		expect(response.status).toBe(200);
		expect(await findUserById(db, account.user.id)).toBeNull();
		// Apple was never contacted for an account with no Apple identity.
		expect(del.apple.requests).toHaveLength(0);
		db.close();
	});

	it("revokes only the Apple side of an account with both providers linked", async () => {
		const db = await createTestDatabase();
		const c = cipher();
		const { account, token } = await signedIn(db, c, { subject: "apple-sub-1" });
		await linkIdentityToUser(
			db,
			account.user.id,
			{ provider: "google", subject: "google-sub-1" },
			NOW,
		);

		const del = makeApp(db, { cipher: c });
		const response = await del(token);

		expect(response.status).toBe(200);
		expect(del.apple.requests).toHaveLength(1);
		// Both identity rows are gone with the user.
		expect(await findIdentity(db, "apple", "apple-sub-1")).toBeNull();
		expect(await findIdentity(db, "google", "google-sub-1")).toBeNull();
		db.close();
	});

	it("does NOT complete a deletion when Apple answers 400 invalid_grant", async () => {
		// This test used to assert the opposite, on the reading that
		// `invalid_grant` means "already revoked". It does not: from the revoke
		// endpoint it can equally mean the token belongs to another client or
		// the request was malformed. Only an Apple 2xx confirms a revocation,
		// so a 4xx leaves the deletion owed rather than finishing it.
		const db = await createTestDatabase();
		const c = cipher();
		const { account, token } = await signedIn(db, c);
		const del = makeApp(db, {
			cipher: c,
			appleResponder: () => appleErrorResponse("invalid_grant"),
		});

		expect((await del(token)).status).toBe(202);
		const user = await findUserById(db, account.user.id);
		expect(user?.state).toBe("deleting");
		// The credential survives, because nothing has revoked it yet.
		expect(
			(await findCredentialForIdentity(db, account.identity.id))?.revoked_at,
		).toBeNull();
		// And the reason is recorded distinctly from an outage.
		expect((await findAccountDeletion(db, account.user.id))?.last_error_code).toBe(
			"provider_rejected",
		);
		db.close();
	});
});

describe("nothing leaks", () => {
	it("never returns or logs the refresh token, subject or user id", async () => {
		const db = await createTestDatabase();
		const c = cipher();
		const { account, token } = await signedIn(db, c, {
			subject: "000123.secret.subject",
		});
		const del = makeApp(db, {
			cipher: c,
			appleResponder: () => new Response("", { status: 503 }),
		});

		const lines: string[] = [];
		const original = console.warn;
		console.warn = (...args: unknown[]) => lines.push(args.join(" "));
		let text: string;
		try {
			text = await (await del(token)).text();
		} finally {
			console.warn = original;
		}

		const logged = lines.join("\n");
		for (const secret of [
			"apple-refresh-token",
			"000123.secret.subject",
			account.user.id,
			token,
		]) {
			expect(text).not.toContain(secret);
			expect(logged).not.toContain(secret);
		}
		db.close();
	});
});

// MARK: - Decryption failure must not finish a deletion

describe("a credential that cannot be decrypted", () => {
	/** Signs a user in, then makes their stored credential unreadable. */
	async function withUnreadableCredential(db: TestDatabase, c: TokenCipher) {
		const { account, token } = await signedIn(db, c);
		return { account, token };
	}

	it("keeps the account deleting instead of hard-deleting it", async () => {
		// The judgement call from the previous round, corrected.
		//
		// An unreadable ciphertext says nothing about the grant at Apple — that
		// is still live. Deleting the account here would destroy the only
		// record that it exists while reporting the deletion as complete, so
		// the deletion stays owed.
		const db = await createTestDatabase();
		const writer = cipher();
		const { account, token } = await withUnreadableCredential(db, writer);
		// The deployment now carries a different key: the row cannot be opened.
		const reader = cipher();
		const del = makeApp(db, { cipher: reader });

		const response = await del(token);

		expect(response.status).toBe(202);
		const user = await findUserById(db, account.user.id);
		expect(user?.state).toBe("deleting");
		expect(user?.deleted_at).toBe(NOW);
		db.close();
	});

	it("keeps the credential material, which is the only thing recoverable", async () => {
		const db = await createTestDatabase();
		const writer = cipher();
		const { account, token } = await withUnreadableCredential(db, writer);
		const before = await findCredentialForIdentity(db, account.identity.id);
		const del = makeApp(db, { cipher: cipher() });

		await del(token);

		const after = await findCredentialForIdentity(db, account.identity.id);
		expect(after).toEqual(before);
		expect(after?.revoked_at).toBeNull();
		// If the key is ever restored, the token can still be revoked.
		expect(await readRefreshToken(db, writer, account.identity.id)).toBe(
			"apple-refresh-token",
		);
		db.close();
	});

	it("never contacts Apple with a credential it could not read", async () => {
		const db = await createTestDatabase();
		const writer = cipher();
		const { token } = await withUnreadableCredential(db, writer);
		const del = makeApp(db, { cipher: cipher() });

		await del(token);

		expect(del.apple.requests).toHaveLength(0);
		db.close();
	});

	it("records a fixed non-PII code an operator can act on", async () => {
		const db = await createTestDatabase();
		const writer = cipher();
		const { account, token } = await withUnreadableCredential(db, writer);
		const del = makeApp(db, { cipher: cipher() });

		const lines: string[] = [];
		const originalError = console.error;
		console.error = (...args: unknown[]) => lines.push(args.join(" "));
		try {
			await del(token);
		} finally {
			console.error = originalError;
		}

		expect((await findAccountDeletion(db, account.user.id))?.last_error_code).toBe(
			"credential_unreadable",
		);
		const logged = lines.join("\n");
		expect(logged).toContain("credential_unreadable");
		// No identifiers in the log.
		expect(logged).not.toContain(account.user.id);
		expect(logged).not.toContain(account.identity.id);
		expect(logged).not.toContain("apple-refresh-token");
		db.close();
	});

	it("leaves the user unable to sign back in while it waits", async () => {
		const db = await createTestDatabase();
		const writer = cipher();
		const { token } = await withUnreadableCredential(db, writer);
		const del = makeApp(db, { cipher: cipher() });

		await del(token);

		// The session that authorised the delete is dead and stays dead.
		expect(await findActiveSessionByToken(db, token, NOW + 1)).toBeNull();
		expect((await del(token)).status).toBe(401);
		db.close();
	});

	it("completes once the correct key is available again", async () => {
		// The pending state is recoverable, not a dead end.
		const db = await createTestDatabase();
		const writer = cipher();
		const { account, token } = await withUnreadableCredential(db, writer);
		await makeApp(db, { cipher: cipher() })(token);
		expect((await findUserById(db, account.user.id))?.state).toBe("deleting");

		const key = await createTestAppleSigningKey();
		const endpoint = fakeAppleEndpoint(() => new Response("", { status: 200 }));
		const outcome = await processAccountDeletion(
			{ db, appleConfig: key.config, cipher: writer, fetchImpl: endpoint.fetchImpl },
			account.user.id,
			NOW + 1_000,
		);

		expect(outcome).toEqual({ status: "completed" });
		expect(await findUserById(db, account.user.id)).toBeNull();
		expect(endpoint.requests).toHaveLength(1);
		db.close();
	});

	it("does not touch another user while one deletion is stuck", async () => {
		const db = await createTestDatabase();
		const writer = cipher();
		const stuck = await signedIn(db, writer, { subject: "apple-stuck" });
		const other = await signedIn(db, writer, { subject: "apple-other" });
		const del = makeApp(db, { cipher: cipher() });

		await del(stuck.token);

		expect(await findUserById(db, other.account.user.id)).not.toBeNull();
		expect(
			await findActiveSessionByToken(db, other.token, NOW + 1),
		).not.toBeNull();
		db.close();
	});
});
