import { describe, expect, it } from "vitest";
import {
	TokenCipher,
	TokenCipherConfigError,
	TokenDecryptError,
	base64Decode,
	base64Encode,
	tokenCipherFromEnv,
} from "../../src/api/crypto/tokenCipher";

const KEY_A = base64Encode(new Uint8Array(32).fill(7));
const KEY_B = base64Encode(new Uint8Array(32).fill(9));

const AAD = {
	authIdentityId: "identity-1",
	provider: "apple",
	purpose: "provider-refresh-token",
};

describe("sealing a refresh token", () => {
	it("round-trips the token", async () => {
		const cipher = new TokenCipher({ version: 1, material: KEY_A });
		const sealed = await cipher.seal("apple-refresh-token", AAD);
		expect(await cipher.open(sealed, AAD)).toBe("apple-refresh-token");
	});

	it("never stores the plaintext", async () => {
		const cipher = new TokenCipher({ version: 1, material: KEY_A });
		const sealed = await cipher.seal("apple-refresh-token", AAD);

		expect(sealed.ciphertext).not.toContain("apple-refresh-token");
		expect(base64Decode(sealed.ciphertext).length).toBeGreaterThan(0);
		// GCM appends a 16-byte tag, so ciphertext is longer than plaintext.
		expect(base64Decode(sealed.ciphertext).length).toBe(
			"apple-refresh-token".length + 16,
		);
	});

	it("uses a fresh IV every time, so one key never repeats a nonce", async () => {
		// IV reuse under a single key is how AES-GCM stops protecting
		// anything, and a re-sign-in re-encrypts the same identity's token.
		const cipher = new TokenCipher({ version: 1, material: KEY_A });
		const ivs = new Set<string>();
		const ciphertexts = new Set<string>();
		for (let i = 0; i < 50; i += 1) {
			const sealed = await cipher.seal("same-token", AAD);
			ivs.add(sealed.iv);
			ciphertexts.add(sealed.ciphertext);
		}
		expect(ivs.size).toBe(50);
		// Same plaintext, same key, different ciphertext each time.
		expect(ciphertexts.size).toBe(50);
	});

	it("uses a 96-bit IV", async () => {
		const cipher = new TokenCipher({ version: 1, material: KEY_A });
		const sealed = await cipher.seal("t", AAD);
		expect(base64Decode(sealed.iv).length).toBe(12);
	});

	it("records the key version it wrote with", async () => {
		const cipher = new TokenCipher({ version: 4, material: KEY_A });
		expect((await cipher.seal("t", AAD)).keyVersion).toBe(4);
	});
});

describe("refusing to open what it should not", () => {
	it("refuses a different key", async () => {
		const writer = new TokenCipher({ version: 1, material: KEY_A });
		const reader = new TokenCipher({ version: 1, material: KEY_B });
		const sealed = await writer.seal("apple-refresh-token", AAD);

		await expect(reader.open(sealed, AAD)).rejects.toBeInstanceOf(
			TokenDecryptError,
		);
	});

	it("refuses a ciphertext moved onto another identity", async () => {
		// The attack this closes: copy one row's ciphertext onto someone
		// else's credential row and have deletion revoke the wrong person's
		// Apple account. Encryption alone would not catch it — the attacker
		// never needs to read the token.
		const cipher = new TokenCipher({ version: 1, material: KEY_A });
		const sealed = await cipher.seal("apple-refresh-token", AAD);

		await expect(
			cipher.open(sealed, { ...AAD, authIdentityId: "identity-2" }),
		).rejects.toBeInstanceOf(TokenDecryptError);
	});

	it("refuses a ciphertext reused for another provider or purpose", async () => {
		const cipher = new TokenCipher({ version: 1, material: KEY_A });
		const sealed = await cipher.seal("apple-refresh-token", AAD);

		await expect(
			cipher.open(sealed, { ...AAD, provider: "google" }),
		).rejects.toBeInstanceOf(TokenDecryptError);
		await expect(
			cipher.open(sealed, { ...AAD, purpose: "something-else" }),
		).rejects.toBeInstanceOf(TokenDecryptError);
	});

	it("refuses tampered ciphertext", async () => {
		const cipher = new TokenCipher({ version: 1, material: KEY_A });
		const sealed = await cipher.seal("apple-refresh-token", AAD);
		const bytes = base64Decode(sealed.ciphertext);
		bytes.set([(bytes[0] ?? 0) ^ 0xff], 0);

		await expect(
			cipher.open({ ...sealed, ciphertext: base64Encode(bytes) }, AAD),
		).rejects.toBeInstanceOf(TokenDecryptError);
	});

	it("refuses a swapped IV", async () => {
		const cipher = new TokenCipher({ version: 1, material: KEY_A });
		const a = await cipher.seal("token-a", AAD);
		const b = await cipher.seal("token-b", AAD);

		await expect(
			cipher.open({ ...a, iv: b.iv }, AAD),
		).rejects.toBeInstanceOf(TokenDecryptError);
	});

	it("refuses a version it has no key for", async () => {
		const cipher = new TokenCipher({ version: 2, material: KEY_A });
		const sealed = await cipher.seal("t", AAD);

		await expect(
			cipher.open({ ...sealed, keyVersion: 1 }, AAD),
		).rejects.toBeInstanceOf(TokenDecryptError);
	});

	it("never puts the token or the key in the error", async () => {
		const writer = new TokenCipher({ version: 1, material: KEY_A });
		const reader = new TokenCipher({ version: 1, material: KEY_B });
		const sealed = await writer.seal("super-secret-refresh-token", AAD);

		const error = await reader.open(sealed, AAD).catch((e: Error) => e);
		expect(String(error)).not.toContain("super-secret-refresh-token");
		expect(String(error)).not.toContain(KEY_A);
		expect(String(error)).not.toContain(KEY_B);
		expect(String(error)).not.toContain(sealed.ciphertext);
	});
});

