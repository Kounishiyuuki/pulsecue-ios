import { describe, expect, it } from "vitest";
import {
	APPLE_TOKEN_AUDIENCE,
	AppleClientSecretConfigError,
	CLIENT_SECRET_TTL_SECONDS,
	appleClientSecretConfigFromEnv,
	createAppleClientSecret,
} from "../../src/api/auth/appleClientSecret";
import { base64urlDecode } from "../../src/api/auth/jwt";
import {
	TEST_APPLE_CLIENT_ID,
	TEST_APPLE_KEY_ID,
	TEST_APPLE_TEAM_ID,
	createTestAppleSigningKey,
} from "./support/appleProduction";

const NOW = 1_800_000_000;

function segment(token: string, index: number): Record<string, unknown> {
	const part = token.split(".")[index] as string;
	return JSON.parse(new TextDecoder().decode(base64urlDecode(part)));
}

describe("the client secret Apple requires", () => {
	it("carries the header Apple specifies", async () => {
		const key = await createTestAppleSigningKey();
		const secret = await createAppleClientSecret(key.config, NOW);

		expect(segment(secret, 0)).toEqual({
			alg: "ES256",
			kid: TEST_APPLE_KEY_ID,
			typ: "JWT",
		});
	});

	it("carries the claims Apple specifies", async () => {
		const key = await createTestAppleSigningKey();
		const secret = await createAppleClientSecret(key.config, NOW);

		expect(segment(secret, 1)).toEqual({
			iss: TEST_APPLE_TEAM_ID,
			iat: NOW,
			exp: NOW + CLIENT_SECRET_TTL_SECONDS,
			aud: APPLE_TOKEN_AUDIENCE,
			sub: TEST_APPLE_CLIENT_ID,
		});
	});

	it("is short-lived rather than the six months Apple allows", async () => {
		// A secret that lives for minutes cannot be replayed for half a year
		// if it ever appears in a log or a heap dump.
		const key = await createTestAppleSigningKey();
		const claims = segment(await createAppleClientSecret(key.config, NOW), 1);
		const lifetime = (claims.exp as number) - (claims.iat as number);

		expect(lifetime).toBe(CLIENT_SECRET_TTL_SECONDS);
		expect(lifetime).toBeLessThanOrEqual(15 * 60);
	});

	it("really is signed by the private key, with a raw r‖s ES256 signature", async () => {
		const key = await createTestAppleSigningKey();
		const secret = await createAppleClientSecret(key.config, NOW);
		const [header, claims, signature] = secret.split(".") as [
			string,
			string,
			string,
		];

		const raw = base64urlDecode(signature);
		// JWS ES256 is the concatenated pair, not DER. 64 bytes for P-256.
		expect(raw.length).toBe(64);

		const verified = await crypto.subtle.verify(
			{ name: "ECDSA", hash: "SHA-256" },
			key.publicKey,
			raw as unknown as BufferSource,
			new TextEncoder().encode(`${header}.${claims}`) as unknown as BufferSource,
		);
		expect(verified).toBe(true);
	});

	it("does not verify under a different key", async () => {
		const key = await createTestAppleSigningKey();
		const impostor = await createTestAppleSigningKey();
		const secret = await createAppleClientSecret(impostor.config, NOW);
		const [header, claims, signature] = secret.split(".") as [
			string,
			string,
			string,
		];

		const verified = await crypto.subtle.verify(
			{ name: "ECDSA", hash: "SHA-256" },
			key.publicKey,
			base64urlDecode(signature) as unknown as BufferSource,
			new TextEncoder().encode(`${header}.${claims}`) as unknown as BufferSource,
		);
		expect(verified).toBe(false);
	});

	it("signs a different value each time, as ECDSA does", async () => {
		const key = await createTestAppleSigningKey();
		const a = await createAppleClientSecret(key.config, NOW);
		const b = await createAppleClientSecret(key.config, NOW);
		// Same claims, different signature: ECDSA is randomised.
		expect(a).not.toBe(b);
	});
});

