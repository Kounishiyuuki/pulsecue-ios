import { describe, expect, it } from "vitest";
import {
	GOOGLE_CLOCK_SKEW_SECONDS,
	GOOGLE_ISSUERS,
	GoogleTokenInvalidError,
	verifyGoogleIdToken,
} from "../../src/api/auth/google";
import {
	JwksFetchError,
	type JwksProvider,
	StaticJwksProvider,
} from "../../src/api/auth/jwks";
import { JwtMalformedError, JwtSignatureError } from "../../src/api/auth/jwt";
import {
	TEST_GOOGLE_AUDIENCE,
	createTestSigner,
	googleClaims,
} from "./support/googleTokens";

const NOW = 1_800_000_100;

async function verifyWith(
	signer: Awaited<ReturnType<typeof createTestSigner>>,
	claimOverrides: Record<string, unknown> = {},
	options: { audience?: string; now?: number; jwks?: JwksProvider } = {},
) {
	const token = await signer.sign(await googleClaims(claimOverrides));
	return verifyGoogleIdToken({
		idToken: token,
		audience: options.audience ?? TEST_GOOGLE_AUDIENCE,
		jwks: options.jwks ?? signer.jwks,
		now: options.now ?? NOW,
	});
}

describe("a well-formed Google token", () => {
	it("yields the subject Google signed, not one the client supplied", async () => {
		const signer = await createTestSigner();
		const identity = await verifyWith(signer, {
			sub: "112233445566778899000",
			email: "user@example.com",
			email_verified: true,
			// A client-controlled field of the same name must not be trusted,
			// and there is nowhere for it to enter: only `sub` is read.
			user_id: "attacker-supplied",
		});

		expect(identity.subject).toBe("112233445566778899000");
		expect(identity.email).toBe("user@example.com");
		expect(identity.emailVerified).toBe(true);
	});

	it("accepts Google's other documented issuer spelling", async () => {
		const signer = await createTestSigner();
		const identity = await verifyWith(signer, { iss: GOOGLE_ISSUERS[1] });
		expect(identity.subject).toBeTruthy();
	});

	it("treats an absent email as absent rather than empty", async () => {
		const signer = await createTestSigner();
		const identity = await verifyWith(signer);
		expect(identity.email).toBeNull();
		expect(identity.emailVerified).toBe(false);
	});

	it("accepts an aud array containing this client", async () => {
		const signer = await createTestSigner();
		const identity = await verifyWith(signer, {
			aud: ["someone.else.apps.googleusercontent.com", TEST_GOOGLE_AUDIENCE],
		});
		expect(identity.subject).toBeTruthy();
	});
});

describe("signature", () => {
	it("rejects a token signed by a different key", async () => {
		const real = await createTestSigner();
		// Same kid, different keypair: the only thing that can catch this is
		// the signature check itself.
		const impostor = await createTestSigner(real.kid);
		const forged = await impostor.sign(await googleClaims());

		await expect(
			verifyGoogleIdToken({
				idToken: forged,
				audience: TEST_GOOGLE_AUDIENCE,
				jwks: real.jwks,
				now: NOW,
			}),
		).rejects.toBeInstanceOf(JwtSignatureError);
	});

	it("rejects an unsigned alg:none token", async () => {
		const signer = await createTestSigner();
		const token = await signer.sign(await googleClaims(), { alg: "none" });

		await expect(
			verifyGoogleIdToken({
				idToken: token,
				audience: TEST_GOOGLE_AUDIENCE,
				jwks: signer.jwks,
				now: NOW,
			}),
		).rejects.toBeInstanceOf(JwtSignatureError);
	});

	it("rejects a token whose kid is not published", async () => {
		const signer = await createTestSigner();
		await expect(
			verifyWith(signer, {}, { jwks: new StaticJwksProvider([]) }),
		).rejects.toBeInstanceOf(GoogleTokenInvalidError);
	});

	it("rejects a token with no kid at all", async () => {
		const signer = await createTestSigner();
		const token = await signer.sign(await googleClaims(), { kid: undefined });

		await expect(
			verifyGoogleIdToken({
				idToken: token,
				audience: TEST_GOOGLE_AUDIENCE,
				jwks: signer.jwks,
				now: NOW,
			}),
		).rejects.toBeInstanceOf(GoogleTokenInvalidError);
	});

	it("rejects a token that is not three segments", async () => {
		const signer = await createTestSigner();
		await expect(
			verifyGoogleIdToken({
				idToken: "not.a-token",
				audience: TEST_GOOGLE_AUDIENCE,
				jwks: signer.jwks,
				now: NOW,
			}),
		).rejects.toBeInstanceOf(JwtMalformedError);
	});

	it("surfaces a key-service outage as itself, not as a bad credential", async () => {
		// One is a 503, the other a 401. Collapsing them would tell users
		// their account is broken during an incident.
		const signer = await createTestSigner();
		const failing: JwksProvider = {
			keyForId: async () => {
				throw new JwksFetchError("request failed");
			},
			invalidate: () => {},
		};

		await expect(verifyWith(signer, {}, { jwks: failing })).rejects.toBeInstanceOf(
			JwksFetchError,
		);
	});
});

