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
import { type TokenCipher, TokenDecryptError } from "../crypto/tokenCipher";
import {
	markCredentialRevoked,
	readRefreshToken,
} from "../db/providerCredentials";
import type { AppleClientSecretConfig } from "./appleClientSecret";
import {
	type AppleRevocationOutcome,
	revokeAppleRefreshToken,
} from "./appleTokenExchange";

export type RevokeIdentityOutcome =
	/** Apple confirmed it, or had already forgotten the token. Material erased. */
	| { status: "revoked" }
	/** No credential to revoke — never stored, or already done. Nothing to do. */
	| { status: "nothingToRevoke" }
	/** Transient: Apple unreachable. Keep the account deleting and retry. */
	| { status: "retryable"; reason: "providerUnavailable" }
	/**
	 * The row exists but cannot be opened — wrong key version, tampering, or
	 * a ciphertext moved between identities. Not retryable by waiting, and
	 * deliberately not silently swallowed: an operator has to know.
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

	let refreshToken: string | null;
	try {
		refreshToken = await readRefreshToken(
			input.db,
			input.cipher,
			input.authIdentityId,
		);
	} catch (error) {
		if (error instanceof TokenDecryptError) {
			return { status: "unrevocable", reason: "decryptFailed" };
		}
		throw error;
	}

	if (refreshToken === null) return { status: "nothingToRevoke" };

	const outcome: AppleRevocationOutcome = await revokeAppleRefreshToken({
		refreshToken,
		config: input.config,
		fetchImpl: input.fetchImpl,
		now,
	});

	if (outcome.status === "unavailable") {
		// The material stays put: a retry needs it.
		return { status: "retryable", reason: "providerUnavailable" };
	}

	// Both "revoked" and "alreadyInvalid" reach the same end state — Apple no
	// longer honours the token — so both erase it here.
	await markCredentialRevoked(input.db, input.authIdentityId, now);
	return { status: "revoked" };
}
