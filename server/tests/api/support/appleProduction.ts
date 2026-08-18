/**
 * Test doubles for Apple's token lifecycle.
 *
 * Two things are faked and nothing else: the P-256 key that signs the client
 * secret, and the HTTP endpoint that answers the exchange. The client-secret
 * generator, the response validation, the encryption and the storage are all
 * the production code.
 *
 * **No Apple credential exists here.** The EC keypair is generated per test
 * run, exported to PKCS#8 PEM in memory, and never written to disk. It is not
 * a `.p8`, is not registered with Apple, and signs nothing Apple would honour.
 */

import type { AppleClientSecretConfig } from "../../../src/api/auth/appleClientSecret";
import { base64Encode } from "../../../src/api/crypto/tokenCipher";
import type { TestSigner } from "./testSigner";

export const TEST_APPLE_CLIENT_ID = "com.example.pulsecue.tests";
export const TEST_APPLE_TEAM_ID = "TEAM000000";
export const TEST_APPLE_KEY_ID = "KEY0000000";

export interface TestAppleSigningKey {
	config: AppleClientSecretConfig;
	/** For verifying, in tests, that the client secret really is signed. */
	publicKey: CryptoKey;
}

/** A throwaway P-256 keypair in the PKCS#8 PEM shape a real .p8 carries. */
export async function createTestAppleSigningKey(
	overrides: Partial<AppleClientSecretConfig> = {},
): Promise<TestAppleSigningKey> {
	const pair = (await crypto.subtle.generateKey(
		{ name: "ECDSA", namedCurve: "P-256" },
		true,
		["sign", "verify"],
	)) as CryptoKeyPair;

	const pkcs8 = new Uint8Array(
		(await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer,
	);

	return {
		config: {
			clientId: TEST_APPLE_CLIENT_ID,
			teamId: TEST_APPLE_TEAM_ID,
			keyId: TEST_APPLE_KEY_ID,
			privateKeyPem: toPem(pkcs8),
			...overrides,
		},
		publicKey: pair.publicKey,
	};
}

function toPem(der: Uint8Array): string {
	const body = base64Encode(der).replace(/(.{64})/g, "$1\n");
	return `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----\n`;
}

/** A 32-byte AES key, base64, freshly random per call. */
export function testEncryptionKey(): string {
	return base64Encode(crypto.getRandomValues(new Uint8Array(32)));
}

export interface RecordedRequest {
	url: string;
	form: Record<string, string>;
}

export interface FakeAppleEndpoint {
	fetchImpl: typeof fetch;
	requests: RecordedRequest[];
}

/**
 * Stands in for `appleid.apple.com`, recording what was posted so a test can
 * assert on the client secret without Apple ever being contacted.
 */
export function fakeAppleEndpoint(
	responder: (request: RecordedRequest) => Response | Promise<Response>,
): FakeAppleEndpoint {
	const requests: RecordedRequest[] = [];
	const fetchImpl = (async (url: string, init?: RequestInit) => {
		const form = Object.fromEntries(
			new URLSearchParams(String(init?.body ?? "")).entries(),
		);
		const request = { url: String(url), form };
		requests.push(request);
		return responder(request);
	}) as unknown as typeof fetch;
	return { fetchImpl, requests };
}

/** The success body Apple returns from `/auth/token`. */
export function appleTokenResponse(
	overrides: Record<string, unknown> = {},
): Response {
	return new Response(
		JSON.stringify({
			access_token: "test-access-token",
			token_type: "Bearer",
			expires_in: 3600,
			refresh_token: "test-refresh-token",
			...overrides,
		}),
		{ status: 200, headers: { "content-type": "application/json" } },
	);
}

/** An OAuth error body, in Apple's documented shape. */
export function appleErrorResponse(code: string, status = 400): Response {
	return new Response(JSON.stringify({ error: code }), {
		status,
		headers: { "content-type": "application/json" },
	});
}

/** Default subject for a minted exchange `id_token`. Matches `appleClaims`. */
export const TEST_APPLE_SUBJECT = "000123.abcdef.1234";

/**
 * Mints the `id_token` Apple puts in a `/auth/token` response.
 *
 * A real RS256 token from the same test signer whose JWKS the verifier is
 * given, so the production verification path runs for real. Note there is
 * deliberately **no nonce**: Apple does not put one on the exchange response,
 * and the verifier must not demand one there.
 */
export async function signExchangeIdToken(
	signer: TestSigner,
	options: {
		sub?: string;
		audience?: string;
		now?: number;
		overrides?: Record<string, unknown>;
	} = {},
): Promise<string> {
	const now = options.now ?? 1_800_000_100;
	return signer.sign({
		iss: "https://appleid.apple.com",
		aud: options.audience ?? TEST_APPLE_CLIENT_ID,
		sub: options.sub ?? TEST_APPLE_SUBJECT,
		iat: now - 10,
		exp: now + 600,
		...(options.overrides ?? {}),
	});
}

/** A `/auth/token` success body carrying a properly signed `id_token`. */
export async function appleTokenResponseFor(
	signer: TestSigner,
	options: {
		sub?: string;
		audience?: string;
		now?: number;
		idTokenOverrides?: Record<string, unknown>;
		bodyOverrides?: Record<string, unknown>;
	} = {},
): Promise<Response> {
	const idToken = await signExchangeIdToken(signer, {
		sub: options.sub,
		audience: options.audience,
		now: options.now,
		overrides: options.idTokenOverrides,
	});
	return appleTokenResponse({ id_token: idToken, ...(options.bodyOverrides ?? {}) });
}

/** Reads `sub` out of a JWT without verifying it. Test convenience only. */
export function unverifiedSubject(token: string): string {
	const payload = token.split(".")[1] ?? "";
	const padded = payload.replace(/-/g, "+").replace(/_/g, "/");
	const json = atob(padded.padEnd(Math.ceil(padded.length / 4) * 4, "="));
	return (JSON.parse(json) as { sub?: string }).sub ?? "";
}
