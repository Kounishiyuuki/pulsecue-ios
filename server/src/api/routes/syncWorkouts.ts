/**
 * `POST /v1/sync/workouts` and `GET /v1/sync/workouts`.
 *
 * The first sync slice, and the endpoint a Guest→account migration uploads
 * through.
 *
 * What this is **not**: full multi-device sync. There is no conflict
 * resolution beyond last-write-wins per record, and no client has ever pulled
 * from it. Calling it "同期完了" in the UI would be a promise a user only
 * discovers is false when they lose a phone — the honest description is an
 * account migration and a first backup slice.
 *
 * The user comes from the authenticated session and nowhere else. There is no
 * user id in the request body to tamper with, and the `(user_id, id)` primary
 * key means even a replayed UUID from another account lands on this user's
 * own row rather than someone else's.
 */

import type { Context } from "hono";
import { z } from "zod";
import { newId } from "../db/ids";
import {
	MAX_SYNC_MUTATIONS_PER_REQUEST,
	SyncAccountNotActiveError,
	SyncCorruptSequenceError,
	SyncDuplicateIdError,
	SyncOwnershipError,
	SyncPayloadTooLargeError,
	SyncTombstonedError,
	pullWorkoutData,
	uploadWorkoutData,
} from "../db/workoutSync";
import type { AuthedEnv } from "../types";

/**
 * The page size for a pull, and the per-array ceiling for an upload.
 *
 * The real upload limit is `MAX_SYNC_MUTATIONS_PER_REQUEST`, applied to the
 * two arrays *combined* below and again in the repository. This per-array
 * bound only stops an absurd body being parsed at all.
 */
const MAX_ROWS = MAX_SYNC_MUTATIONS_PER_REQUEST;

const sessionSchema = z.object({
	id: z.string().min(1).max(64),
	startedAt: z.number().int(),
	endedAt: z.number().int().nullish(),
	title: z.string().max(200).nullish(),
	deleted: z.boolean().optional(),
});

const stepResultSchema = z.object({
	id: z.string().min(1).max(64),
	sessionId: z.string().min(1).max(64),
	exerciseName: z.string().min(1).max(200),
	orderIndex: z.number().int().min(0).max(10_000),
	reps: z.number().int().min(0).max(10_000).nullish(),
	weightKg: z.number().min(0).max(10_000).nullish(),
	durationSeconds: z.number().int().min(0).max(86_400).nullish(),
	completedAt: z.number().int().nullish(),
	deleted: z.boolean().optional(),
});

const uploadSchema = z
	.object({
		sessions: z.array(sessionSchema).max(MAX_ROWS).default([]),
		stepResults: z.array(stepResultSchema).max(MAX_ROWS).default([]),
	})
	// Combined, because D1 meters every statement in a batch against its
	// per-invocation query limit — and two independent 500s let a request ask
	// for a batch the platform would refuse after we had accepted it.
	.refine(
		(body) =>
			body.sessions.length + body.stepResults.length <=
			MAX_SYNC_MUTATIONS_PER_REQUEST,
		{ message: "too many records in one request" },
	);

export function makeUploadWorkoutsHandler(deps: { now?: () => number } = {}) {
	return async (c: Context<AuthedEnv>) => {
		const user = c.get("user");
		const now = deps.now?.() ?? Math.floor(Date.now() / 1000);
		const correlationId = newId();

		const parsed = uploadSchema.safeParse(await readJson(c));
		if (!parsed.success) {
			return reject(c, correlationId, "malformed_request", 400);
		}

		try {
			const result = await uploadWorkoutData(
				c.env.DB,
				user.id,
				{
					sessions: parsed.data.sessions,
					stepResults: parsed.data.stepResults,
				},
				now,
			);
			return c.json(result);
		} catch (error) {
			if (error instanceof SyncOwnershipError) {
				// The payload references a session this user does not have. No
				// id is echoed: a client should not learn whether one exists
				// for somebody else.
				return reject(c, correlationId, "unknown_session", 400);
			}
			if (error instanceof SyncPayloadTooLargeError) {
				return reject(c, correlationId, "too_many_records", 400);
			}
			if (error instanceof SyncDuplicateIdError) {
				return reject(c, correlationId, "duplicate_id", 400);
			}
			if (error instanceof SyncTombstonedError) {
				// Distinct from a malformed request: the payload was
				// well-formed and the server refused it. A client that keeps
				// retrying an unchanged body needs to be told *why* it will
				// never be accepted.
				return conflict(c, correlationId);
			}
			if (error instanceof SyncAccountNotActiveError) {
				return accountGone(c, correlationId);
			}
			throw error;
		}
	};
}

