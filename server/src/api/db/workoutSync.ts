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

/**
 * The most rows one upload may write, sessions and step results together.
 *
 * A combined cap, not one per table. The two independent 500s it replaced
 * allowed 1000 mutations in a request, and D1 meters **every statement in a
 * batch** against its 1000-queries-per-invocation limit — so the largest
 * previously-valid upload issued at least 1002 statements in the batch alone
 * and would have been refused by the platform, after the client had already
 * been told the size was acceptable.
 *
 * Worst case at this cap, counted rather than estimated:
 *
 *   session middleware                                     2
 *   step-result session preflight    ceil(500/90)           6
 *   tombstone preflight (both tables, <= 500 ids)           7
 *   batch: sequence bump + 500 mutations + final read     502
 *                                                       -----
 *                                                         517
 *
 * Comfortably under 1000, with room for a query someone adds later without
 * recounting. `MAX_SYNC_ROWS_PER_SEQUENCE` must stay >= this number; a test
 * pins that relationship rather than leaving it to a comment.
 */
export const MAX_SYNC_MUTATIONS_PER_REQUEST = 500;

/**
 * Ids per `IN (...)` lookup.
 *
 * D1 allows at most 100 bind parameters per query. Each preflight binds the
 * user id plus one parameter per record id, so 90 leaves clear headroom and
 * no query in this file can reach the limit.
 */
export const SYNC_ID_CHUNK_SIZE = 90;

/**
 * The most rows that may share a single sequence, per table.
 *
 * Bounded by the write side: one upload writes at most
 * `MAX_SYNC_MUTATIONS_PER_REQUEST` rows and they all share one sequence, so
 * no legitimately-written sequence can exceed this. The pull path treats a
 * larger one as corruption rather than as something to truncate.
 */
export const MAX_SYNC_ROWS_PER_SEQUENCE = 500;

export class SyncOwnershipError extends Error {
	constructor(reason: string) {
		super(`sync rejected: ${reason}`);
		this.name = "SyncOwnershipError";
	}
}

/** The payload exceeds `MAX_SYNC_MUTATIONS_PER_REQUEST`. */
export class SyncPayloadTooLargeError extends Error {
	constructor() {
		super("sync rejected: too many records in one request");
		this.name = "SyncPayloadTooLargeError";
	}
}

/**
 * The same id appears twice in one request.
 *
 * Refused rather than resolved. Letting it through would make the outcome
 * depend on the order the statements happen to run in, which is not something
 * a client can predict or a reviewer can reason about.
 */
export class SyncDuplicateIdError extends Error {
	constructor() {
		super("sync rejected: duplicate id in one request");
		this.name = "SyncDuplicateIdError";
	}
}

/** A live upload targets a record the server has already tombstoned. */
export class SyncTombstonedError extends Error {
	constructor() {
		super("sync rejected: record was deleted");
		this.name = "SyncTombstonedError";
	}
}

/**
 * The account stopped being active. Raised when the database refuses a write,
 * or when a read finds the account already on its way out.
 */
export class SyncAccountNotActiveError extends Error {
	constructor() {
		super("sync rejected: account is not active");
		this.name = "SyncAccountNotActiveError";
	}
}

/**
 * A stored sequence holds more rows than any upload could have written.
 *
 * Never expected. It is raised rather than worked around because every way of
 * "handling" it loses data: truncating the sequence and advancing the cursor
 * past it drops the remainder permanently, which is strictly worse than a
 * sync that fails loudly and can be retried once the data is repaired.
 */
