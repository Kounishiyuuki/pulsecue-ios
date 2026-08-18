/**
 * What happens between "Apple issued a refresh token" and "we stored it".
 *
 * That gap is the dangerous part of the whole flow. Once Apple mints a
 * refresh token, a live grant exists that only this one in-flight request
 * knows about. Every failure from that instant onwards has exactly two
 * acceptable endings:
 *
 *   the token is durably stored, or
 *   the token is handed back to Apple.
 *
 * Anything else leaves a credential that cannot be revoked at account
 * deletion — Apple's own requirement — and that no table can even show you.
 *
 * The second thing these tests pin is that **no account row is written until
 * the subject binding holds**. An exchange whose `id_token` names a different
 * person must not leave a PulseCue user behind.
 */

import { Hono } from "hono";
import { describe, expect, it } from "vitest";
import { TokenCipher } from "../../src/api/crypto/tokenCipher";
import { findIdentity, findOrCreateAccountForIdentity } from "../../src/api/db/accounts";
import { findCredentialForIdentity } from "../../src/api/db/providerCredentials";
import { makeAppleAuthHandler } from "../../src/api/routes/authApple";
import type { ApiEnv } from "../../src/api/types";
import {
	TEST_AUDIENCE,
	appleClaims,
	createTestSigner,
	hashedNonce,
} from "./support/appleTokens";
import {
	appleTokenResponse,
	appleTokenResponseFor,
	createTestAppleSigningKey,
	fakeAppleEndpoint,
	signExchangeIdToken,
	testEncryptionKey,
} from "./support/appleProduction";
import { type TestDatabase, createTestDatabase } from "./support/sqliteD1";

const NOW = 1_800_000_100;
const RAW_NONCE = "compensation-nonce";
const SUBJECT = "apple-sub-1";

interface SignInResult {
	response: Response;
	/** Every request the fake Apple received. */
	requests: { url: string; form: Record<string, string> }[];
	revokes: { url: string; form: Record<string, string> }[];
	logs: string;
}

/**
 * Runs a full sign-in against a fake Apple whose `/auth/token` response the
 * test controls, capturing the revoke calls and the logs.
 */
async function signIn(
	db: TestDatabase,
	options: {
		tokenResponse?: (context: {
			signer: Awaited<ReturnType<typeof createTestSigner>>;
			key: Awaited<ReturnType<typeof createTestAppleSigningKey>>;
		}) => Response | Promise<Response>;
		revokeResponse?: () => Response;
		subject?: string;
		nonce?: string;
	} = {},
): Promise<SignInResult> {
	const signer = await createTestSigner();
	const key = await createTestAppleSigningKey();
	const subject = options.subject ?? SUBJECT;
	const nonce = options.nonce ?? RAW_NONCE;

	const endpoint = fakeAppleEndpoint(async (request) => {
		if (request.url.endsWith("/auth/revoke")) {
			return options.revokeResponse?.() ?? new Response("", { status: 200 });
		}
		return (
			options.tokenResponse ??
			(({ signer: s, key: k }) =>
				appleTokenResponseFor(s, {
					sub: subject,
					audience: k.config.clientId,
					now: NOW,
				}))
		)({ signer, key });
	});

	const app = new Hono<{ Bindings: ApiEnv }>();
	app.post(
		"/v1/auth/apple",
		makeAppleAuthHandler({
			jwks: signer.jwks,
			audience: TEST_AUDIENCE,
			clientSecret: key.config,
			cipher: new TokenCipher({ version: 1, material: testEncryptionKey() }),
			fetchImpl: endpoint.fetchImpl,
			now: () => NOW,
		}),
	);

	const identityToken = await signer.sign(
		await appleClaims({ sub: subject, nonce: await hashedNonce(nonce) }),
	);

	const lines: string[] = [];
	const originalWarn = console.warn;
	const originalError = console.error;
	console.warn = (...args: unknown[]) => lines.push(args.join(" "));
	console.error = (...args: unknown[]) => lines.push(args.join(" "));
	let response: Response;
	try {
		response = await app.request(
			"/v1/auth/apple",
			{
				method: "POST",
				headers: { "content-type": "application/json" },
				body: JSON.stringify({
					identityToken,
					authorizationCode: "test-authorization-code",
					rawNonce: nonce,
				}),
			},
			{ DB: db, APPLE_AUDIENCE: TEST_AUDIENCE } as unknown as ApiEnv,
		);
	} finally {
		console.warn = originalWarn;
		console.error = originalError;
	}

	return {
		response,
		requests: endpoint.requests,
		revokes: endpoint.requests.filter((r) => r.url.endsWith("/auth/revoke")),
		logs: lines.join("\n"),
	};
}

