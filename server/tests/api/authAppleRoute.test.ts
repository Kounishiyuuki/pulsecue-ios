import { Hono } from "hono";
import { describe, expect, it } from "vitest";
import { StaticJwksProvider } from "../../src/api/auth/jwks";
import { findIdentity } from "../../src/api/db/accounts";
import { findActiveSessionByToken } from "../../src/api/db/sessions";
import { makeAppleAuthHandler } from "../../src/api/routes/authApple";
import type { ApiEnv } from "../../src/api/types";
import {
	TEST_AUDIENCE,
	appleClaims,
	createTestSigner,
	hashedNonce,
} from "./support/appleTokens";
import { type TestDatabase, createTestDatabase } from "./support/sqliteD1";

const RAW_NONCE = "route-nonce";
const NOW = 1_800_000_100;

async function makeApp(
	db: TestDatabase,
	signer: Awaited<ReturnType<typeof createTestSigner>>,
	overrides: { audience?: string; jwks?: StaticJwksProvider } = {},
) {
	const app = new Hono<{ Bindings: ApiEnv }>();
	app.post(
		"/v1/auth/apple",
		makeAppleAuthHandler({
			jwks: overrides.jwks ?? signer.jwks,
			audience: overrides.audience ?? TEST_AUDIENCE,
			now: () => NOW,
		}),
	);
	return (body: unknown) =>
		app.request(
			"/v1/auth/apple",
			{
				method: "POST",
				headers: { "content-type": "application/json" },
				body: JSON.stringify(body),
			},
			{ DB: db, APPLE_AUDIENCE: TEST_AUDIENCE } as unknown as ApiEnv,
		);
}

async function tokenFor(
	signer: Awaited<ReturnType<typeof createTestSigner>>,
	overrides: Record<string, unknown> = {},
	nonce = RAW_NONCE,
) {
	return signer.sign(
		await appleClaims({ nonce: await hashedNonce(nonce), ...overrides }),
	);
}

describe("POST /v1/auth/apple", () => {
	it("creates an account and returns a usable session", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const post = await makeApp(db, signer);

		const response = await post({
			identityToken: await tokenFor(signer, { sub: "apple-sub-1" }),
			rawNonce: RAW_NONCE,
			deviceName: "iPhone",
		});

		expect(response.status).toBe(200);
		const body = (await response.json()) as {
			sessionToken: string;
			expiresAt: number;
			user: { id: string; created: boolean };
		};
		expect(body.user.created).toBe(true);
		expect(body.sessionToken).toMatch(/^[A-Za-z0-9_-]{43}$/);

		// The session actually works, and belongs to the new account.
		const session = await findActiveSessionByToken(db, body.sessionToken, NOW + 1);
		expect(session?.user_id).toBe(body.user.id);
		// The subject stored is Apple's, from the signed token.
		const identity = await findIdentity(db, "apple", "apple-sub-1");
		expect(identity?.user_id).toBe(body.user.id);
		db.close();
	});

	it("signs a returning user into the same account", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const post = await makeApp(db, signer);

		const first = await post({
			identityToken: await tokenFor(signer, { sub: "apple-sub-1" }, "nonce-a"),
			rawNonce: "nonce-a",
		});
		const second = await post({
			identityToken: await tokenFor(signer, { sub: "apple-sub-1" }, "nonce-b"),
			rawNonce: "nonce-b",
		});

		const a = (await first.json()) as { user: { id: string; created: boolean } };
		const b = (await second.json()) as { user: { id: string; created: boolean } };
		expect(b.user.id).toBe(a.user.id);
		expect(b.user.created).toBe(false);
		expect(await db.count("users")).toBe(1);
		db.close();
	});

	it("refuses a replayed request", async () => {
		// Same body twice: the signature and every claim still check out, so
		// only single-use nonce enforcement can stop it.
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const post = await makeApp(db, signer);
		const body = {
			identityToken: await tokenFor(signer, { sub: "apple-sub-1" }),
			rawNonce: RAW_NONCE,
		};

		expect((await post(body)).status).toBe(200);
		const replay = await post(body);

		expect(replay.status).toBe(401);
		// The replay created nothing.
		expect(await db.count("sessions")).toBe(1);
		db.close();
	});

	it("answers 401 identically for every kind of bad credential", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const impostor = await createTestSigner(signer.kid);
		const post = await makeApp(db, signer);

		const cases = [
			// Wrong signer.
			{
				identityToken: await impostor.sign(
					await appleClaims({ nonce: await hashedNonce(RAW_NONCE) }),
				),
				rawNonce: RAW_NONCE,
			},
			// Wrong audience.
			{
				identityToken: await tokenFor(signer, { aud: "com.someone.else" }),
				rawNonce: RAW_NONCE,
			},
			// Expired.
			{
				identityToken: await tokenFor(signer, { exp: NOW - 3600 }),
				rawNonce: RAW_NONCE,
			},
			// Nonce does not match.
			{
				identityToken: await tokenFor(signer),
				rawNonce: "a-different-nonce",
			},
		];

		const bodies: string[] = [];
		for (const body of cases) {
			const response = await post(body);
			expect(response.status).toBe(401);
			const json = (await response.json()) as {
				error: { code: string; message: string; correlationId: string };
			};
			expect(json.error.code).toBe("invalid_credentials");
			// A correlation id differs per request; everything else must not.
			bodies.push(JSON.stringify({ ...json.error, correlationId: "" }));
		}
		expect(new Set(bodies).size).toBe(1);
		// None of them created anything.
		expect(await db.count("users")).toBe(0);
		expect(await db.count("sessions")).toBe(0);
		db.close();
	});

	it("never echoes the token, nonce or subject back to the client", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const post = await makeApp(db, signer);
		const identityToken = await tokenFor(signer, { sub: "apple-secret-sub" });

		const response = await post({ identityToken, rawNonce: "wrong-nonce" });
		const text = await response.text();

		expect(text).not.toContain(identityToken);
		expect(text).not.toContain("apple-secret-sub");
		expect(text).not.toContain("wrong-nonce");
		db.close();
	});

	it("rejects a malformed body with 400 and creates nothing", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const post = await makeApp(db, signer);

		const response = await post({ rawNonce: RAW_NONCE });

		expect(response.status).toBe(400);
		expect(await db.count("users")).toBe(0);
		db.close();
	});

	it("refuses to sign anyone in when the audience is unconfigured", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const post = await makeApp(db, signer, { audience: "" });

		const response = await post({
			identityToken: await tokenFor(signer),
			rawNonce: RAW_NONCE,
		});

		expect(response.status).toBe(401);
		expect(await db.count("users")).toBe(0);
		db.close();
	});

	it("reports 503, not a bad credential, when Apple's keys are unreachable", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const failing = {
			keyForId: async () => {
				const { JwksFetchError } = await import("../../src/api/auth/jwks");
				throw new JwksFetchError("request failed");
			},
			invalidate: () => {},
		};
		const post = await makeApp(db, signer, {
			jwks: failing as unknown as StaticJwksProvider,
		});

		const response = await post({
			identityToken: await tokenFor(signer),
			rawNonce: RAW_NONCE,
		});

		expect(response.status).toBe(503);
		db.close();
	});
});
