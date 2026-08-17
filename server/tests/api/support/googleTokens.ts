/**
 * Mints Google Sign-In ID tokens for tests.
 *
 * Same arrangement as the Apple helper: a real RSA keypair generated per test
 * run signs a real RS256 token with Google's claim shape, so the production
 * verification path runs end to end. No Google credential of any kind is
 * involved, and no network call is made.
 */

import { GOOGLE_ISSUERS } from "../../../src/api/auth/google";

export { type TestSigner, createTestSigner } from "./testSigner";

/** Stands in for the iOS OAuth client id. Not a real Google client. */
export const TEST_GOOGLE_AUDIENCE =
	"000000000000-testclient.apps.googleusercontent.com";

/** Claims shaped like Google's, overridable per test. */
export async function googleClaims(overrides: Record<string, unknown> = {}) {
	const now = 1_800_000_000;
	return {
		iss: GOOGLE_ISSUERS[0],
		aud: TEST_GOOGLE_AUDIENCE,
		// Google subjects are numeric strings.
		sub: "112233445566778899000",
		iat: now,
		exp: now + 3600,
		...overrides,
	};
}