/** Every table a sign-in could possibly have written to. */
async function writtenRowCounts(db: TestDatabase) {
	return {
		users: await db.count("users"),
		identities: await db.count("auth_identities"),
		profiles: await db.count("user_profiles"),
		credentials: await db.count("provider_credentials"),
		sessions: await db.count("sessions"),
	};
}

const NOTHING_WRITTEN = {
	users: 0,
	identities: 0,
	profiles: 0,
	credentials: 0,
	sessions: 0,
};

// MARK: - Validation failures after a token was issued

describe("a refresh token is revoked when the response fails validation", () => {
	/**
	 * Each case: Apple returns 200 with a usable `refresh_token`, and
	 * something about the rest of the response is wrong.
	 */
	const cases: Array<{
		name: string;
		body: (context: {
			signer: Awaited<ReturnType<typeof createTestSigner>>;
			key: Awaited<ReturnType<typeof createTestAppleSigningKey>>;
		}) => Response | Promise<Response>;
	}> = [
		{ name: "id_token missing", body: () => appleTokenResponse() },
		{
			name: "id_token empty",
			body: () => appleTokenResponse({ id_token: "" }),
		},
		{
			name: "id_token malformed",
			body: () => appleTokenResponse({ id_token: "not.a.jwt" }),
		},
		{
			name: "id_token forged",
			body: async ({ signer, key }) => {
				const impostor = await createTestSigner(signer.kid);
				return appleTokenResponse({
					id_token: await signExchangeIdToken(impostor, {
						sub: SUBJECT,
						audience: key.config.clientId,
						now: NOW,
					}),
				});
			},
		},
		{
			name: "wrong issuer",
			body: ({ signer, key }) =>
				appleTokenResponseFor(signer, {
					sub: SUBJECT,
					audience: key.config.clientId,
					now: NOW,
					idTokenOverrides: { iss: "https://accounts.google.com" },
				}),
		},
		{
			name: "wrong audience",
			body: ({ signer }) =>
				appleTokenResponseFor(signer, {
					sub: SUBJECT,
					audience: "com.someone.else",
					now: NOW,
				}),
		},
		{
			name: "expired",
			body: ({ signer, key }) =>
				appleTokenResponseFor(signer, {
					sub: SUBJECT,
					audience: key.config.clientId,
					now: NOW,
					idTokenOverrides: { exp: NOW - 3600 },
				}),
		},
		{
			name: "bad iat",
			body: ({ signer, key }) =>
				appleTokenResponseFor(signer, {
					sub: SUBJECT,
					audience: key.config.clientId,
					now: NOW,
					idTokenOverrides: { iat: NOW + 3600 },
				}),
		},
		{
			name: "missing sub",
			body: ({ signer, key }) =>
				appleTokenResponseFor(signer, {
					sub: SUBJECT,
					audience: key.config.clientId,
					now: NOW,
					idTokenOverrides: { sub: undefined },
				}),
		},
		{
			name: "empty sub",
			body: ({ signer, key }) =>
				appleTokenResponseFor(signer, {
					sub: SUBJECT,
					audience: key.config.clientId,
					now: NOW,
					idTokenOverrides: { sub: "" },
				}),
		},
		{
			name: "subject mismatch",
			body: ({ signer, key }) =>
				appleTokenResponseFor(signer, {
					sub: "999999.someone.else",
					audience: key.config.clientId,
					now: NOW,
				}),
		},
		{
			name: "unexpected token_type",
			body: ({ signer, key }) =>
				appleTokenResponseFor(signer, {
					sub: SUBJECT,
					audience: key.config.clientId,
					now: NOW,
					bodyOverrides: { token_type: "mac" },
				}),
		},
	];

	for (const testCase of cases) {
		it(`revokes and writes nothing — ${testCase.name}`, async () => {
			const db = await createTestDatabase();

			const result = await signIn(db, { tokenResponse: testCase.body });

			// The token went back to Apple…
			expect(result.revokes, "compensating revoke").toHaveLength(1);
			expect(result.revokes[0]?.form.token).toBe("test-refresh-token");
			expect(result.revokes[0]?.form.token_type_hint).toBe("refresh_token");
			// …no session was issued…
			expect(result.response.status).not.toBe(200);
			expect(await result.response.text()).not.toContain("sessionToken");
			// …and not a single row was written anywhere.
			expect(await writtenRowCounts(db)).toEqual(NOTHING_WRITTEN);
			db.close();
		});
	}

	it("does not revoke when Apple issued no refresh token at all", async () => {
		// Nothing to compensate: there is no token. Calling revoke here would
		// be a pointless outbound request on every malformed response.
		const db = await createTestDatabase();

		const result = await signIn(db, {
			tokenResponse: () => appleTokenResponse({ refresh_token: undefined }),
		});

		expect(result.revokes).toHaveLength(0);
		expect(result.response.status).not.toBe(200);
		expect(await writtenRowCounts(db)).toEqual(NOTHING_WRITTEN);
		db.close();
	});

	it("does not revoke when the token endpoint itself failed", async () => {
		const db = await createTestDatabase();

		const result = await signIn(db, {
			tokenResponse: () =>
				new Response(JSON.stringify({ error: "invalid_grant" }), { status: 400 }),
		});

		expect(result.revokes).toHaveLength(0);
		expect(result.response.status).toBe(401);
		expect(await writtenRowCounts(db)).toEqual(NOTHING_WRITTEN);
		db.close();
	});
});

