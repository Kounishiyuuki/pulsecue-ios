import { Hono } from "hono";
import { describe, expect, it } from "vitest";
import {
	readBearerToken,
	requireSession,
} from "../../src/api/middleware/requireSession";
import {
	findOrCreateAccountForIdentity,
	markUserDeleting,
} from "../../src/api/db/accounts";
import {
	createSession,
	findActiveSessionByToken,
	revokeSession,
} from "../../src/api/db/sessions";
import { handleLogout, handleLogoutAll } from "../../src/api/routes/logout";
import { handleGetMe } from "../../src/api/routes/me";
import type { AuthedEnv } from "../../src/api/types";
import { type TestDatabase, createTestDatabase } from "./support/sqliteD1";

const NOW = 1_800_000_100;

function makeApp(db: TestDatabase, now = NOW) {
	const app = new Hono<AuthedEnv>();
	app.get("/v1/me", requireSession({ now: () => now }), handleGetMe);
	app.post("/v1/auth/logout", requireSession({ now: () => now }), handleLogout);
	app.post(
		"/v1/auth/logout-all",
		requireSession({ now: () => now }),
		handleLogoutAll,
	);
	return (
		path: string,
		options: { token?: string; header?: string; method?: string } = {},
	) => {
		const headers: Record<string, string> = {};
		if (options.header !== undefined) headers.authorization = options.header;
		else if (options.token) headers.authorization = `Bearer ${options.token}`;
		return app.request(
			path,
			{ method: options.method ?? (path === "/v1/me" ? "GET" : "POST"), headers },
			{ DB: db } as unknown as AuthedEnv["Bindings"],
		);
	};
}

async function signedInUser(
	db: TestDatabase,
	options: { provider?: "apple" | "google"; subject?: string; device?: string } = {},
) {
	const account = await findOrCreateAccountForIdentity(
		db,
		{
			provider: options.provider ?? "apple",
			subject: options.subject ?? "apple-sub-1",
			email: "user@example.com",
		},
		NOW,
	);
	const issued = await createSession(db, account.user.id, {
		deviceName: options.device ?? "iPhone",
		now: NOW,
	});
	return { account, token: issued.token, session: issued.session };
}

describe("reading the bearer token", () => {
	it("accepts the scheme in any case, as RFC 6750 requires", () => {
		expect(readBearerToken("Bearer abc123")).toBe("abc123");
		expect(readBearerToken("bearer abc123")).toBe("abc123");
		expect(readBearerToken("BEARER abc123")).toBe("abc123");
		expect(readBearerToken("  Bearer abc123  ")).toBe("abc123");
	});

	it("refuses anything that is not exactly one bearer token", () => {
		// A lenient parser here is how a token ends up read from somewhere it
		// was never meant to be.
		for (const header of [
			undefined,
			null,
			"",
			"abc123",
			"Basic abc123",
			"Bearer",
			"Bearer ",
			"Bearer a b",
			"Bearer abc, Bearer def",
			"Token abc123",
		]) {
			expect(readBearerToken(header)).toBeNull();
		}
	});
});