export class SyncCorruptSequenceError extends Error {
	constructor() {
		super("sync failed: a change sequence is larger than the write limit");
		this.name = "SyncCorruptSequenceError";
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
 *
 * Every invariant below is enforced *here*, not only in the route. The route
 * is one caller; a migration script, a future endpoint or a test helper are
 * others, and an oversized batch written by any of them would produce a
 * sequence the pull path cannot deliver — permanent, silent data loss for
 * that user. Making the repository the place the rules live means there is no
 * way in that skips them.
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

	assertWithinRequestLimit(sessions, stepResults);
	assertNoDuplicateIds(sessions, stepResults);

	if (sessions.length === 0 && stepResults.length === 0) {
		// Nothing to publish, so nothing to advance. Bumping the sequence for
		// an empty upload would hand every other device a cursor move with no
		// rows behind it. The account is still checked: an empty upload from a
		// deleting account is not a success.
		return {
			changeSeq: await activeUserChangeSeq(db, userId),
			sessions: 0,
			stepResults: 0,
		};
	}

	// A step result whose session is neither in this payload nor already
	// stored would be rejected by the foreign key mid-batch. Catching it here
	// makes it a clear 4xx instead of an opaque constraint failure.
	await assertSessionsResolvable(db, userId, sessions, stepResults);

	// A tombstone is terminal. Detected up front so the client is told its
	// upload was refused, rather than having the database abort the batch and
	// the request fail as an opaque error.
	await assertNoTombstoneResurrection(db, userId, sessions, stepResults);

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

	// The sequence this upload used, read inside the same transaction as the
	// writes.
	//
	// It used to be a separate `SELECT` after the batch committed, which
	// returned whatever the sequence had become — including a *different*
	// upload's. The client stored that as its cursor and never asked for the
	// other upload's rows again. Reading it here means the number returned is
	// this request's own, whatever else commits around it.
	statements.push(
		db
			.prepare(`SELECT seq FROM user_change_seq WHERE user_id = ?`)
			.bind(userId),
	);

	let batchResults: { results: unknown[] }[];
	try {
		batchResults = (await db.batch<{ seq: number }>(statements)) as unknown as {
			results: unknown[];
		}[];
	} catch (error) {
		throw translateWriteAbort(error);
	}

	const changeSeq = readSequenceFromBatch(batchResults);

	return {
		changeSeq,
		sessions: sessions.length,
		stepResults: stepResults.length,
	};
}

function assertWithinRequestLimit(
	sessions: WorkoutSessionInput[],
	stepResults: StepResultInput[],
): void {
	if (sessions.length + stepResults.length > MAX_SYNC_MUTATIONS_PER_REQUEST) {
		throw new SyncPayloadTooLargeError();
	}
}

/**
 * Refuses a request that names the same record twice.
 *
 * Sessions and step results are separate id spaces — a session and a step
 * result may legitimately share an id — so they are checked separately.
 */
function assertNoDuplicateIds(
	sessions: WorkoutSessionInput[],
	stepResults: StepResultInput[],
): void {
	if (new Set(sessions.map((row) => row.id)).size !== sessions.length) {
		throw new SyncDuplicateIdError();
	}
	if (new Set(stepResults.map((row) => row.id)).size !== stepResults.length) {
		throw new SyncDuplicateIdError();
	}
}

/**
 * Turns a trigger's `RAISE(ABORT, ...)` into the error the caller expects.
 *
 * The database is the authority on both of these — it checks them inside the
 * transaction, where there is no window to lose a race in — so the message it
 * raises is the honest source of the refusal, even when a preflight above was
 * supposed to have caught it first.
 */
function translateWriteAbort(error: unknown): Error {
	const message = error instanceof Error ? error.message : String(error);
	if (message.includes("sync_user_not_active")) {
		return new SyncAccountNotActiveError();
	}
	if (message.includes("sync_tombstone_is_terminal")) {
		return new SyncTombstonedError();
	}
	return error instanceof Error ? error : new Error(message);
}

/** Pulls the sequence out of the batch's final statement. */
function readSequenceFromBatch(
	batchResults: { results: unknown[] }[],
): number {
	const last = batchResults[batchResults.length - 1];
	const row = last?.results?.[0] as { seq?: number } | undefined;
	if (typeof row?.seq !== "number") {
		// The batch committed but did not report the sequence back. Returning
		// a guess would hand the client a cursor that may skip rows, so this
		// fails instead.
		throw new Error("sync failed: upload did not report its sequence");
	}
	return row.seq;
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

/** Splits ids so no query exceeds D1's 100-bind-parameter limit. */
function chunkIds(ids: string[]): string[][] {
	const chunks: string[][] = [];
	for (let index = 0; index < ids.length; index += SYNC_ID_CHUNK_SIZE) {
		chunks.push(ids.slice(index, index + SYNC_ID_CHUNK_SIZE));
	}
	return chunks;
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

	const known = new Set<string>();
	// Chunked: a single `IN (...)` over a full payload would bind more
	// parameters than D1 accepts, and the request would fail on the platform
	// while passing every local test that used plain SQLite.
	for (const chunk of chunkIds(missing)) {
		const { results } = await db
			.prepare(
				`SELECT id FROM workout_sessions
				  WHERE user_id = ? AND id IN (${chunk.map(() => "?").join(", ")})`,
			)
			.bind(userId, ...chunk)
			.all<{ id: string }>();
		for (const row of results) known.add(row.id);
	}

	if (missing.some((id) => !known.has(id))) {
		// No id is quoted: a client should not learn whether a session id
		// exists for somebody else.
		throw new SyncOwnershipError("a step result names an unknown session");
	}
}

/**
 * Refuses an upload that would bring a deleted record back.
 *
 * The v1 conflict policy is that a tombstone is terminal. A client composes
 * an upload, another device deletes one of those records, and the upload
 * arrives still carrying it as live — a plain upsert would clear
 * `deleted_at`, and because the resurrection gets its own sequence, every
 * device would then pull the record back. The delete would simply undo
 * itself, with nothing anywhere reporting a problem.
 *
 * Re-sending the *same* delete is not affected: only rows arriving as live
 * are checked. A record that genuinely needs to come back gets a new id.
 *
 * The database enforces this too, in a trigger. This preflight exists so the
 * client gets a specific, actionable refusal instead of an aborted batch.
 */
async function assertNoTombstoneResurrection(
	db: SqlDatabase,
	userId: string,
	sessions: WorkoutSessionInput[],
	stepResults: StepResultInput[],
): Promise<void> {
	const liveSessions = sessions.filter((row) => !row.deleted).map((row) => row.id);
	const liveSteps = stepResults.filter((row) => !row.deleted).map((row) => row.id);

	if (await anyTombstoned(db, "workout_sessions", userId, liveSessions)) {
		throw new SyncTombstonedError();
	}
	if (await anyTombstoned(db, "step_results", userId, liveSteps)) {
		throw new SyncTombstonedError();
	}
}

async function anyTombstoned(
	db: SqlDatabase,
	table: "workout_sessions" | "step_results",
	userId: string,
	ids: string[],
): Promise<boolean> {
	if (ids.length === 0) return false;

	for (const chunk of chunkIds([...new Set(ids)])) {
		// The table name is a literal union, never caller input.
		const { results } = await db
			.prepare(
				`SELECT id FROM ${table}
				  WHERE user_id = ?
				    AND deleted_at IS NOT NULL
				    AND id IN (${chunk.map(() => "?").join(", ")})
				  LIMIT 1`,
			)
			.bind(userId, ...chunk)
			.all<{ id: string }>();
		if (results.length > 0) return true;
	}
	return false;
}

/**
 * The one condition that decides whether an account may sync.
 *
 * A function rather than a string so every caller spells it the same way. The
 * middleware asks the same question earlier, and two places drifting apart on
 * what "active" means is how a deleting account ends up served.
 */
function activeUser(alias: string): string {
	return `${alias}.state = 'active'`;
}

/**
 * Refuses unless the account is active *right now*.
 *
 * Used as the last thing a pull does. A pull is several queries, and D1 does
 * not run them in one read transaction, so an account deletion committing
 * between two of them yields a page assembled from two different worlds —
 * sessions from before, step results from after. Returning that with a 200
 * tells the client it is caught up, when what it actually has is half of a
 * deleted account's data.
 *
 * An absent row counts as not active: a hard delete has already removed it,
 * and there is no path in this schema that puts an account back to 'active',
 * so absence is terminal rather than transient.
 */
async function assertAccountActive(
	db: SqlDatabase,
	userId: string,
): Promise<void> {
	const row = await db
		.prepare(
			`SELECT 1 AS ok FROM users AS u WHERE u.id = ? AND ${activeUser("u")}`,
		)
		.bind(userId)
		.first<{ ok: number }>();

	if (!row) throw new SyncAccountNotActiveError();
}

/**
 * This user's current sequence, readable only while the account is active.
 *
 * The session middleware already checked the account, but that was a
 * different query at an earlier moment: another request can move the account
 * to `deleting` in between, and a read that trusted the earlier answer would
 * hand a deleting account its data. Joining `users` here asks the question at
 * the moment the answer is used.
 */
async function activeUserChangeSeq(
	db: SqlDatabase,
	userId: string,
): Promise<number> {
	const row = await db
		.prepare(
			`SELECT s.seq AS seq
			   FROM user_change_seq AS s
			   JOIN users AS u ON u.id = s.user_id
			  WHERE s.user_id = ? AND ${activeUser("u")}`,
		)
		.bind(userId)
		.first<{ seq: number }>();

	if (!row) {
		// Either the account is no longer active, or it has no sequence row.
		// Both are refusals here; neither may be reported as "no changes".
		throw new SyncAccountNotActiveError();
	}
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
 * Everything is read against one snapshot sequence, captured up front. Both
 * tables and the cursor therefore describe the same instant: a write that
 * lands while the page is being assembled is excluded from *all* of it, and
 * arrives whole on the next pull rather than being half-included in this one
 * with a cursor that has already moved past it.
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
	// Throws if the account is no longer active, so a deletion that started
	// after the middleware ran cannot be served a page of data.
	const snapshotSeq = await activeUserChangeSeq(db, userId);

	const sessions = await readPage<WorkoutSessionRow>(
		db,
		"workout_sessions",
		userId,
		sinceSeq,
		limit,
		snapshotSeq,
	);
	const stepResults = await readPage<StepResultRow>(
		db,
		"step_results",
		userId,
		sinceSeq,
		limit,
		snapshotSeq,
	);

	// The two tables paginate independently, so the cursor is the lower of the
	// two. Re-reading a few rows on the next pull is harmless — the client
	// applies them idempotently — whereas skipping any is not.
	const changeSeq = Math.min(sessions.cursor, stepResults.cursor);
	const hasMore = changeSeq < snapshotSeq;

	// Last, after every value this response would carry has been read.
	//
	// The per-query guards above are not enough on their own: they make each
	// query individually refuse a deleting account, but the queries run at
	// different moments. A deletion committing between them leaves the earlier
	// results in hand and the later ones empty — a page that is internally
	// inconsistent and, returned as 200, indistinguishable from "you are up to
	// date". This throws instead, and because it throws before the object
	// below is built, nothing read so far escapes: no rows, no cursor, no
	// `hasMore` for the client to act on.
	await assertAccountActive(db, userId);

	return {
		sessions: sessions.rows,
		stepResults: stepResults.rows,
		changeSeq,
		hasMore,
	};
}

/**
 * Reads one page and works out how far the client may advance.
 *
 * Fetches `limit + 1` rows: if the extra one exists the page was cut short,
 * and every row sharing the excluded row's sequence is dropped so no sequence
 * is ever delivered in halves.
 *
 * Every query is bounded above by `snapshotSeq` and joined to an active
 * `users` row, so neither a concurrent write nor a deletion starting midway
 * can change what this page contains.
 */
async function readPage<T extends { change_seq: number }>(
	db: SqlDatabase,
	table: "workout_sessions" | "step_results",
	userId: string,
	sinceSeq: number,
	limit: number,
	snapshotSeq: number,
): Promise<{ rows: T[]; cursor: number }> {
	// The table name is a literal union, never caller input.
	const pageSql = `SELECT t.* FROM ${table} AS t
		  JOIN users AS u ON u.id = t.user_id
		  WHERE t.user_id = ?
		    AND ${activeUser("u")}
		    AND t.change_seq > ?
		    AND t.change_seq <= ?
		  ORDER BY t.change_seq ASC, t.id ASC
		  LIMIT ?`;

	const { results } = await db
		.prepare(pageSql)
		.bind(userId, sinceSeq, snapshotSeq, limit + 1)
		.all<T>();

	if (results.length <= limit) {
		// Everything above `sinceSeq` and within the snapshot fits, so the
		// client is caught up to the snapshot — not to "now", which may
		// already be further along.
		return { rows: results, cursor: snapshotSeq };
	}

	// Truncated. The first excluded row names the sequence that is only
	// partially covered; drop it entirely and stop just below it.
	const firstExcludedSeq = (results[limit] as T).change_seq;
	const rows = results.slice(0, limit).filter(
		(row) => row.change_seq < firstExcludedSeq,
	);

	if (rows.length > 0) {
		return { rows, cursor: firstExcludedSeq - 1 };
	}

	// Nothing survived the filter: this single sequence is larger than the
	// page. Returning the empty page would leave the cursor exactly where it
	// was and the client would ask the same question forever, so the sequence
	// is delivered whole instead — over the page limit, deliberately.
	//
	// It is read one row past `MAX_SYNC_ROWS_PER_SEQUENCE` to tell "large" from
	// "impossible". No upload can write more than that at one sequence, so more
	// than that means the data is not what the write path can produce. The
	// tempting response — return the first N and move the cursor past the
	// sequence — destroys the remainder permanently and reports success while
	// doing it. Failing the pull leaves every row exactly where it is and the
	// cursor untouched, so nothing is lost and a retry works once the data is
	// repaired.
	const whole = await db
		.prepare(
			`SELECT t.* FROM ${table} AS t
			   JOIN users AS u ON u.id = t.user_id
			  WHERE t.user_id = ?
			    AND ${activeUser("u")}
			    AND t.change_seq = ?
			  ORDER BY t.id ASC
			  LIMIT ?`,
		)
		.bind(userId, firstExcludedSeq, MAX_SYNC_ROWS_PER_SEQUENCE + 1)
		.all<T>();

	if (whole.results.length > MAX_SYNC_ROWS_PER_SEQUENCE) {
		throw new SyncCorruptSequenceError();
	}

	return { rows: whole.results, cursor: firstExcludedSeq };
}
