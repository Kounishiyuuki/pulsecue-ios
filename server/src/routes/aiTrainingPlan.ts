//
//  aiTrainingPlan.ts
//  server
//
//  Deterministic, MOCK-ONLY proxy endpoint for AI training plan drafts.
//  Implements `POST /api/ai/training-plan` per
//  `Docs/ai-training-plan-proxy-endpoint-spec.md`.
//
//  Boundaries (locked for this PR):
//   - No real AI, no OpenAI, no provider SDK, no external HTTP calls,
//     no provider keys/secrets, no env requirement. The response is a
//     pure function of the request, so it is stable across calls.
//   - Mirrors the iOS `MockAITrainingPlanProvider`: it lays the
//     caller-supplied (catalog-known) machine ids out across the
//     requested number of days. It does NOT interpret `userMessage`.
//   - Never fabricates machine ids: returned `exerciseMachineIds` are
//     always a subset of the request's `availableMachineIds` that also
//     exist in the server catalog.
//   - Saves nothing. There is no Routine/Step concept on the server;
//     persistence happens only on the iOS side after explicit user
//     confirmation.
//
//  Auth: this mock endpoint is intentionally UNGATED (dev/mock only).
//  The real endpoint will require a short-lived `ai:training-plan`
//  scoped token (see the spec §4 and `Docs/import-token-endpoint-spec.md`);
//  that is deliberately deferred so this PR introduces no credential
//  system and no secrets.
//

import type { Context } from "hono";
import { z } from "zod";
import { MACHINE_CATALOG } from "../parser/machines";

// MARK: - Constraints (see spec §5/§6)

const USER_MESSAGE_MAX = 1000;
const MIN_DAYS = 1;
const MAX_DAYS = 6;
const DEFAULT_DAYS = 3;
const MAX_AVAILABLE_MACHINES = 64;
const MAX_EXERCISES_PER_SESSION = 8;

/** Canonical server-side machine ids the response is allowed to use. */
const CATALOG_IDS: ReadonlySet<string> = new Set(
	MACHINE_CATALOG.map((entry) => entry.id),
);

// MARK: - Request schema
//
// Type-strict but value-lenient: wrong top-level types are rejected as
// `invalid_request`, but unknown enum/body-part *values* are tolerated
// (ignored) per the spec — the mock does not act on them. All fields are
// optional so a bare `{}` (or free-form chat) is valid.

const BodySchema = z.object({
	userMessage: z.string().optional(),
	goal: z.string().nullish(),
	daysPerWeek: z.number().nullish(),
	targetBodyParts: z.array(z.string()).optional(),
	experienceLevel: z.string().nullish(),
	preferredSplit: z.string().nullish(),
	availableMachineIds: z.array(z.string()).optional(),
});

interface SessionResponse {
	title: string;
	exerciseMachineIds: string[];
	notes: string | null;
}

export async function aiTrainingPlanHandler(c: Context): Promise<Response> {
	// 1. Body validation.
	const rawBody = await safeReadJson(c);
	if (!rawBody.ok) {
		return c.json(errorBody("invalid_request", rawBody.message), 400);
	}
	const parsed = BodySchema.safeParse(rawBody.value);
	if (!parsed.success) {
		const message = parsed.error.issues
			.map((issue) => `${issue.path.join(".") || "body"}: ${issue.message}`)
			.join("; ");
		return c.json(errorBody("invalid_request", message), 400);
	}
	const body = parsed.data;

	const warnings: string[] = [];
	const warn = (message: string) => {
		if (!warnings.includes(message)) warnings.push(message);
	};

	// 2. userMessage length cap (truncate + warn; never echoed in logs).
	const rawMessage = body.userMessage ?? "";
	if (rawMessage.length > USER_MESSAGE_MAX) {
		warn(`相談内容が長いため${USER_MESSAGE_MAX}文字に切り詰めました。`);
	}

	// 3. daysPerWeek: round + clamp to 1...6.
	const days = clampDays(body.daysPerWeek, warn);

	// 4. availableMachineIds: dedupe, cap, then keep only catalog ids.
	const requested = body.availableMachineIds ?? [];
	if (requested.length > MAX_AVAILABLE_MACHINES) {
		warn(`利用可能マシンが多いため先頭${MAX_AVAILABLE_MACHINES}件のみ使用しました。`);
	}
	const deduped: string[] = [];
	for (const id of requested.slice(0, MAX_AVAILABLE_MACHINES)) {
		if (!deduped.includes(id)) deduped.push(id);
	}
	const unknown = deduped.filter((id) => !CATALOG_IDS.has(id));
	if (unknown.length > 0) {
		warn(`カタログにないマシンを除外しました: ${unknown.join(", ")}`);
	}
	// Usable pool: catalog-known ids, sorted for deterministic output.
	const pool = deduped.filter((id) => CATALOG_IDS.has(id)).sort();

	// 5. Build sessions (round-robin across days). Never fabricates ids.
	const sessions: SessionResponse[] = [];
	for (let day = 0; day < days; day += 1) {
		const machines = pool
			.filter((_, index) => index % days === day)
			.slice(0, MAX_EXERCISES_PER_SESSION);
		sessions.push({
			title: `Day ${day + 1}`,
			exerciseMachineIds: machines,
			notes: null,
		});
	}

	if (pool.length === 0) {
		warn(
			"利用可能なマシンがないため、種目を提案できませんでした。マシンを選択して再度お試しください。",
		);
	}

	const goalLabel = goalDisplayName(body.goal);
	return c.json({
		title: `${goalLabel}プラン（モックAI下書き）`,
		sessions,
		rationale:
			"サーバーのモックエンドポイントによる決定論的な下書きです。実際のAI生成は行っていません。",
		warnings,
	});
}

// MARK: - Helpers

function clampDays(
	value: number | null | undefined,
	warn: (message: string) => void,
): number {
	if (value === null || value === undefined || !Number.isFinite(value)) {
		return DEFAULT_DAYS;
	}
	const rounded = Math.round(value);
	const clamped = Math.min(Math.max(rounded, MIN_DAYS), MAX_DAYS);
	if (clamped !== value) {
		warn(`週の日数を${MIN_DAYS}〜${MAX_DAYS}日の範囲（${clamped}日）に調整しました。`);
	}
	return clamped;
}

/** Localized goal label. Unknown/absent goals fall back generically. */
function goalDisplayName(goal: string | null | undefined): string {
	switch (goal) {
		case "fatLoss":
			return "減量";
		case "hypertrophy":
			return "筋肥大";
		case "strength":
			return "筋力";
		case "consistency":
			return "習慣化";
		default:
			return "トレーニング";
	}
}

async function safeReadJson(
	c: Context,
): Promise<{ ok: true; value: unknown } | { ok: false; message: string }> {
	try {
		const value = await c.req.json();
		return { ok: true, value };
	} catch {
		return { ok: false, message: "Request body must be valid JSON" };
	}
}

function errorBody(code: string, message: string) {
	return { error: { code, message } };
}
