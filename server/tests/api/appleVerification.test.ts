import { describe, expect, it } from "vitest";
import {
	APPLE_CLOCK_SKEW_SECONDS,
	AppleTokenInvalidError,
	verifyAppleIdentityToken,
} from "../../src/api/auth/apple";
import { StaticJwksProvider } from "../../src/api/auth/jwks";
import { JwtMalformedError, JwtSignatureError } from "../../src/api/auth/jwt";
import {
	TEST_AUDIENCE,
	appleClaims,
	createTestSigner,
	hashedNonce,
} from "./support/appleTokens";

const RAW_NONCE = "raw-nonce-value";
const NOW = 1_800_000_100;

async function verifyWith(
	signer: Awaited<ReturnType<typeof createTestSigner>>,
	claimOverrides: Record<string, unknown> = {},
	options: { rawNonce?: string; audience?: string; now?: number } = {},
) {
	const claims = await appleClaims({
		nonce: await hashedNonce(RAW_NONCE),
		...claimOverrides,
	});
	const token = await signer.sign(claims);
	return verifyAppleIdentityToken({
		identityToken: token,
		rawNonce: options.rawNonce ?? RAW_NONCE,
		audience: options.audience ?? TEST_AUDIENCE,
		jwks: signer.jwks,
		now: options.now ?? NOW,
	});
}

describe("a well-formed Apple token", () => {
	it("yields the subject Apple signed, not one the client supplied", async () => {
		const signer = await createTestSigner();
		const identity = await verifyWith(signer, {
			sub: "000123.trusted.999",
			email: "user@privaterelay.appleid.com",
			email_verified: "true",
		});

		expect(identity.subject).toBe("000123.trusted.999");
		expect(identity.email).toBe("user@privaterelay.appleid.com");
		expect(identity.emailVerified).toBe(true);
		expect(identity.nonceHash).toBe(await hashedNonce(RAW_NONCE));
	});

	it("accepts email_verified as a boolean too", async () => {
		const signer = await createTestSigner();
		const identity = await verifyWith(signer, { email_verified: true });
		expect(identity.emailVerified).toBe(true);
	});

	it("treats an absent email as absent rather than empty", async () => {
		const signer = await createTestSigner();
		const identity = await verifyWith(signer);
		expect(identity.email).toBeNull();
		expect(identity.emailVerified).toBe(false);
	});

	it("accepts an aud array containing this app", async () => {
		const signer = await createTestSigner();
		const identity = await verifyWith(signer, {
			aud: ["someone.else", TEST_AUDIENCE],
		});
		expect(identity.subject).toBeTruthy();
	});
});

describe("signature", () => {
	it("rejects a token signed by a different key", async () => {
		const real = await createTestSigner();
		const impostor = await createTestSigner(real.kid);
		const claims = await appleClaims({ nonce: await hashedNonce(RAW_NONCE) });
		const forged = await impostor.sign(claims);

		await expect(
			verifyAppleIdentityToken({
				identityToken: forged,
				rawNonce: RAW_NONCE,
				audience: TEST_AUDIENCE,
				// Published key set is the real one; the token is not.
				jwks: real.jwks,
				now: NOW,
			}),
		).rejects.toBeInstanceOf(JwtSignatureError);
	});

	it("rejects an unsigned alg:none token", async () => {
		const signer = await createTestSigner();
		const claims = await appleClaims({ nonce: await hashedNonce(RAW_NONCE) });
		const token = await signer.sign(claims, { alg: "none" });

		await expect(
			verifyAppleIdentityToken({
				identityToken: token,
				rawNonce: RAW_NONCE,
				audience: TEST_AUDIENCE,
				jwks: signer.jwks,
				now: NOW,
			}),
		).rejects.toBeInstanceOf(JwtSignatureError);
	});

	it("rejects a token whose kid is not published", async () => {
		const signer = await createTestSigner();
		const empty = new StaticJwksProvider([]);
		const claims = await appleClaims({ nonce: await hashedNonce(RAW_NONCE) });
		const token = await signer.sign(claims);

		await expect(
			verifyAppleIdentityToken({
				identityToken: token,
				rawNonce: RAW_NONCE,
				audience: TEST_AUDIENCE,
				jwks: empty,
				now: NOW,
			}),
		).rejects.toBeInstanceOf(AppleTokenInvalidError);
	});

	it("rejects a token with no kid at all", async () => {
		const signer = await createTestSigner();
		const claims = await appleClaims({ nonce: await hashedNonce(RAW_NONCE) });
		const token = await signer.sign(claims, { kid: undefined });

		await expect(
			verifyAppleIdentityToken({
				identityToken: token,
				rawNonce: RAW_NONCE,
				audience: TEST_AUDIENCE,
				jwks: signer.jwks,
				now: NOW,
			}),
		).rejects.toBeInstanceOf(AppleTokenInvalidError);
	});

	it("rejects a token that is not three segments", async () => {
		const signer = await createTestSigner();
		await expect(
			verifyAppleIdentityToken({
				identityToken: "not.a-token",
				rawNonce: RAW_NONCE,
				audience: TEST_AUDIENCE,
				jwks: signer.jwks,
				now: NOW,
			}),
		).rejects.toBeInstanceOf(JwtMalformedError);
	});
});