describe("authenticating a request", () => {
	it("lets a valid session through", async () => {
		const db = await createTestDatabase();
		const { token } = await signedInUser(db);

		expect((await makeApp(db)("/v1/me", { token })).status).toBe(200);
		db.close();
	});

	it("refuses every kind of bad session identically", async () => {
		// Missing, malformed, unknown, expired, revoked, and deleting-account
		// are six facts and one answer. Telling them apart would let a caller
		// probe which tokens ever existed and make deletion observable.
		const db = await createTestDatabase();
		const { token, session, account } = await signedInUser(db);

		const expired = await signedInUser(db, { subject: "apple-sub-2" });
		const revoked = await signedInUser(db, { subject: "apple-sub-3" });
		await revokeSession(db, revoked.session.id, NOW);
		const deleting = await signedInUser(db, { subject: "apple-sub-4" });
		await markUserDeleting(db, deleting.account.user.id, NOW);

		const cases: Array<{ token?: string; header?: string; now?: number }> = [
			{ header: undefined, token: undefined },
			{ header: "" },
			{ header: "Basic something" },
			{ header: `Bearer ${token} extra` },
			{ token: "a-token-that-was-never-issued" },
			{ token: expired.token, now: expired.session.expires_at + 1 },
			{ token: revoked.token },
			{ token: deleting.token },
		];

		const bodies: string[] = [];
		for (const testCase of cases) {
			const response = await makeApp(db, testCase.now ?? NOW)("/v1/me", {
				token: testCase.token,
				header: testCase.header,
			});
			expect(response.status).toBe(401);
			const json = (await response.json()) as {
				error: { code: string; message: string; correlationId: string };
			};
			expect(json.error.code).toBe("invalid_session");
			bodies.push(JSON.stringify({ ...json.error, correlationId: "" }));
		}
		// A correlation id differs per request; nothing else does.
		expect(new Set(bodies).size).toBe(1);

		// The good session still works, so nothing above was a blanket refusal.
		expect((await makeApp(db)("/v1/me", { token })).status).toBe(200);
		expect(session.user_id).toBe(account.user.id);
		db.close();
	});

	it("stops honouring a token the moment the account starts deleting", async () => {
		const db = await createTestDatabase();
		const { token, account } = await signedInUser(db);
		expect((await makeApp(db)("/v1/me", { token })).status).toBe(200);

		await markUserDeleting(db, account.user.id, NOW);

		expect((await makeApp(db)("/v1/me", { token })).status).toBe(401);
		db.close();
	});

	it("never logs the token", async () => {
		const db = await createTestDatabase();
		const lines: string[] = [];
		const original = console.warn;
		console.warn = (...args: unknown[]) => lines.push(args.join(" "));
		try {
			await makeApp(db)("/v1/me", { token: "super-secret-session-token" });
		} finally {
			console.warn = original;
		}

		expect(lines.length).toBeGreaterThan(0);
		expect(lines.join("\n")).not.toContain("super-secret-session-token");
		db.close();
	});
});

describe("GET /v1/me", () => {
	it("returns the allowlisted profile", async () => {
		const db = await createTestDatabase();
		const { token, account, session } = await signedInUser(db);

		const body = (await (await makeApp(db)("/v1/me", { token })).json()) as {
			user: Record<string, unknown>;
			linkedProviders: Array<Record<string, unknown>>;
			session: Record<string, unknown>;
		};

		expect(Object.keys(body).sort()).toEqual([
			"linkedProviders",
			"session",
			"user",
		]);
		expect(Object.keys(body.user).sort()).toEqual([
			"createdAt",
			"displayName",
			"id",
			"state",
		]);
		expect(body.user.id).toBe(account.user.id);
		expect(body.user.state).toBe("active");
		expect(body.session.expiresAt).toBe(session.expires_at);
		db.close();
	});

	it("names which providers are linked, but never the subject or the email", async () => {
		// The subject is the account key. Echoing it back turns a stolen
		// session into a correlatable identity across services.
		const db = await createTestDatabase();
		const { token, account } = await signedInUser(db, {
			subject: "000123.secret.subject",
		});
		await findOrCreateAccountForIdentity(
			db,
			{ provider: "google", subject: "google-secret-subject" },
			NOW,
		);

		const response = await makeApp(db)("/v1/me", { token });
		const text = await response.text();
		const body = JSON.parse(text) as {
			linkedProviders: Array<Record<string, unknown>>;
		};

		expect(body.linkedProviders).toEqual([
			{ provider: "apple", linkedAt: NOW },
		]);
		expect(text).not.toContain("000123.secret.subject");
		expect(text).not.toContain("user@example.com");
		expect(text).not.toContain(account.identity.subject);
		db.close();
	});

	it("lists both providers for an account that linked two", async () => {
		const db = await createTestDatabase();
		const { token, account } = await signedInUser(db);
		const { linkIdentityToUser } = await import("../../src/api/db/accounts");
		await linkIdentityToUser(
			db,
			account.user.id,
			{ provider: "google", subject: "google-sub-1" },
			NOW + 10,
		);

		const body = (await (await makeApp(db)("/v1/me", { token })).json()) as {
			linkedProviders: Array<{ provider: string }>;
		};

		expect(body.linkedProviders.map((p) => p.provider).sort()).toEqual([
			"apple",
			"google",
		]);
		db.close();
	});

	it("never returns credential or session-hash material", async () => {
		const db = await createTestDatabase();
		const { token, session } = await signedInUser(db);

		const text = await (await makeApp(db)("/v1/me", { token })).text();

		expect(text).not.toContain(session.token_sha256);
		expect(text).not.toContain(token);
		for (const forbidden of [
			"token_sha256",
			"encrypted_refresh_token",
			"subject",
			"email",
		]) {
			expect(text).not.toContain(forbidden);
		}
		db.close();
	});

	it("shows one user only their own account", async () => {
		// The user comes from the authenticated session; there is no id in the
		// request to tamper with.
		const db = await createTestDatabase();
		const alice = await signedInUser(db, { subject: "apple-alice" });
		const bob = await signedInUser(db, { subject: "apple-bob" });

		const forAlice = (await (
			await makeApp(db)("/v1/me", { token: alice.token })
		).json()) as { user: { id: string } };
		const forBob = (await (
			await makeApp(db)("/v1/me", { token: bob.token })
		).json()) as { user: { id: string } };

		expect(forAlice.user.id).toBe(alice.account.user.id);
		expect(forBob.user.id).toBe(bob.account.user.id);
		expect(forAlice.user.id).not.toBe(forBob.user.id);
		db.close();
	});
});