export async function handlePullWorkouts(c: Context<AuthedEnv>) {
	const user = c.get("user");
	const raw = c.req.query("since") ?? "0";
	const since = Number(raw);
	if (!Number.isInteger(since) || since < 0) {
		return reject(c, newId(), "malformed_request", 400);
	}

	let data: Awaited<ReturnType<typeof pullWorkoutData>>;
	try {
		data = await pullWorkoutData(c.env.DB, user.id, since, MAX_ROWS);
	} catch (error) {
		if (error instanceof SyncAccountNotActiveError) {
			// The account started deleting after this request was
			// authenticated. It gets no data, and no partially-successful page.
			return accountGone(c, newId());
		}
		if (error instanceof SyncCorruptSequenceError) {
			// Fail closed. The alternative is a page that silently drops rows
			// and a cursor that moves past them, which loses them for good.
			return unavailable(c, newId());
		}
		throw error;
	}

	return c.json({
		changeSeq: data.changeSeq,
		// True when the page was cut short: the cursor above is safe to store,
		// but the client should pull again rather than assume it is caught up.
		hasMore: data.hasMore,
		sessions: data.sessions.map((row) => ({
			id: row.id,
			startedAt: row.started_at,
			endedAt: row.ended_at,
			title: row.title,
			changeSeq: row.change_seq,
			deleted: row.deleted_at !== null,
		})),
		stepResults: data.stepResults.map((row) => ({
			id: row.id,
			sessionId: row.session_id,
			exerciseName: row.exercise_name,
			orderIndex: row.order_index,
			reps: row.reps,
			weightKg: row.weight_kg,
			durationSeconds: row.duration_seconds,
			completedAt: row.completed_at,
			changeSeq: row.change_seq,
			deleted: row.deleted_at !== null,
		})),
	});
}

/** The request was valid and the server will never accept it. */
function conflict(c: Context<AuthedEnv>, correlationId: string) {
	console.warn(
		JSON.stringify({
			event: "sync_rejected",
			reason: "record_deleted",
			correlationId,
		}),
	);
	return c.json(
		{
			error: {
				code: "record_deleted",
				message:
					"A record in this request was already deleted. Deleted records cannot be restored; create a new record instead.",
				correlationId,
			},
		},
		409,
	);
}

/** The account is no longer active, so sync is closed for it. */
function accountGone(c: Context<AuthedEnv>, correlationId: string) {
	console.warn(
		JSON.stringify({
			event: "sync_rejected",
			reason: "account_not_active",
			correlationId,
		}),
	);
	return c.json(
		{
			error: {
				code: "account_not_active",
				message: "This account is no longer active.",
				correlationId,
			},
		},
		403,
	);
}

/** Stored data this endpoint refuses to serve incorrectly. */
function unavailable(c: Context<AuthedEnv>, correlationId: string) {
	console.error(
		JSON.stringify({
			event: "sync_failed",
			reason: "oversized_change_sequence",
			correlationId,
		}),
	);
	return c.json(
		{
			error: {
				code: "sync_unavailable",
				message: "Sync is temporarily unavailable for this account.",
				correlationId,
			},
		},
		500,
	);
}

function reject(
	c: Context<AuthedEnv>,
	correlationId: string,
	reason: string,
	status: 400,
) {
	console.warn(
		JSON.stringify({
			event: "sync_rejected",
			reason,
			correlationId,
			// Deliberately absent: user id, record ids, exercise names.
		}),
	);
	return c.json(
		{
			error: {
				code: "malformed_request",
				message: "Malformed request",
				correlationId,
			},
		},
		status,
	);
}

async function readJson(c: Context<AuthedEnv>): Promise<unknown> {
	try {
		return await c.req.json();
	} catch {
		return null;
	}
}
