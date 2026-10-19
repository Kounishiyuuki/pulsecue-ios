/**
 * Single-use enforcement for sign-in nonces.
 *
 * `verifyAppleIdentityToken` proves a token is bound to a nonce. This makes
 * that nonce usable exactly once, which is what stops a captured request
 * body from being replayed for the rest of the token's lifetime.
 */

import type { AuthProvider, EpochSeconds, SqlDatabase } from "../types";
import { APPLE_CLOCK_SKEW_SECONDS } from "../auth/apple";
import { changedRows } from "./changes";
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

/** Rows a single scheduled sweep may remove; any backlog waits for the next run. */
export const NONCE_PURGE_BATCH_LIMIT = 500;

/**
 * The sweep a scheduler should run: drops only nonces whose token the
 * verifier would already refuse.
 *
 * **The retention boundary is not `expires_at`.** Verification accepts a
 * token until `exp + APPLE_CLOCK_SKEW_SECONDS`, so deleting the row the
 * instant `expires_at` passes opens a window in which the token is still
 * accepted but its nonce is gone — a cleanup job that manufactures the exact
 * vulnerability the table exists to prevent. The sweep lags by the same skew
 * the verifier applies.
 *
 * Bounded to `limit` rows in one statement, oldest first. D1 has no
 * `DELETE … LIMIT`, so the bound lives in an indexed subquery; no nonce hash
 * is ever read into the Worker. Returns how many rows the DELETE actually
 * removed, so a scheduled run has something to report without logging any
 * nonce.
 */
export async function purgeReplayableNonces(
	db: SqlDatabase,
	now: EpochSeconds = nowSeconds(),
	skewSeconds: EpochSeconds = APPLE_CLOCK_SKEW_SECONDS,
	limit: number = NONCE_PURGE_BATCH_LIMIT,
): Promise<number> {
	const cutoff = now - skewSeconds;
	const result = await db
		.prepare(
			`DELETE FROM auth_nonces
			  WHERE rowid IN (
			    SELECT rowid FROM auth_nonces
			     WHERE expires_at <= ?
			     ORDER BY expires_at ASC
			     LIMIT ?
			  )`,
		)
		.bind(cutoff, limit)
		.run();
	return changedRows(result);
}
