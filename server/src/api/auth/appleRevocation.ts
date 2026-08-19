/**
 * Revoking a stored Apple credential.
 *
 * The service boundary account deletion will call, kept separate from the
 * deletion route so it can be built and tested before the route exists. It
 * does three things in order — read the credential, revoke it at Apple, erase
 * the material — and reports which of them happened.
 *
 * The outcome is a closed set rather than an exception, because the caller
 * has to make a genuinely different decision for each one. In particular:
 * "Apple is unreachable" must never be recorded as "revoked". Deletion has to
 * stay pending and retry, and an account that reports a revocation that never
 * happened is exactly the failure Apple's requirement exists to prevent.
 */

import type { EpochSeconds, SqlDatabase } from "../types";
import type { TokenCipher } from "../crypto/tokenCipher";
import {
	markCredentialRevoked,
	readStoredCredential,
} from "../db/providerCredentials";
import type { AppleClientSecretConfig } from "./appleClientSecret";
import {
	type AppleRevocationOutcome,
	revokeAppleRefreshToken,
} from "./appleTokenExchange";

export type RevokeIdentityOutcome =
	/**
	 * **Apple answered HTTP 2xx.** The only outcome that means the token is
	 * gone, and the only one that erases the stored material.
	 */
	| { status: "revoked" }
	/** No credential to revoke — never stored, or already erased. */
	| { status: "nothingToRevoke" }
	/**
	 * Not revoked, and the credential is kept so a retry still has it.
	 *
	 * `providerUnavailable` — network trouble or a 5xx.
	 * `providerRejected`    — Apple answered 4xx. Not transient in the "wait
	 *   and it heals" sense (it usually means a misconfigured client secret),
	 *   but emphatically **not** evidence the token was revoked, so the safe
	 *   response is still to keep the credential and try again. The distinct
	 *   reason is what tells an operator which of the two they are looking at.
	 */
	| { status: "retryable"; reason: "providerUnavailable" | "providerRejected" }
	/**
	 * The row exists but cannot be opened — wrong key version, tampering, or
	 * a ciphertext moved between identities. Not fixable by waiting, and
	 * deliberately not silently swallowed: an operator has to know.
	 *
	 * This does **not** mean the token was revoked at Apple. It means we can
	 * no longer produce the credential needed to try.
	 */
	| { status: "unrevocable"; reason: "decryptFailed" };

export interface RevokeIdentityInput {
	db: SqlDatabase;
	cipher: TokenCipher;
	config: AppleClientSecretConfig;
	authIdentityId: string;
	fetchImpl?: typeof fetch;
	now?: EpochSeconds;
}

export async function revokeAppleIdentityCredential(
	input: RevokeIdentityInput,
): Promise<RevokeIdentityOutcome> {
	const now = input.now ?? Math.floor(Date.now() / 1000);

	const stored = await readStoredCredential(
		input.db,
		input.cipher,
		input.authIdentityId,
	);

	switch (stored.status) {
		case "absent":
			// This identity never stored a credential — a Google identity, or
			// an Apple one from before the exchange existed.
			return { status: "nothingToRevoke" };

		case "alreadyRevoked":
			// The material was blanked after a confirmed 2xx. Nothing is owed.
			return { status: "nothingToRevoke" };

		case "unreadable":
			// A row that is still live as far as Apple is concerned, whose
			// material we cannot turn back into a token. Emphatically NOT the
			// same as having no credential: reporting it as such would let
			// deletion hard-delete the account while the grant stays alive and
			// becomes untraceable. Nothing is sent to Apple, and the row is
			// left exactly as it is so a restored key can still recover it.
			return { status: "unrevocable", reason: "decryptFailed" };

		case "readable":
			break;
	}

	const refreshToken = stored.refreshToken;

	const outcome: AppleRevocationOutcome = await revokeAppleRefreshToken({
		refreshToken,
		config: input.config,
		fetchImpl: input.fetchImpl,
		now,
	});

	if (outcome.status !== "revoked") {
		// Anything short of an Apple 2xx leaves the material exactly where it
		// is. A retry needs it, and erasing it here would destroy the only
		// copy of a credential that is, as far as anyone knows, still live.
		return {
			status: "retryable",
			reason:
				outcome.status === "rejected" ? "providerRejected" : "providerUnavailable",
		};
	}

	// Only now: Apple returned 2xx, so the token really is gone.
	await markCredentialRevoked(input.db, input.authIdentityId, now);
	return { status: "revoked" };
}