describe("claims", () => {
	it("rejects another issuer", async () => {
		const signer = await createTestSigner();
		await expect(
			verifyWith(signer, { iss: "https://appleid.apple.com" }),
		).rejects.toBeInstanceOf(GoogleTokenInvalidError);
	});

	it("rejects a lookalike issuer", async () => {
		const signer = await createTestSigner();
		await expect(
			verifyWith(signer, { iss: "https://accounts.google.com.evil.test" }),
		).rejects.toBeInstanceOf(GoogleTokenInvalidError);
	});

	it("rejects a token minted for another Google client", async () => {
		// Without this, an ID token from any Google app — including one the
		// attacker registered — would sign its holder in here.
		const signer = await createTestSigner();
		await expect(
			verifyWith(signer, { aud: "999.apps.googleusercontent.com" }),
		).rejects.toBeInstanceOf(GoogleTokenInvalidError);
	});

	it("refuses to run when the audience is unconfigured", async () => {
		// A missing config must never degrade into "accept anything".
		const signer = await createTestSigner();
		await expect(verifyWith(signer, {}, { audience: "" })).rejects.toBeInstanceOf(
			GoogleTokenInvalidError,
		);
	});

	it("rejects an expired token but allows a little clock skew", async () => {
		const signer = await createTestSigner();
		const expiry = 1_800_000_600;

		await expect(
			verifyWith(signer, { exp: expiry }, { now: expiry + GOOGLE_CLOCK_SKEW_SECONDS }),
		).rejects.toBeInstanceOf(GoogleTokenInvalidError);

		const stillValid = await verifyWith(
			signer,
			{ exp: expiry },
			{ now: expiry + GOOGLE_CLOCK_SKEW_SECONDS - 1 },
		);
		expect(stillValid.subject).toBeTruthy();
	});

	it("rejects a token with no exp", async () => {
		const signer = await createTestSigner();
		await expect(verifyWith(signer, { exp: undefined })).rejects.toBeInstanceOf(
			GoogleTokenInvalidError,
		);
	});

	it("rejects a token issued too far in the future", async () => {
		const signer = await createTestSigner();
		await expect(verifyWith(signer, { iat: NOW + 3600 })).rejects.toBeInstanceOf(
			GoogleTokenInvalidError,
		);
	});

	it("requires iat, and requires it to be a number", async () => {
		const signer = await createTestSigner();
		await expect(verifyWith(signer, { iat: undefined })).rejects.toBeInstanceOf(
			GoogleTokenInvalidError,
		);
		await expect(verifyWith(signer, { iat: "1800000000" })).rejects.toBeInstanceOf(
			GoogleTokenInvalidError,
		);
	});

	it("rejects a missing or non-string sub", async () => {
		const signer = await createTestSigner();
		await expect(verifyWith(signer, { sub: undefined })).rejects.toBeInstanceOf(
			GoogleTokenInvalidError,
		);
		await expect(verifyWith(signer, { sub: "" })).rejects.toBeInstanceOf(
			GoogleTokenInvalidError,
		);
		await expect(verifyWith(signer, { sub: 12345 })).rejects.toBeInstanceOf(
			GoogleTokenInvalidError,
		);
	});
});