// MARK: - No account mutation before the binding holds

describe("no account is created or touched until the subjects agree", () => {
	it("creates no user for a subject mismatch", async () => {
		// The regression: resolving the account before the exchange meant a
		// mismatched exchange still left a PulseCue user and auth identity
		// behind. Move account resolution back above the exchange and this
		// fails.
		const db = await createTestDatabase();

		const result = await signIn(db, {
			tokenResponse: ({ signer, key }) =>
				appleTokenResponseFor(signer, {
					sub: "999999.someone.else",
					audience: key.config.clientId,
					now: NOW,
				}),
		});

		expect(result.response.status).toBe(401);
		expect(await writtenRowCounts(db)).toEqual(NOTHING_WRITTEN);
		expect(await findIdentity(db, "apple", SUBJECT)).toBeNull();
		db.close();
	});

	it("leaves an existing account completely untouched on a mismatch", async () => {
		const db = await createTestDatabase();
		const existing = await findOrCreateAccountForIdentity(
			db,
			{ provider: "apple", subject: SUBJECT, email: "user@example.com" },
			NOW - 5_000,
		);
		const before = await db
			.prepare(`SELECT * FROM auth_identities WHERE id = ?`)
			.bind(existing.identity.id)
			.first<Record<string, unknown>>();

		const result = await signIn(db, {
			tokenResponse: ({ signer, key }) =>
				appleTokenResponseFor(signer, {
					sub: "999999.someone.else",
					audience: key.config.clientId,
					now: NOW,
				}),
		});

		expect(result.response.status).toBe(401);
		// No new rows…
		expect(await db.count("users")).toBe(1);
		expect(await db.count("sessions")).toBe(0);
		expect(await db.count("provider_credentials")).toBe(0);
		// …and the identity row is byte-identical, including last_seen_at.
		const after = await db
			.prepare(`SELECT * FROM auth_identities WHERE id = ?`)
			.bind(existing.identity.id)
			.first<Record<string, unknown>>();
		expect(after).toEqual(before);
		db.close();
	});

	it("does not replace an existing credential on a mismatch", async () => {
		const db = await createTestDatabase();
		const cipher = new TokenCipher({ version: 1, material: testEncryptionKey() });
		const existing = await findOrCreateAccountForIdentity(
			db,
			{ provider: "apple", subject: SUBJECT },
			NOW - 5_000,
		);
		const { prepareCredentialUpsert } = await import(
			"../../src/api/db/providerCredentials"
		);
		await (
			await prepareCredentialUpsert(
				db,
				cipher,
				{
					authIdentityId: existing.identity.id,
					provider: "apple",
					refreshToken: "original-refresh-token",
				},
				NOW - 5_000,
			)
		).run();
		const before = await findCredentialForIdentity(db, existing.identity.id);

		await signIn(db, {
			tokenResponse: ({ signer, key }) =>
				appleTokenResponseFor(signer, {
					sub: "999999.someone.else",
					audience: key.config.clientId,
					now: NOW,
				}),
		});

		expect(await findCredentialForIdentity(db, existing.identity.id)).toEqual(
			before,
		);
		db.close();
	});
});

