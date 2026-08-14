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
	if (!row) throw new Error(`no change sequence row for user ${userId}`);
	return row.seq;
}

export async function currentChangeSeq(
	db: SqlDatabase,
	userId: string,
): Promise<number> {
	const row = await db
		.prepare(`SELECT seq FROM user_change_seq WHERE user_id = ?`)
		.bind(userId)
		.first<{ seq: number }>();
	return row?.seq ?? 0;
}