describe("claims", () => {
	it("rejects another issuer", async () => {
		const signer = await createTestSigner();
		await expect(
			verifyWith(signer, { iss: "https://accounts.google.com" }),
		).rejects.toBeInstanceOf(AppleTokenInvalidError);
	});

	it("rejects a token minted for another app", async () => {
		// Without this, any Apple client's token would sign a user in here.
		const signer = await createTestSigner();
		await expect(
			verifyWith(signer, { aud: "com.someone.else" }),
		).rejects.toBeInstanceOf(AppleTokenInvalidError);
	});

	it("refuses to run when the audience is unconfigured", async () => {
		// A missing config must never degrade into "accept anything".
		const signer = await createTestSigner();
		await expect(verifyWith(signer, {}, { audience: "" })).rejects.toBeInstanceOf(
			AppleTokenInvalidError,
		);
	});

	it("rejects an expired token but allows a little clock skew", async () => {
		const signer = await createTestSigner();
		const expiry = 1_800_000_600;

		await expect(
			verifyWith(signer, { exp: expiry }, { now: expiry + APPLE_CLOCK_SKEW_SECONDS }),
		).rejects.toBeInstanceOf(AppleTokenInvalidError);

		const stillValid = await verifyWith(
			signer,
			{ exp: expiry },
			{ now: expiry + APPLE_CLOCK_SKEW_SECONDS - 1 },
		);
		expect(stillValid.subject).toBeTruthy();
	});

	it("rejects a token issued too far in the future", async () => {
		const signer = await createTestSigner();
		await expect(
			verifyWith(signer, { iat: NOW + 3600 }),
		).rejects.toBeInstanceOf(AppleTokenInvalidError);
	});

	it("rejects a token with no sub", async () => {
		const signer = await createTestSigner();
		await expect(verifyWith(signer, { sub: undefined })).rejects.toBeInstanceOf(
			AppleTokenInvalidError,
		);
	});
});

describe("nonce binding", () => {
	it("rejects a nonce that does not hash to the claim", async () => {
		const signer = await createTestSigner();
		await expect(
			verifyWith(signer, {}, { rawNonce: "some-other-nonce" }),
		).rejects.toBeInstanceOf(AppleTokenInvalidError);
	});

	it("rejects a token carrying no nonce", async () => {
		const signer = await createTestSigner();
		await expect(verifyWith(signer, { nonce: undefined })).rejects.toBeInstanceOf(
			AppleTokenInvalidError,
		);
	});

	it("rejects a request that omits the raw nonce", async () => {
		const signer = await createTestSigner();
		await expect(verifyWith(signer, {}, { rawNonce: "" })).rejects.toBeInstanceOf(
			AppleTokenInvalidError,
		);
	});

	it("compares the SHA-256 of the raw nonce, as iOS sends it", async () => {
		const signer = await createTestSigner();
		const identity = await verifyWith(signer);
		expect(identity.nonceHash).toMatch(/^[0-9a-f]{64}$/);
	});
});
