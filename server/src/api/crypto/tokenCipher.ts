/**
 * Authenticated encryption for provider refresh tokens.
 *
 * A refresh token is a long-lived credential for someone else's account
 * system. PulseCue holds Apple's only because Apple requires a revocation
 * call at account deletion, so the bar is: a D1 disclosure must not hand the
 * reader a usable Apple credential.
 *
 * AES-256-GCM, because it authenticates as well as encrypts. That second
 * property is what makes the AAD useful: the ciphertext is bound to the
 * identity, provider, purpose and key version it was written for, so a row
 * copied onto a *different* `auth_identity_id` fails to decrypt instead of
 * quietly revoking the wrong person's Apple session. Encryption alone would
 * not catch that — the attacker never needs to read the token to misuse it.
 *
 * A fresh 96-bit IV is generated per encryption and stored beside the
 * ciphertext. IV reuse under one key is the way GCM fails catastrophically,
 * so the IV is never derived, never defaulted, and never reused on update:
 * re-encrypting the same token produces a new IV every time.
 *
 * Keys are versioned. Only one key encrypts; any number may decrypt. That is
 * the whole of the rotation story on purpose — enough that a future key swap
 * is a config change and a re-encrypt pass rather than a schema migration,
 * and not one line more.
 */

export class TokenCipherConfigError extends Error {
	constructor(reason: string) {
		super(`token encryption is not configured: ${reason}`);
		this.name = "TokenCipherConfigError";
	}
}

export class TokenDecryptError extends Error {
	constructor(reason: string) {
		// Never quotes ciphertext, key material, or the AAD's values.
		super(`could not decrypt stored credential: ${reason}`);
		this.name = "TokenDecryptError";
	}
}

/** AES-256-GCM needs exactly 32 bytes of key. */
const KEY_BYTES = 32;
/** 96 bits, the size GCM is specified for. */
const IV_BYTES = 12;

export interface EncryptionKey {
	/** Monotonic. Stored with the row so old ciphertext stays readable. */
	version: number;
	/** Base64 of exactly 32 bytes. A Worker secret in production. */
	material: string;
}

export interface SealedToken {
	ciphertext: string;
	iv: string;
	keyVersion: number;
}

/**
 * What a ciphertext is bound to. Every field is already known to the caller
 * from the row itself, so nothing extra is stored — but changing any of them
 * makes the ciphertext undecryptable.
 */
export interface CredentialAad {
	authIdentityId: string;
	provider: string;
	purpose: string;
	keyVersion: number;
}

export class TokenCipher {
	private readonly byVersion = new Map<number, Uint8Array>();
	private readonly current: EncryptionKey;

	/**
	 * @param current  the key new ciphertext is written with.
	 * @param previous decrypt-only keys, kept so a rotation does not orphan
	 *                 rows written before it.
	 */
	constructor(current: EncryptionKey, previous: EncryptionKey[] = []) {
		this.current = current;
		for (const key of [current, ...previous]) {
			if (this.byVersion.has(key.version)) {
				throw new TokenCipherConfigError("two keys share a version");
			}
			this.byVersion.set(key.version, decodeKey(key));
		}
	}

	async seal(plaintext: string, aad: Omit<CredentialAad, "keyVersion">): Promise<SealedToken> {
		const keyVersion = this.current.version;
		const iv = crypto.getRandomValues(new Uint8Array(IV_BYTES));
		const key = await this.importKey(keyVersion, "encrypt");

		const sealed = await crypto.subtle.encrypt(
			{
				name: "AES-GCM",
				iv: iv as unknown as BufferSource,
				additionalData: encodeAad({ ...aad, keyVersion }) as unknown as BufferSource,
			},
			key,
			new TextEncoder().encode(plaintext) as unknown as BufferSource,
		);

		return {
			ciphertext: base64Encode(new Uint8Array(sealed)),
			iv: base64Encode(iv),
			keyVersion,
		};
	}

