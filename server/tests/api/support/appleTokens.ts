/**
 * Mints Sign in with Apple identity tokens for tests.
 *
 * The signer itself is provider-neutral and lives in `testSigner.ts`, shared
 * with the Google tests; this file adds Apple's claim shape. Nothing here is
 * an Apple credential — the keypair is generated per test run and never
 * leaves the process.
 */

import { APPLE_ISSUER } from "../../../src/api/auth/apple";
import { sha256Hex } from "./testSigner";

export { type TestSigner, createTestSigner } from "./testSigner";

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
	return sha256Hex(raw);
}