// MARK: - Compensation outcomes

describe("the outcome of the compensating revoke", () => {
	const mismatch =
		({
			signer,
			key,
		}: {
			signer: Awaited<ReturnType<typeof createTestSigner>>;
			key: Awaited<ReturnType<typeof createTestAppleSigningKey>>;
		}) =>
			appleTokenResponseFor(signer, {
				sub: "999999.someone.else",
				audience: key.config.clientId,
				now: NOW,
			});

	it("never turns a failed authentication into a success", async () => {
		// Whatever the compensation did, the original request failed.
		for (const revokeResponse of [
			() => new Response("", { status: 200 }),
			() => new Response(JSON.stringify({ error: "invalid_grant" }), { status: 400 }),
			() => new Response("", { status: 500 }),
			() => new Response("", { status: 503 }),
		]) {
			const db = await createTestDatabase();
			const result = await signIn(db, {
				tokenResponse: mismatch,
				revokeResponse,
			});

			expect(result.response.status).not.toBe(200);
			expect(await result.response.text()).not.toContain("sessionToken");
			expect(await writtenRowCounts(db)).toEqual(NOTHING_WRITTEN);
			db.close();
		}
	});

	it("records a fixed reason code when the revoke did not confirm", async () => {
		// A live Apple grant may still exist that nothing here tracks. That is
		// the one condition an operator has to be able to find later.
		const db = await createTestDatabase();

		const result = await signIn(db, {
			tokenResponse: mismatch,
			revokeResponse: () => new Response("", { status: 500 }),
		});

		expect(result.logs).toContain("apple_auth_compensation_revoke_failed");
		db.close();
	});

	it("does not claim a failure when the revoke confirmed", async () => {
		const db = await createTestDatabase();

		const result = await signIn(db, {
			tokenResponse: mismatch,
			revokeResponse: () => new Response("", { status: 200 }),
		});

		expect(result.logs).not.toContain("apple_auth_compensation_revoke_failed");
		db.close();
	});

	it("treats a 4xx revoke as unconfirmed, never as revoked", async () => {
		const db = await createTestDatabase();

		const result = await signIn(db, {
			tokenResponse: mismatch,
			revokeResponse: () =>
				new Response(JSON.stringify({ error: "invalid_grant" }), { status: 400 }),
		});

		expect(result.logs).toContain("apple_auth_compensation_revoke_failed");
		db.close();
	});

	it("leaks nothing in the response or the logs, even when compensation fails", async () => {
		const db = await createTestDatabase();

		const result = await signIn(db, {
			subject: "000123.secret.subject",
			tokenResponse: mismatch,
			revokeResponse: () => new Response("", { status: 500 }),
		});
		const text = await result.response.text();

		for (const secret of [
			"test-refresh-token",
			"test-authorization-code",
			"000123.secret.subject",
			"999999.someone.else",
			"test-access-token",
		]) {
			expect(text, `response: ${secret}`).not.toContain(secret);
			expect(result.logs, `log: ${secret}`).not.toContain(secret);
		}
		db.close();
	});
});
