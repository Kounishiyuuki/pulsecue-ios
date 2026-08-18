/**
 * The repository half of account deletion.
 *
 * Two operations matter here and both are batches, because both have a
 * half-done state that would be a real problem:
 *
 *   `requestAccountDeletion` marks the account and revokes every session in
 *   one commit. A user left `deleting` with a live session is an
 *   authentication bypass; an `active` user whose sessions were all revoked
 *   is a silent lockout. Neither is reachable if they land together.
 *
 *   `hardDeleteUser` removes the user row and lets the foreign keys take the
 *   rest. Enumerating child tables by hand is how a table added next year
 *   quietly survives a deletion.
 */

import type {
	AccountDeletionRow,
	EpochSeconds,
	SqlDatabase,
	UserRow,
} from "../types";
import { nowSeconds } from "./ids";

/** How long to wait before a processor may retry a failed revocation. */
export const DELETION_RETRY_BACKOFF_SECONDS = 15 * 60;

/**
 * Why the last attempt did not finish. A closed set, stored as-is.
 *
 * Never a provider message: those quote request bodies and identifiers, and
 * this row outlives the request that wrote it.
 */
export type DeletionErrorCode =
	| "provider_unavailable"
	| "credential_unreadable";

export async function findAccountDeletion(
	db: SqlDatabase,
	userId: string,
): Promise<AccountDeletionRow | null> {
	return db
		.prepare(`SELECT * FROM account_deletions WHERE user_id = ?`)
		.bind(userId)
		.first<AccountDeletionRow>();
}

/**
 * Starts a deletion: the account becomes `deleting`, every session is
 * revoked, and the retry row appears — all in one commit.
 *
 * Idempotent. Asking twice does not reset the attempt counter or the
 * requested-at time, because a retry of the HTTP call must not look like a
 * fresh request and restart the backoff.
 */
export async function requestAccountDeletion(
	db: SqlDatabase,
	userId: string,
	now: EpochSeconds = nowSeconds(),
): Promise<void> {
	await db.batch([
		db
			.prepare(
				`UPDATE users
				    SET state = 'deleting', deleted_at = ?, updated_at = ?
				  WHERE id = ? AND state = 'active'`,
			)
			.bind(now, now, userId),
		db
			.prepare(
				`UPDATE sessions SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL`,
			)
			.bind(now, userId),
		db
			.prepare(
				`INSERT INTO account_deletions
				   (user_id, requested_at, attempts, last_attempt_at, last_error_code, next_attempt_at)
				 VALUES (?, ?, 0, NULL, NULL, ?)
				 ON CONFLICT (user_id) DO NOTHING`,
			)
			.bind(userId, now, now),
	]);
}

/** Records a failed attempt and when the next one may run. */
export async function recordDeletionAttempt(
	db: SqlDatabase,
	userId: string,
	code: DeletionErrorCode,
	now: EpochSeconds = nowSeconds(),
	backoffSeconds: EpochSeconds = DELETION_RETRY_BACKOFF_SECONDS,
): Promise<void> {
	await db
		.prepare(
			`UPDATE account_deletions
			    SET attempts        = attempts + 1,
			        last_attempt_at = ?,
			        last_error_code = ?,
			        next_attempt_at = ?
			  WHERE user_id = ?`,
		)
		.bind(now, code, now + backoffSeconds, userId)
		.run();
}

/** Deletions whose next attempt is due. Ordered oldest-request-first. */
export async function listDueAccountDeletions(
	db: SqlDatabase,
	now: EpochSeconds = nowSeconds(),
	limit = 50,
): Promise<AccountDeletionRow[]> {
	const { results } = await db
		.prepare(
			`SELECT * FROM account_deletions
			  WHERE next_attempt_at <= ?
			  ORDER BY requested_at ASC
			  LIMIT ?`,
		)
		.bind(now, limit)
		.all<AccountDeletionRow>();
	return results;
}

/**
 * Removes the user and everything hanging off it.
 *
 * One statement. `auth_identities`, `user_profiles`, `sessions`,
 * `user_change_seq`, `provider_credentials` (through the identity) and this
 * deletion row all carry `ON DELETE CASCADE`, so the database decides what
 * belongs to a user rather than a list in this file that someone has to
 * remember to update. A test asserts nothing is left behind and that another
 * user is untouched.
 *
 * `auth_nonces` is deliberately not swept: it is keyed by a nonce hash and
 * has no owner, so there is nothing there that belongs to this user.
 */
export async function hardDeleteUser(
	db: SqlDatabase,
	userId: string,
): Promise<void> {
	await db.prepare(`DELETE FROM users WHERE id = ?`).bind(userId).run();
}

/** The user, if it still exists. Used to tell "gone" from "still pending". */
export async function findUserForDeletion(
	db: SqlDatabase,
	userId: string,
): Promise<UserRow | null> {
	return db
		.prepare(`SELECT * FROM users WHERE id = ?`)
		.bind(userId)
		.first<UserRow>();
}
