import { Hono } from "hono";
import { describe, expect, it } from "vitest";
import { StaticJwksProvider } from "../../src/api/auth/jwks";
import { base64urlEncode } from "../../src/api/auth/jwt";
import { findIdentity } from "../../src/api/db/accounts";
import { findActiveSessionByToken } from "../../src/api/db/sessions";
import { makeAppleAuthHandler } from "../../src/api/routes/authApple";
import type { AppleClientSecretConfig } from "../../src/api/auth/appleClientSecret";
import { TokenCipher } from "../../src/api/crypto/tokenCipher";
import { readRefreshToken } from "../../src/api/db/providerCredentials";
import type { ApiEnv } from "../../src/api/types";
import {
	TEST_AUDIENCE,
	appleClaims,
	createTestSigner,
	hashedNonce,
} from "./support/appleTokens";
import {
	appleErrorResponse,
	appleTokenResponse,
	createTestAppleSigningKey,
	fakeAppleEndpoint,
	testEncryptionKey,
} from "./support/appleProduction";
import { type TestDatabase, createTestDatabase } from "./support/sqliteD1";

const RAW_NONCE = "route-nonce";
const NOW = 1_800_000_100;

const AUTHORIZATION_CODE = "test-authorization-code";

async function makeApp(
	db: TestDatabase,
	signer: Awaited<ReturnType<typeof createTestSigner>>,
	overrides: {
		audience?: string;
		jwks?: StaticJwksProvider;
		clientSecret?: AppleClientSecretConfig | null;
		cipher?: TokenCipher | null;
		appleResponder?: Parameters<typeof fakeAppleEndpoint>[0];
	} = {},
) {
	const key = await createTestAppleSigningKey();
	const endpoint = fakeAppleEndpoint(
		overrides.appleResponder ?? (() => appleTokenResponse()),
	);
	const app = new Hono<{ Bindings: ApiEnv }>();
	app.post(
		"/v1/auth/apple",
		makeAppleAuthHandler({
			jwks: overrides.jwks ?? signer.jwks,
			audience: overrides.audience ?? TEST_AUDIENCE,
			clientSecret:
				overrides.clientSecret === undefined ? key.config : overrides.clientSecret,
			cipher:
				overrides.cipher === undefined
					? new TokenCipher({ version: 1, material: testEncryptionKey() })
					: overrides.cipher,
			fetchImpl: endpoint.fetchImpl,
			now: () => NOW,
		}),
	);
	// The authorization code is required now, so it is defaulted in rather
	// than repeated in every body; a test that cares passes its own.
	const post = (body: Record<string, unknown>) =>
		app.request(
			"/v1/auth/apple",
			{
				method: "POST",
				headers: { "content-type": "application/json" },
				body: JSON.stringify({ authorizationCode: AUTHORIZATION_CODE, ...body }),
			},
			{ DB: db, APPLE_AUDIENCE: TEST_AUDIENCE } as unknown as ApiEnv,
		);
	return Object.assign(post, { apple: endpoint, key });
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

/** A token with literally these segments, for shapes a signer cannot make. */
function rawToken(header: string, payload: string): string {
	const encode = (json: string) =>
		base64urlEncode(new TextEncoder().encode(json));
	return `${encode(header)}.${encode(payload)}.c2ln`;
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
			// Payload is not a JSON object — must be a 401, not a crash.
			{
				identityToken: rawToken('{"alg":"RS256","kid":"k1"}', "null"),
				rawNonce: RAW_NONCE,
			},
			{
				identityToken: rawToken('{"alg":"RS256","kid":"k1"}', '["iss"]'),
				rawNonce: RAW_NONCE,
			},
			{
				identityToken: rawToken('{"alg":"RS256","kid":"k1"}', '"a-string"'),
				rawNonce: RAW_NONCE,
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

describe("POST /v1/auth/apple — authorization code lifecycle", () => {
	it("requires the authorization code", async () => {
		// Apple hands it over once per sign-in and it cannot be re-requested.
		// Accepting a sign-in without it would create an account that can never
		// meet Apple's revoke-on-deletion requirement.
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const post = await makeApp(db, signer);

		const response = await post({
			authorizationCode: undefined,
			identityToken: await tokenFor(signer),
			rawNonce: RAW_NONCE,
		});

		expect(response.status).toBe(400);
		expect(await db.count("users")).toBe(0);
		expect(await db.count("sessions")).toBe(0);
		db.close();
	});

	it("exchanges the code and stores the refresh token encrypted", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const cipher = new TokenCipher({ version: 1, material: testEncryptionKey() });
		const post = await makeApp(db, signer, { cipher });

		const response = await post({
			identityToken: await tokenFor(signer, { sub: "apple-sub-1" }),
			rawNonce: RAW_NONCE,
		});

		expect(response.status).toBe(200);
		// The code really went to Apple.
		expect(post.apple.requests[0]?.form.code).toBe(AUTHORIZATION_CODE);

		const identity = await findIdentity(db, "apple", "apple-sub-1");
		expect(await readRefreshToken(db, cipher, identity!.id)).toBe(
			"test-refresh-token",
		);
		// And the row holds ciphertext, not the token.
		const row = await db
			.prepare(`SELECT encrypted_refresh_token FROM provider_credentials`)
			.first<{ encrypted_refresh_token: string }>();
		expect(row?.encrypted_refresh_token).not.toContain("test-refresh-token");
		db.close();
	});

	it("issues no session when the exchange fails", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const post = await makeApp(db, signer, {
			appleResponder: () => appleErrorResponse("invalid_grant"),
		});

		const response = await post({
			identityToken: await tokenFor(signer),
			rawNonce: RAW_NONCE,
		});

		expect(response.status).toBe(401);
		expect(await db.count("sessions")).toBe(0);
		expect(await db.count("provider_credentials")).toBe(0);
		db.close();
	});

	it("reports an Apple outage as 503, not as a bad credential", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const post = await makeApp(db, signer, {
			appleResponder: () => new Response("", { status: 503 }),
		});

		const response = await post({
			identityToken: await tokenFor(signer),
			rawNonce: RAW_NONCE,
		});

		expect(response.status).toBe(503);
		const body = (await response.json()) as { error: { code: string } };
		expect(body.error.code).toBe("service_unavailable");
		db.close();
	});

	it("refuses when Apple's response names a different subject", async () => {
		// A victim's authorization code paired with the attacker's identity
		// token. Nothing is written and no session is issued.
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const idToken = await signer.sign({
			iss: "https://appleid.apple.com",
			aud: (await createTestAppleSigningKey()).config.clientId,
			sub: "999999.someone.else",
			iat: NOW - 10,
			exp: NOW + 600,
		});
		const post = await makeApp(db, signer, {
			appleResponder: () => appleTokenResponse({ id_token: idToken }),
		});

		const response = await post({
			identityToken: await tokenFor(signer, { sub: "apple-sub-1" }),
			rawNonce: RAW_NONCE,
		});

		expect(response.status).toBe(401);
		expect(await db.count("sessions")).toBe(0);
		expect(await db.count("provider_credentials")).toBe(0);
		db.close();
	});

	it("never issues a session without a stored credential", async () => {
		// The invariant, stated directly: across every request that reached a
		// 200, there is a credential row for the identity.
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const post = await makeApp(db, signer);

		await post({
			identityToken: await tokenFor(signer, { sub: "apple-sub-1" }, "n1"),
			rawNonce: "n1",
		});

		expect(await db.count("sessions")).toBe(await db.count("provider_credentials"));
		db.close();
	});

	it("re-signing in replaces the credential and does not duplicate the user", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const cipher = new TokenCipher({ version: 1, material: testEncryptionKey() });
		let issued = 0;
		const post = await makeApp(db, signer, {
			cipher,
			appleResponder: () => {
				issued += 1;
				return appleTokenResponse({ refresh_token: `refresh-${issued}` });
			},
		});

		for (const nonce of ["n1", "n2"]) {
			const response = await post({
				identityToken: await tokenFor(signer, { sub: "apple-sub-1" }, nonce),
				rawNonce: nonce,
			});
			expect(response.status).toBe(200);
		}

		// The authorization code is single-use, so each sign-in brings a new
		// one and a new refresh token replaces the old.
		expect(await db.count("users")).toBe(1);
		expect(await db.count("provider_credentials")).toBe(1);
		const identity = await findIdentity(db, "apple", "apple-sub-1");
		expect(await readRefreshToken(db, cipher, identity!.id)).toBe("refresh-2");
		db.close();
	});

	it("refuses to sign anyone in when Apple is not configured", async () => {
		// Not a degraded mode: without the client secret the code cannot be
		// exchanged, so the account could not be deleted properly.
		const db = await createTestDatabase();
		const signer = await createTestSigner();

		for (const overrides of [{ clientSecret: null }, { cipher: null }]) {
			const post = await makeApp(db, signer, overrides);
			const response = await post({
				identityToken: await tokenFor(signer),
				rawNonce: RAW_NONCE,
			});
			expect(response.status).toBe(503);
		}

		// And it refused before spending the nonce or touching the account.
		expect(await db.count("users")).toBe(0);
		expect(await db.count("auth_nonces")).toBe(0);
		db.close();
	});

	it("never returns or logs the code, the refresh token or the client secret", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const post = await makeApp(db, signer, {
			appleResponder: () => appleErrorResponse("invalid_grant"),
		});

		const lines: string[] = [];
		const originalWarn = console.warn;
		console.warn = (...args: unknown[]) => lines.push(args.join(" "));
		let text: string;
		try {
			text = await (
				await post({
					identityToken: await tokenFor(signer),
					rawNonce: RAW_NONCE,
				})
			).text();
		} finally {
			console.warn = originalWarn;
		}

		const logged = lines.join("\n");
		for (const secret of [
			AUTHORIZATION_CODE,
			"test-refresh-token",
			post.apple.requests[0]?.form.client_secret ?? "@@",
			post.key.config.privateKeyPem.slice(40, 80),
		]) {
			expect(text).not.toContain(secret);
			expect(logged).not.toContain(secret);
		}
		db.close();
	});
});