describe("key rotation", () => {
	it("reads rows written with the previous key and writes with the current one", async () => {
		const old = new TokenCipher({ version: 1, material: KEY_A });
		const sealedOld = await old.seal("apple-refresh-token", AAD);

		const rotated = new TokenCipher({ version: 2, material: KEY_B }, [
			{ version: 1, material: KEY_A },
		]);

		expect(await rotated.open(sealedOld, AAD)).toBe("apple-refresh-token");
		// New writes use the new key, so a re-encrypt pass drains version 1.
		expect((await rotated.seal("t", AAD)).keyVersion).toBe(2);
	});

	it("refuses two keys claiming the same version", async () => {
		expect(
			() =>
				new TokenCipher({ version: 1, material: KEY_A }, [
					{ version: 1, material: KEY_B },
				]),
		).toThrow(TokenCipherConfigError);
	});
});

describe("configuration", () => {
	it("is absent, not permissive, when no key is set", () => {
		expect(tokenCipherFromEnv({})).toBeNull();
	});

	it("defaults the version to 1", async () => {
		const cipher = tokenCipherFromEnv({ APPLE_TOKEN_ENCRYPTION_KEY: KEY_A });
		expect((await cipher!.seal("t", AAD)).keyVersion).toBe(1);
	});

	it("carries a decrypt-only predecessor", async () => {
		const old = new TokenCipher({ version: 1, material: KEY_A });
		const sealed = await old.seal("apple-refresh-token", AAD);

		const cipher = tokenCipherFromEnv({
			APPLE_TOKEN_ENCRYPTION_KEY: KEY_B,
			APPLE_TOKEN_ENCRYPTION_KEY_VERSION: "2",
			APPLE_TOKEN_ENCRYPTION_KEY_PREVIOUS: KEY_A,
			APPLE_TOKEN_ENCRYPTION_KEY_PREVIOUS_VERSION: "1",
		});

		expect(await cipher!.open(sealed, AAD)).toBe("apple-refresh-token");
	});

	it("rejects a key that is the wrong length, without quoting it", () => {
		const short = base64Encode(new Uint8Array(16).fill(1));
		const error = (() => {
			try {
				tokenCipherFromEnv({ APPLE_TOKEN_ENCRYPTION_KEY: short });
				return null;
			} catch (e) {
				return e as Error;
			}
		})();

		expect(error).toBeInstanceOf(TokenCipherConfigError);
		expect(String(error)).not.toContain(short);
		expect(String(error)).toContain("32 bytes");
	});

	it("rejects a key that is not base64", () => {
		expect(() =>
			tokenCipherFromEnv({ APPLE_TOKEN_ENCRYPTION_KEY: "not base64 !!!" }),
		).toThrow(TokenCipherConfigError);
	});

	it("rejects a nonsense key version", () => {
		expect(() =>
			tokenCipherFromEnv({
				APPLE_TOKEN_ENCRYPTION_KEY: KEY_A,
				APPLE_TOKEN_ENCRYPTION_KEY_VERSION: "-1",
			}),
		).toThrow(TokenCipherConfigError);
	});
});