	async open(sealed: SealedToken, aad: Omit<CredentialAad, "keyVersion">): Promise<string> {
		if (!this.byVersion.has(sealed.keyVersion)) {
			// The row was written with a key this deployment does not carry.
			// Refusing is the only safe answer; guessing with another key would
			// just fail the tag check anyway.
			throw new TokenDecryptError("no key for that version");
		}
		const key = await this.importKey(sealed.keyVersion, "decrypt");

		let opened: ArrayBuffer;
		try {
			opened = await crypto.subtle.decrypt(
				{
					name: "AES-GCM",
					iv: base64Decode(sealed.iv) as unknown as BufferSource,
					additionalData: encodeAad({
						...aad,
						keyVersion: sealed.keyVersion,
					}) as unknown as BufferSource,
				},
				key,
				base64Decode(sealed.ciphertext) as unknown as BufferSource,
			);
		} catch {
			// Wrong key, tampered ciphertext, or a row moved to another
			// identity. All three are the same answer, and none of them says
			// which.
			throw new TokenDecryptError("authentication failed");
		}
		return new TextDecoder().decode(opened);
	}

	private async importKey(
		version: number,
		usage: "encrypt" | "decrypt",
	): Promise<CryptoKey> {
		const material = this.byVersion.get(version);
		if (!material) throw new TokenDecryptError("no key for that version");
		return crypto.subtle.importKey(
			"raw",
			material as unknown as BufferSource,
			{ name: "AES-GCM" },
			false,
			[usage],
		);
	}
}

/**
 * Builds a cipher from environment config, or explains why it cannot.
 *
 * Returns `null` rather than throwing when nothing is configured at all, so
 * the caller can decide: a deployment without Apple credentials configured
 * must refuse Apple sign-in, not crash on boot.
 */
export function tokenCipherFromEnv(env: {
	APPLE_TOKEN_ENCRYPTION_KEY?: string;
	APPLE_TOKEN_ENCRYPTION_KEY_VERSION?: string;
	APPLE_TOKEN_ENCRYPTION_KEY_PREVIOUS?: string;
	APPLE_TOKEN_ENCRYPTION_KEY_PREVIOUS_VERSION?: string;
}): TokenCipher | null {
	if (!env.APPLE_TOKEN_ENCRYPTION_KEY) return null;

	const current: EncryptionKey = {
		version: parseVersion(env.APPLE_TOKEN_ENCRYPTION_KEY_VERSION, 1),
		material: env.APPLE_TOKEN_ENCRYPTION_KEY,
	};
	const previous: EncryptionKey[] = [];
	if (env.APPLE_TOKEN_ENCRYPTION_KEY_PREVIOUS) {
		previous.push({
			version: parseVersion(env.APPLE_TOKEN_ENCRYPTION_KEY_PREVIOUS_VERSION, 0),
			material: env.APPLE_TOKEN_ENCRYPTION_KEY_PREVIOUS,
		});
	}
	return new TokenCipher(current, previous);
}

function parseVersion(raw: string | undefined, fallback: number): number {
	if (raw === undefined || raw === "") return fallback;
	const parsed = Number(raw);
	if (!Number.isInteger(parsed) || parsed < 0) {
		throw new TokenCipherConfigError("key version is not a non-negative integer");
	}
	return parsed;
}

function decodeKey(key: EncryptionKey): Uint8Array {
	let bytes: Uint8Array;
	try {
		bytes = base64Decode(key.material);
	} catch {
		throw new TokenCipherConfigError("key is not base64");
	}
	if (bytes.length !== KEY_BYTES) {
		// Length, never the value.
		throw new TokenCipherConfigError(
			`key must be ${KEY_BYTES} bytes, got ${bytes.length}`,
		);
	}
	return bytes;
}

/**
 * A fixed, unambiguous encoding. The separator cannot appear in a UUID, a
 * provider name or a version, so two different tuples cannot encode to the
 * same bytes.
 */
function encodeAad(aad: CredentialAad): Uint8Array {
	return new TextEncoder().encode(
		`pulsecue|v${aad.keyVersion}|${aad.provider}|${aad.purpose}|${aad.authIdentityId}`,
	);
}

export function base64Encode(bytes: Uint8Array): string {
	let binary = "";
	for (const byte of bytes) binary += String.fromCharCode(byte);
	return btoa(binary);
}

export function base64Decode(value: string): Uint8Array {
	const binary = atob(value);
	const bytes = new Uint8Array(binary.length);
	for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
	return bytes;
}