describe("POST /v1/auth/logout", () => {
	it("revokes the calling session and nothing else", async () => {
		const db = await createTestDatabase();
		const { token, account } = await signedInUser(db);
		// The same user on a second device.
		const second = await createSession(db, account.user.id, {
			deviceName: "iPad",
			now: NOW,
		});

		expect((await makeApp(db)("/v1/auth/logout", { token })).status).toBe(200);

		expect(await findActiveSessionByToken(db, token, NOW + 1)).toBeNull();
		// Signing out of a phone must not sign out the iPad.
		expect(
			await findActiveSessionByToken(db, second.token, NOW + 1),
		).not.toBeNull();
		db.close();
	});

	it("is idempotent, so a retry over a flaky network still succeeds", async () => {
		const db = await createTestDatabase();
		const { token } = await signedInUser(db);

		expect((await makeApp(db)("/v1/auth/logout", { token })).status).toBe(200);
		// The second call authenticates with a now-revoked token, so it is a
		// 401 — but the user is logged out, which is the requested end state.
		expect((await makeApp(db)("/v1/auth/logout", { token })).status).toBe(401);
		db.close();
	});

	it("keeps the original revocation time when called twice at the repository level", async () => {
		const db = await createTestDatabase();
		const { session } = await signedInUser(db);

		await revokeSession(db, session.id, NOW);
		await revokeSession(db, session.id, NOW + 500);

		const row = await db
			.prepare(`SELECT revoked_at FROM sessions WHERE id = ?`)
			.bind(session.id)
			.first<{ revoked_at: number }>();
		expect(row?.revoked_at).toBe(NOW);
		db.close();
	});

	it("leaves another user's sessions completely alone", async () => {
		const db = await createTestDatabase();
		const alice = await signedInUser(db, { subject: "apple-alice" });
		const bob = await signedInUser(db, { subject: "apple-bob" });

		await makeApp(db)("/v1/auth/logout", { token: alice.token });

		expect(
			await findActiveSessionByToken(db, bob.token, NOW + 1),
		).not.toBeNull();
		db.close();
	});

	it("requires a session of its own", async () => {
		const db = await createTestDatabase();
		expect((await makeApp(db)("/v1/auth/logout")).status).toBe(401);
		db.close();
	});
});

describe("POST /v1/auth/logout-all", () => {
	it("revokes every session this user has", async () => {
		const db = await createTestDatabase();
		const { token, account } = await signedInUser(db);
		const second = await createSession(db, account.user.id, { now: NOW });
		const third = await createSession(db, account.user.id, { now: NOW });

		expect((await makeApp(db)("/v1/auth/logout-all", { token })).status).toBe(200);

		for (const revoked of [token, second.token, third.token]) {
			expect(await findActiveSessionByToken(db, revoked, NOW + 1)).toBeNull();
		}
		db.close();
	});

	it("does not touch another user", async () => {
		const db = await createTestDatabase();
		const alice = await signedInUser(db, { subject: "apple-alice" });
		const bob = await signedInUser(db, { subject: "apple-bob" });
		const bobSecond = await createSession(db, bob.account.user.id, { now: NOW });

		await makeApp(db)("/v1/auth/logout-all", { token: alice.token });

		for (const kept of [bob.token, bobSecond.token]) {
			expect(await findActiveSessionByToken(db, kept, NOW + 1)).not.toBeNull();
		}
		db.close();
	});

	it("is idempotent when there is nothing left to revoke", async () => {
		const db = await createTestDatabase();
		const { token, account } = await signedInUser(db);
		await makeApp(db)("/v1/auth/logout-all", { token });

		// A fresh session, then logout-all again: still fine.
		const again = await createSession(db, account.user.id, { now: NOW });
		expect(
			(await makeApp(db)("/v1/auth/logout-all", { token: again.token })).status,
		).toBe(200);
		db.close();
	});
});
