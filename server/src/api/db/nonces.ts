/**
 * Single-use enforcement for sign-in nonces.
 *
 * `verifyAppleIdentityToken` proves a token is bound to a nonce. This makes
 * that nonce usable exactly once, which is what stops a captured request
 * body from being replayed for the rest of the token's lifetime.
 */

import type { AuthProvider, EpochSeconds, SqlDatabase } from "../types";
import { nowSeconds } from "./ids";

export class NonceAlreadyUsedError extends Error {
	constructor() {
		super("nonce has already been used");
		this.name = "NonceAlreadyUsedError";
	}
}

/**
 * Claims a nonce, or throws if it was already claimed.
 *
 * The primary key does the work: two concurrent replays cannot both insert,
 * so exactly one of them proceeds. Checking first and inserting after would
 * leave a window where both pass.
 */
export async function consumeNonce(
	db: SqlDatabase,
	params: {
		nonceHash: string;
		provider: AuthProvider;
		expiresAt: EpochSeconds;
		now?: EpochSeconds;
	},
): Promise<void> {
	const now = params.now ?? nowSeconds();
	try {
		await db
			.prepare(
				`INSERT INTO auth_nonces (nonce_sha256, provider, used_at, expires_at)
				 VALUES (?, ?, ?, ?)`,
			)
			.bind(params.nonceHash, params.provider, now, params.expiresAt)
			.run();
	} catch {
		// The only constraint on this table is the primary key, so a failure
		// here means the nonce was already recorded.
		throw new NonceAlreadyUsedError();
	}
}

/**
 * Drops nonces whose token has expired. A replay of one of these would be
 * refused for being expired, so the row has no further value.
 */
export async function purgeExpiredNonces(
	db: SqlDatabase,
	now: EpochSeconds = nowSeconds(),
): Promise<void> {
	await db
		.prepare(`DELETE FROM auth_nonces WHERE expires_at <= ?`)
		.bind(now)
		.run();
}
