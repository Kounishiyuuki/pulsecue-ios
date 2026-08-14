/**
 * The per-user sync cursor.
 *
 * Every syncable row will be written with the sequence returned here, and a
 * client pulls everything above the sequence it last saw. A counter rather
 * than a timestamp: clocks skew between edge locations, and two writes in
 * the same second still have to be ordered.
 */

import type { SqlDatabase } from "../types";

/**
 * Increments and returns the user's sequence.
 *
 * The increment and the read are one statement so two concurrent writers
 * cannot be handed the same number.
 */
export async function nextChangeSeq(
	db: SqlDatabase,
	userId: string,
): Promise<number> {
	const row = await db
		.prepare(
			`UPDATE user_change_seq SET seq = seq + 1 WHERE user_id = ? RETURNING seq`,
		)
		.bind(userId)
		.first<{ seq: number }>();
	if (!row) throw new MissingChangeSequenceError(userId);
	return row.seq;
}

/**
 * The user's current sequence.
 *
 * A freshly created account legitimately sits at 0. A *missing* row does
 * not: account creation writes it in the same batch as the user, so its
 * absence means the account is malformed. Returning 0 for both would hide
 * that behind a plausible-looking answer and let a client sync against a
 * cursor that was never initialised, so the two are separated.
 */
export async function currentChangeSeq(
	db: SqlDatabase,
	userId: string,
): Promise<number> {
	const row = await db
		.prepare(`SELECT seq FROM user_change_seq WHERE user_id = ?`)
		.bind(userId)
		.first<{ seq: number }>();
	if (!row) throw new MissingChangeSequenceError(userId);
	return row.seq;
}

/** No sync cursor exists for this user — the account row set is incomplete. */
export class MissingChangeSequenceError extends Error {
	constructor(readonly userId: string) {
		super(`no change sequence row for user ${userId}`);
		this.name = "MissingChangeSequenceError";
	}
}
