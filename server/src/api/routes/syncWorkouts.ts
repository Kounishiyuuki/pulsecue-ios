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
	SyncOwnershipError,
	pullWorkoutData,
	uploadWorkoutData,
} from "../db/workoutSync";
import type { AuthedEnv } from "../types";

/** Bounded so one request cannot ask the Worker to do unbounded work. */
const MAX_ROWS = 500;

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

const uploadSchema = z.object({
	sessions: z.array(sessionSchema).max(MAX_ROWS).default([]),
	stepResults: z.array(stepResultSchema).max(MAX_ROWS).default([]),
});

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

	const data = await pullWorkoutData(c.env.DB, user.id, since, MAX_ROWS);
	return c.json({
		changeSeq: data.changeSeq,
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
