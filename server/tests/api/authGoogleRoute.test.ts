import { Hono } from "hono";
import { describe, expect, it } from "vitest";
import { JwksFetchError, type JwksProvider } from "../../src/api/auth/jwks";
import { base64urlEncode } from "../../src/api/auth/jwt";
import { findIdentity, markUserDeleting } from "../../src/api/db/accounts";
import { findActiveSessionByToken } from "../../src/api/db/sessions";
import { makeGoogleAuthHandler } from "../../src/api/routes/authGoogle";
import type { ApiEnv } from "../../src/api/types";
import {
	TEST_GOOGLE_AUDIENCE,
	createTestSigner,
	googleClaims,
} from "./support/googleTokens";
import { type TestDatabase, createTestDatabase } from "./support/sqliteD1";

const NOW = 1_800_000_100;

async function makeApp(
	db: TestDatabase,
	signer: Awaited<ReturnType<typeof createTestSigner>>,
	overrides: { audience?: string; jwks?: JwksProvider } = {},
) {
	const app = new Hono<{ Bindings: ApiEnv }>();
	app.post(
		"/v1/auth/google",
		makeGoogleAuthHandler({
			jwks: overrides.jwks ?? signer.jwks,
			audience: overrides.audience ?? TEST_GOOGLE_AUDIENCE,
			now: () => NOW,
		}),
	);
	return (body: unknown) =>
		app.request(
			"/v1/auth/google",
			{
				method: "POST",
				headers: { "content-type": "application/json" },
				body: JSON.stringify(body),
			},
			{ DB: db, GOOGLE_AUDIENCE: TEST_GOOGLE_AUDIENCE } as unknown as ApiEnv,
		);
}

async function tokenFor(
	signer: Awaited<ReturnType<typeof createTestSigner>>,
	overrides: Record<string, unknown> = {},
) {
	return signer.sign(await googleClaims(overrides));
}

/** A token with literally these segments, for shapes a signer cannot make. */
function rawToken(header: string, payload: string): string {
	const encode = (json: string) =>
		base64urlEncode(new TextEncoder().encode(json));
	return `${encode(header)}.${encode(payload)}.c2ln`;
}

