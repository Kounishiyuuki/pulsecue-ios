/**
 * Single-use enforcement for sign-in nonces.
 *
 * `verifyAppleIdentityToken` proves a token is bound to a nonce. This makes
 * that nonce usable exactly once, which is what stops a captured request
 * body from being replayed for the rest of the token's lifetime.
 */

import type { AuthProvider, EpochSeconds, SqlDatabase } from "../types";
import { APPLE_CLOCK_SKEW_SECONDS } from "../auth/apple";
import { nowSeconds } from "./ids";

export class NonceAlreadyUsedError extends Error {
	constructor() {
		super("nonce has already been used");
		this.name = "NonceAlreadyUsedError";
	}
}

/**
 * The nonce store could not answer — D1 unavailable, or an unexpected
 * failure that is not the primary key rejecting a duplicate.
 *
 * A distinct type because the two must not share an HTTP status: a replay is
 * a bad credential (401), while a database outage is ours (503). Reporting an
 * outage as a bad credential tells a user their sign-in failed for a reason
 * that is not true, and hides the incident.
 */
export class NonceStoreUnavailableError extends Error {
	constructor() {
		super("nonce store is unavailable");
		this.name = "NonceStoreUnavailableError";
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
		// Which failure was it? Treating *every* insert error as a replay
		// turns a D1 outage into "your credentials are invalid" for every
		// user at once.
		//
		// The distinction is drawn by asking the table rather than by reading
		// the driver's error text: error strings are provider-specific and
		// change between D1 versions and the SQLite double used in tests, so
		// matching on them would be brittle in exactly the situation that
		// matters. If the row is there, the primary key rejected a duplicate
		// and this is a replay. If it is not there — or the lookup itself
		// fails — the store is the problem.
		let existing: unknown = null;
		try {
			existing = await db
				.prepare(`SELECT 1 FROM auth_nonces WHERE nonce_sha256 = ?`)
				.bind(params.nonceHash)
				.first();
		} catch {
			throw new NonceStoreUnavailableError();
		}
		if (existing) throw new NonceAlreadyUsedError();
		throw new NonceStoreUnavailableError();
	}
}

/**
 * Drops nonces whose token can no longer be replayed.
 *
 * **The retention boundary is not `expires_at`.** Verification accepts a
 * token until `exp + APPLE_CLOCK_SKEW_SECONDS`, so deleting the row the
 * instant `expires_at` passes opens a window in which the token is still
 * accepted but its nonce is gone — the cleanup would create the replay hole
 * that the nonce exists to close. `purgeReplayableNonces` is the function to
 * schedule; it applies the same skew the verifier does.
 *
 * This lower-level form takes the cutoff directly and does no reasoning about
 * skew, which is why it is not the one a scheduler should call.
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

/**
 * The sweep a scheduler should run: drops only nonces whose token the
 * verifier would already refuse.
 *
 * A nonce is safe to forget once no token bound to it can still be accepted.
 * The verifier's own boundary is `exp + APPLE_CLOCK_SKEW_SECONDS`, so the
 * sweep lags by the same amount. Sweeping earlier would delete the replay
 * protection for tokens that are still inside their accepted window — a
 * cleanup job that manufactures the exact vulnerability the table exists to
 * prevent.
 *
 * Returns how many rows it removed, so a future scheduled invocation has
 * something to report without logging any nonce.
 */
export async function purgeReplayableNonces(
	db: SqlDatabase,
	now: EpochSeconds = nowSeconds(),
	skewSeconds: EpochSeconds = APPLE_CLOCK_SKEW_SECONDS,
): Promise<number> {
	const cutoff = now - skewSeconds;
	const { results } = await db
		.prepare(`SELECT nonce_sha256 FROM auth_nonces WHERE expires_at <= ?`)
		.bind(cutoff)
		.all<{ nonce_sha256: string }>();
	if (results.length === 0) return 0;

	await db
		.prepare(`DELETE FROM auth_nonces WHERE expires_at <= ?`)
		.bind(cutoff)
		.run();
	return results.length;
}
