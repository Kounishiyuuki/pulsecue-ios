/**
 * Uploading workout sessions and step results.
 *
 * The whole file is really about one guarantee: **the sequence and the rows
 * move together.** A previous note in this repo flagged the danger — writing
 * a synced row in one commit and bumping `user_change_seq` in another means a
 * reader can observe a sequence with no rows behind it, or rows a pull will
 * never return because the cursor never advanced past them. Both are silent
 * data loss from the user's point of view.
 *
 * So an upload is exactly one `db.batch()`:
 *
 *   1. `UPDATE user_change_seq SET seq = seq + 1`
 *   2. every row INSERTed with `change_seq = (SELECT seq FROM user_change_seq …)`
 *
 * Statement 1 runs first inside the transaction, so the subquery in the rest
 * reads the *new* value. If any statement fails, D1 rolls the whole batch
 * back and neither the sequence nor a single row moved.
 *
 * Everything is scoped by `user_id` from the authenticated session — never
 * from the request body. Combined with the `(user_id, id)` primary key, a
 * client cannot reach another user's row even by sending their UUID.
 */

import type {
	EpochSeconds,
	SqlDatabase,
	SqlStatement,
	StepResultRow,
	WorkoutSessionRow,
} from "../types";
import { nowSeconds } from "./ids";

export interface WorkoutSessionInput {
	id: string;
	startedAt: EpochSeconds;
	endedAt?: EpochSeconds | null;
	title?: string | null;
	deleted?: boolean;
}

export interface StepResultInput {
	id: string;
	sessionId: string;
	exerciseName: string;
	orderIndex: number;
	reps?: number | null;
	weightKg?: number | null;
	durationSeconds?: number | null;
	completedAt?: EpochSeconds | null;
	deleted?: boolean;
}

export interface UploadResult {
	/** The sequence every row in this upload was written at. */
	changeSeq: number;
	sessions: number;
	stepResults: number;
}

export class SyncOwnershipError extends Error {
	constructor(reason: string) {
		super(`sync rejected: ${reason}`);
		this.name = "SyncOwnershipError";
	}
}

/**
 * Writes an upload, atomically, and returns the sequence it landed at.
 *
 * Idempotent by construction: a retry of the same payload upserts onto the
 * same `(user_id, id)` rows, so the content converges and no duplicate
 * appears. The sequence advances on each attempt, which is correct — the rows
 * really were written again, and a pull cursor that skipped them would be the
 * bug.
 */
export async function uploadWorkoutData(
	db: SqlDatabase,
	userId: string,
	payload: {
		sessions: WorkoutSessionInput[];
		stepResults: StepResultInput[];
	},
	now: EpochSeconds = nowSeconds(),
): Promise<UploadResult> {
	const { sessions, stepResults } = payload;

	if (sessions.length === 0 && stepResults.length === 0) {
		// Nothing to publish, so nothing to advance. Bumping the sequence for
		// an empty upload would hand every other device a cursor move with no
		// rows behind it.
		return { changeSeq: await currentChangeSeq(db, userId), sessions: 0, stepResults: 0 };
	}

	// A step result whose session is neither in this payload nor already
	// stored would be rejected by the foreign key mid-batch. Catching it here
	// makes it a clear 4xx instead of an opaque constraint failure.
	await assertSessionsResolvable(db, userId, sessions, stepResults);

	const statements: SqlStatement[] = [
		// First, and inside the same transaction as everything below.
		db
			.prepare(`UPDATE user_change_seq SET seq = seq + 1 WHERE user_id = ?`)
			.bind(userId),
	];

	for (const session of sessions) {
		statements.push(sessionUpsert(db, userId, session, now));
	}
	for (const result of stepResults) {
		statements.push(stepResultUpsert(db, userId, result, now));
	}

	await db.batch(statements);

	return {
		changeSeq: await currentChangeSeq(db, userId),
		sessions: sessions.length,
		stepResults: stepResults.length,
	};
}

/** The sequence a `SELECT` subquery inside the batch will read. */
const NEXT_SEQ = `(SELECT seq FROM user_change_seq WHERE user_id = ?)`;

function sessionUpsert(
	db: SqlDatabase,
	userId: string,
	session: WorkoutSessionInput,
	now: EpochSeconds,
): SqlStatement {
	return db
		.prepare(
			`INSERT INTO workout_sessions
			   (id, user_id, started_at, ended_at, title, change_seq, updated_at, deleted_at)
			 VALUES (?, ?, ?, ?, ?, ${NEXT_SEQ}, ?, ?)
			 ON CONFLICT (user_id, id) DO UPDATE SET
			   started_at = excluded.started_at,
			   ended_at   = excluded.ended_at,
			   title      = excluded.title,
			   change_seq = excluded.change_seq,
			   updated_at = excluded.updated_at,
			   deleted_at = excluded.deleted_at`,
		)
		.bind(
			session.id,
			userId,
			session.startedAt,
			session.endedAt ?? null,
			session.title ?? null,
			userId,
			now,
			session.deleted ? now : null,
		);
}