describe("POST /v1/auth/google", () => {
	it("creates an account and returns a usable session", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const post = await makeApp(db, signer);

		const response = await post({
			idToken: await tokenFor(signer, { sub: "google-sub-1" }),
			deviceName: "iPhone",
		});

		expect(response.status).toBe(200);
		const body = (await response.json()) as {
			sessionToken: string;
			expiresAt: number;
			user: { id: string; created: boolean };
		};
		expect(body.user.created).toBe(true);
		// 256 bits, base64url, unpadded.
		expect(body.sessionToken).toMatch(/^[A-Za-z0-9_-]{43}$/);
		// 60-day absolute expiry, no sliding extension.
		expect(body.expiresAt).toBe(NOW + 60 * 24 * 60 * 60);

		const session = await findActiveSessionByToken(db, body.sessionToken, NOW + 1);
		expect(session?.user_id).toBe(body.user.id);
		// The subject stored is Google's, from the signed token.
		const identity = await findIdentity(db, "google", "google-sub-1");
		expect(identity?.user_id).toBe(body.user.id);
		db.close();
	});

	it("stores only the hash of the session token, never the token", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const post = await makeApp(db, signer);

		const body = (await (await post({ idToken: await tokenFor(signer) })).json()) as {
			sessionToken: string;
		};

		const row = await db
			.prepare(`SELECT token_sha256 FROM sessions`)
			.first<{ token_sha256: string }>();
		expect(row?.token_sha256).toMatch(/^[0-9a-f]{64}$/);
		expect(row?.token_sha256).not.toBe(body.sessionToken);
		db.close();
	});

	it("signs a returning user into the same account", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const post = await makeApp(db, signer);

		const first = await post({ idToken: await tokenFor(signer, { sub: "g-1" }) });
		const second = await post({ idToken: await tokenFor(signer, { sub: "g-1" }) });

		const a = (await first.json()) as { user: { id: string; created: boolean } };
		const b = (await second.json()) as { user: { id: string; created: boolean } };
		expect(b.user.id).toBe(a.user.id);
		expect(b.user.created).toBe(false);
		expect(await db.count("users")).toBe(1);
		db.close();
	});

	it("does not merge two subjects that share an email", async () => {
		// An address is not proof of ownership. Merging on one would let
		// whoever controls a mailbox walk into an existing account.
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const post = await makeApp(db, signer);
		const email = "same-person@example.com";

		const first = await post({
			idToken: await tokenFor(signer, { sub: "g-old", email, email_verified: true }),
		});
		const second = await post({
			idToken: await tokenFor(signer, { sub: "g-new", email, email_verified: true }),
		});

		const a = (await first.json()) as { user: { id: string } };
		const b = (await second.json()) as { user: { id: string } };
		expect(b.user.id).not.toBe(a.user.id);
		expect(await db.count("users")).toBe(2);
		db.close();
	});

	it("does not merge a Google identity into an Apple account with the same email", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const post = await makeApp(db, signer);
		const email = "shared@example.com";

		// An existing Apple account for the same person.
		const { findOrCreateAccountForIdentity } = await import(
			"../../src/api/db/accounts"
		);
		const apple = await findOrCreateAccountForIdentity(
			db,
			{ provider: "apple", subject: "apple-sub", email, emailVerified: true },
			NOW,
		);

		const response = await post({
			idToken: await tokenFor(signer, { sub: "g-1", email, email_verified: true }),
		});
		const body = (await response.json()) as { user: { id: string } };

		expect(body.user.id).not.toBe(apple.user.id);
		expect(await db.count("users")).toBe(2);
		db.close();
	});

	it("refuses an account that is being deleted", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const post = await makeApp(db, signer);

		const first = (await (
			await post({ idToken: await tokenFor(signer, { sub: "g-1" }) })
		).json()) as { sessionToken: string; user: { id: string } };
		await markUserDeleting(db, first.user.id, NOW);

		const response = await post({ idToken: await tokenFor(signer, { sub: "g-1" }) });

		// A perfectly valid token, refused because the account is going away —
		// and answered exactly like a bad credential, so nothing leaks.
		expect(response.status).toBe(401);
		const rejected = (await response.json()) as { error: { code: string } };
		expect(rejected.error.code).toBe("invalid_credentials");
		// No second session was issued, and the first one stopped working.
		expect(await db.count("sessions")).toBe(1);
		expect(
			await findActiveSessionByToken(db, first.sessionToken, NOW + 1),
		).toBeNull();
		db.close();
	});

	it("answers 401 identically for every kind of bad credential", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const impostor = await createTestSigner(signer.kid);
		const post = await makeApp(db, signer);

		const cases = [
			// Wrong signer.
			{ idToken: await impostor.sign(await googleClaims()) },
			// Wrong audience.
			{ idToken: await tokenFor(signer, { aud: "999.apps.googleusercontent.com" }) },
			// Wrong issuer.
			{ idToken: await tokenFor(signer, { iss: "https://appleid.apple.com" }) },
			// Expired.
			{ idToken: await tokenFor(signer, { exp: NOW - 3600 }) },
			// No sub.
			{ idToken: await tokenFor(signer, { sub: undefined }) },
			// Unsigned.
			{ idToken: await signer.sign(await googleClaims(), { alg: "none" }) },
			// Unknown kid.
			{ idToken: await (await createTestSigner("rotated-away")).sign(await googleClaims()) },
			// Payload is not a JSON object — must be a 401, not a crash.
			{ idToken: rawToken('{"alg":"RS256","kid":"k1"}', "null") },
			{ idToken: rawToken('{"alg":"RS256","kid":"k1"}', '["iss"]') },
			{ idToken: rawToken('{"alg":"RS256","kid":"k1"}', '"a-string"') },
			{ idToken: rawToken('{"alg":"RS256","kid":"k1"}', "42") },
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

	it("never echoes the token, subject or email back to the client", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const post = await makeApp(db, signer);
		const idToken = await tokenFor(signer, {
			sub: "google-secret-sub",
			email: "secret@example.com",
			aud: "wrong.apps.googleusercontent.com",
		});

		const text = await (await post({ idToken })).text();

		expect(text).not.toContain(idToken);
		expect(text).not.toContain("google-secret-sub");
		expect(text).not.toContain("secret@example.com");
		db.close();
	});

	it("does not log the token, subject or email on rejection", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const post = await makeApp(db, signer);
		const idToken = await tokenFor(signer, {
			sub: "google-secret-sub",
			email: "secret@example.com",
			aud: "wrong.apps.googleusercontent.com",
		});

		const lines: string[] = [];
		const original = console.warn;
		console.warn = (...args: unknown[]) => lines.push(args.join(" "));
		try {
			await post({ idToken });
		} finally {
			console.warn = original;
		}

		expect(lines.length).toBeGreaterThan(0);
		const logged = lines.join("\n");
		expect(logged).not.toContain(idToken);
		expect(logged).not.toContain("google-secret-sub");
		expect(logged).not.toContain("secret@example.com");
		db.close();
	});

	it("rejects a malformed body with 400 and creates nothing", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const post = await makeApp(db, signer);

		// `userID` instead of a token: the client does not get to name itself.
		const response = await post({ userID: "112233", email: "a@example.com" });

		expect(response.status).toBe(400);
		expect(await db.count("users")).toBe(0);
		db.close();
	});

	it("refuses to sign anyone in when the audience is unconfigured", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const post = await makeApp(db, signer, { audience: "" });

		const response = await post({ idToken: await tokenFor(signer) });

		expect(response.status).toBe(401);
		expect(await db.count("users")).toBe(0);
		db.close();
	});

	it("reports 503, not a bad credential, when Google's keys are unreachable", async () => {
		const db = await createTestDatabase();
		const signer = await createTestSigner();
		const failing: JwksProvider = {
			keyForId: async () => {
				throw new JwksFetchError("request failed");
			},
			invalidate: () => {},
		};
		const post = await makeApp(db, signer, { jwks: failing });

		const response = await post({ idToken: await tokenFor(signer) });

		expect(response.status).toBe(503);
		const json = (await response.json()) as { error: { code: string } };
		expect(json.error.code).toBe("service_unavailable");
		db.close();
	});
});
