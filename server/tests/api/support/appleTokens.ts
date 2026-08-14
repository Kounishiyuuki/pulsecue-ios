/**
 * Mints Sign in with Apple identity tokens for tests.
 *
 * A real RSA keypair, a real RS256 signature, and the real claim shape
 * Apple sends. The verification path under test is therefore the production
 * one: the only thing swapped out is *whose* key set is published, which is
 * exactly the boundary `JwksProvider` exists to provide.
 *
 * Nothing here is an Apple credential. The keypair is generated per test
 * run and never leaves the process.
 */

import { APPLE_ISSUER } from "../../../src/api/auth/apple";
import { StaticJwksProvider } from "../../../src/api/auth/jwks";
import { base64urlEncode } from "../../../src/api/auth/jwt";

export interface TestSigner {
	kid: string;
	jwks: StaticJwksProvider;
	/** The public JWK, for building a provider that omits or rotates it. */
	publicJwk: JsonWebKey & { kid: string };
	sign(claims: Record<string, unknown>, header?: Record<string, unknown>): Promise<string>;
}

export async function createTestSigner(kid = "test-key-1"): Promise<TestSigner> {
	const pair = (await crypto.subtle.generateKey(
		{
			name: "RSASSA-PKCS1-v1_5",
			modulusLength: 2048,
			publicExponent: new Uint8Array([1, 0, 1]),
			hash: "SHA-256",
		},
		true,
		["sign", "verify"],
	)) as CryptoKeyPair;

	const exported = (await crypto.subtle.exportKey(
		"jwk",
		pair.publicKey,
	)) as JsonWebKey;
	const publicJwk = { ...exported, kid, alg: "RS256", use: "sig" } as JsonWebKey & {
		kid: string;
	};

	return {
		kid,
		publicJwk,
		jwks: new StaticJwksProvider([publicJwk]),
		async sign(claims, header = {}) {
			const encodedHeader = base64urlEncode(
				new TextEncoder().encode(
					JSON.stringify({ alg: "RS256", kid, typ: "JWT", ...header }),
				),
			);
			const encodedClaims = base64urlEncode(
				new TextEncoder().encode(JSON.stringify(claims)),
			);
			const signingInput = `${encodedHeader}.${encodedClaims}`;
			const signature = await crypto.subtle.sign(
				"RSASSA-PKCS1-v1_5",
				pair.privateKey,
				new TextEncoder().encode(signingInput) as unknown as BufferSource,
			);
			return `${signingInput}.${base64urlEncode(new Uint8Array(signature))}`;
		},
	};
}

export const TEST_AUDIENCE = "com.example.pulsecue.tests";

/** Claims shaped like Apple's, overridable per test. */
export async function appleClaims(overrides: Record<string, unknown> = {}) {
	const now = 1_800_000_000;
	return {
		iss: APPLE_ISSUER,
		aud: TEST_AUDIENCE,
		sub: "000123.abcdef.1234",
		iat: now,
		exp: now + 600,
		...overrides,
	};
}

/** SHA-256 hex of a nonce, matching what iOS hands Apple. */
export async function hashedNonce(raw: string): Promise<string> {
	const digest = await crypto.subtle.digest(
		"SHA-256",
		new TextEncoder().encode(raw),
	);
	return Array.from(new Uint8Array(digest))
		.map((byte) => byte.toString(16).padStart(2, "0"))
		.join("");
}