function stepResultUpsert(
	db: SqlDatabase,
	userId: string,
	result: StepResultInput,
	now: EpochSeconds,
): SqlStatement {
	return db
		.prepare(
			`INSERT INTO step_results
			   (id, user_id, session_id, exercise_name, order_index, reps, weight_kg,
			    duration_seconds, completed_at, change_seq, updated_at, deleted_at)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ${NEXT_SEQ}, ?, ?)
			 ON CONFLICT (user_id, id) DO UPDATE SET
			   session_id       = excluded.session_id,
			   exercise_name    = excluded.exercise_name,
			   order_index      = excluded.order_index,
			   reps             = excluded.reps,
			   weight_kg        = excluded.weight_kg,
			   duration_seconds = excluded.duration_seconds,
			   completed_at     = excluded.completed_at,
			   change_seq       = excluded.change_seq,
			   updated_at       = excluded.updated_at,
			   deleted_at       = excluded.deleted_at`,
		)
		.bind(
			result.id,
			userId,
			result.sessionId,
			result.exerciseName,
			result.orderIndex,
			result.reps ?? null,
			result.weightKg ?? null,
			result.durationSeconds ?? null,
			result.completedAt ?? null,
			userId,
			now,
			result.deleted ? now : null,
		);
}

/**
 * Every step result must land on a session this user owns — one in the same
 * payload, or one already stored.
 *
 * The foreign key already guarantees it; this only turns the failure into a
 * legible one. Note it can never *widen* what is allowed: the lookup is
 * scoped to `user_id`, so a session id belonging to someone else is not
 * found, and the row is refused exactly as the constraint would have refused
 * it.
 */
async function assertSessionsResolvable(
	db: SqlDatabase,
	userId: string,
	sessions: WorkoutSessionInput[],
	stepResults: StepResultInput[],
): Promise<void> {
	if (stepResults.length === 0) return;

	const incoming = new Set(sessions.map((session) => session.id));
	const missing = [
		...new Set(
			stepResults
				.map((result) => result.sessionId)
				.filter((id) => !incoming.has(id)),
		),
	];
	if (missing.length === 0) return;

	const { results } = await db
		.prepare(
			`SELECT id FROM workout_sessions
			  WHERE user_id = ? AND id IN (${missing.map(() => "?").join(", ")})`,
		)
		.bind(userId, ...missing)
		.all<{ id: string }>();

	const known = new Set(results.map((row) => row.id));
	if (missing.some((id) => !known.has(id))) {
		// No id is quoted: a client should not learn whether a session id
		// exists for somebody else.
		throw new SyncOwnershipError("a step result names an unknown session");
	}
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

/**
 * Everything of this user's written after `sinceSeq`, oldest first.
 *
 * The returned `changeSeq` is a **cursor the client may safely store**, and
 * getting that right is the whole subtlety here. An earlier version returned
 * the user's current sequence regardless of how much it had actually sent —
 * so a pull that hit the row limit told the client "you are up to date at
 * seq N" while silently withholding rows below N. The client would store N,
 * never ask for them again, and lose them permanently.
 *
 * Now a page that is cut short reports the last sequence it delivered
 * *completely*, and says there is more. Rows are read one past the limit to
 * detect truncation, and any partially-delivered sequence is dropped rather
 * than half-sent.
 *
 * Progress is guaranteed because one upload batch writes at most `MAX_ROWS`
 * rows per table at a single sequence, and the page limit is the same number:
 * a single sequence therefore always fits, so the cursor always advances.
 */
export async function pullWorkoutData(
	db: SqlDatabase,
	userId: string,
	sinceSeq: number,
	limit = 500,
): Promise<{
	sessions: WorkoutSessionRow[];
	stepResults: StepResultRow[];
	changeSeq: number;
	hasMore: boolean;
}> {
	const currentSeq = await currentChangeSeq(db, userId);

	const sessions = await readPage<WorkoutSessionRow>(
		db,
		`SELECT * FROM workout_sessions
		  WHERE user_id = ? AND change_seq > ?
		  ORDER BY change_seq ASC, id ASC
		  LIMIT ?`,
		userId,
		sinceSeq,
		limit,
		currentSeq,
	);
	const stepResults = await readPage<StepResultRow>(
		db,
		`SELECT * FROM step_results
		  WHERE user_id = ? AND change_seq > ?
		  ORDER BY change_seq ASC, id ASC
		  LIMIT ?`,
		userId,
		sinceSeq,
		limit,
		currentSeq,
	);

	// The two tables paginate independently, so the cursor is the lower of the
	// two. Re-reading a few rows on the next pull is harmless — the client
	// applies them idempotently — whereas skipping any is not.
	const changeSeq = Math.min(sessions.cursor, stepResults.cursor);

	return {
		sessions: sessions.rows,
		stepResults: stepResults.rows,
		changeSeq,
		hasMore: changeSeq < currentSeq,
	};
}

/**
 * Reads one page and works out how far the client may advance.
 *
 * Fetches `limit + 1` rows: if the extra one exists the page was cut short,
 * and every row sharing the excluded row's sequence is dropped so no sequence
 * is ever delivered in halves.
 */
async function readPage<T extends { change_seq: number }>(
	db: SqlDatabase,
	sql: string,
	userId: string,
	sinceSeq: number,
	limit: number,
	currentSeq: number,
): Promise<{ rows: T[]; cursor: number }> {
	const { results } = await db
		.prepare(sql)
		.bind(userId, sinceSeq, limit + 1)
		.all<T>();

	if (results.length <= limit) {
		// Everything above `sinceSeq` fits, so the client is caught up to the
		// user's current sequence.
		return { rows: results, cursor: currentSeq };
	}

	// Truncated. The first excluded row names the sequence that is only
	// partially covered; drop it entirely and stop just below it.
	const firstExcludedSeq = (results[limit] as T).change_seq;
	const rows = results.slice(0, limit).filter(
		(row) => row.change_seq < firstExcludedSeq,
	);
	return { rows, cursor: firstExcludedSeq - 1 };
}