describe("client secret configuration", () => {
	it("is absent, not permissive, when nothing is set", () => {
		expect(appleClientSecretConfigFromEnv({})).toBeNull();
	});

	it("refuses a half-filled config rather than behaving like an empty one", () => {
		// Half-configured is a mistake someone made. Silently treating it as
		// "Apple not configured" would hide it.
		expect(() =>
			appleClientSecretConfigFromEnv({
				APPLE_CLIENT_ID: TEST_APPLE_CLIENT_ID,
				APPLE_TEAM_ID: TEST_APPLE_TEAM_ID,
			}),
		).toThrow(AppleClientSecretConfigError);
	});

	it("names what is missing without quoting the key", () => {
		const error = (() => {
			try {
				appleClientSecretConfigFromEnv({
					APPLE_CLIENT_ID: TEST_APPLE_CLIENT_ID,
					APPLE_TEAM_ID: TEST_APPLE_TEAM_ID,
					APPLE_KEY_ID: TEST_APPLE_KEY_ID,
				});
				return null;
			} catch (e) {
				return e as Error;
			}
		})();
		expect(String(error)).toContain("privateKeyPem");
	});

	it("reads a complete config", async () => {
		const key = await createTestAppleSigningKey();
		const config = appleClientSecretConfigFromEnv({
			APPLE_CLIENT_ID: TEST_APPLE_CLIENT_ID,
			APPLE_TEAM_ID: TEST_APPLE_TEAM_ID,
			APPLE_KEY_ID: TEST_APPLE_KEY_ID,
			APPLE_PRIVATE_KEY: key.config.privateKeyPem,
		});
		expect(config?.clientId).toBe(TEST_APPLE_CLIENT_ID);
		// And it actually signs.
		await expect(createAppleClientSecret(config!, NOW)).resolves.toContain(".");
	});
});

describe("a private key that is not usable", () => {
	it("rejects an empty key", async () => {
		const key = await createTestAppleSigningKey({ privateKeyPem: "" });
		await expect(
			createAppleClientSecret(key.config, NOW),
		).rejects.toBeInstanceOf(AppleClientSecretConfigError);
	});

	it("rejects a key that is not base64 PEM", async () => {
		const key = await createTestAppleSigningKey({
			privateKeyPem:
				"-----BEGIN PRIVATE KEY-----\n!!!not base64!!!\n-----END PRIVATE KEY-----",
		});
		await expect(
			createAppleClientSecret(key.config, NOW),
		).rejects.toBeInstanceOf(AppleClientSecretConfigError);
	});

	it("rejects a well-formed key that is not P-256", async () => {
		const rsa = (await crypto.subtle.generateKey(
			{
				name: "RSASSA-PKCS1-v1_5",
				modulusLength: 2048,
				publicExponent: new Uint8Array([1, 0, 1]),
				hash: "SHA-256",
			},
			true,
			["sign", "verify"],
		)) as CryptoKeyPair;
		const pkcs8 = new Uint8Array(
			(await crypto.subtle.exportKey("pkcs8", rsa.privateKey)) as ArrayBuffer,
		);
		let binary = "";
		for (const byte of pkcs8) binary += String.fromCharCode(byte);
		const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(binary)}\n-----END PRIVATE KEY-----`;

		const key = await createTestAppleSigningKey({ privateKeyPem: pem });
		await expect(
			createAppleClientSecret(key.config, NOW),
		).rejects.toBeInstanceOf(AppleClientSecretConfigError);
	});

	it("never puts key material in the error", async () => {
		const real = await createTestAppleSigningKey();
		const key = await createTestAppleSigningKey({
			privateKeyPem: `${real.config.privateKeyPem}-corrupted`,
		});
		const error = await createAppleClientSecret(key.config, NOW).catch(
			(e: Error) => e,
		);
		expect(String(error)).not.toContain(real.config.privateKeyPem.slice(40, 80));
	});
});
