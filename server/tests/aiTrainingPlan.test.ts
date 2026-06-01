import { describe, expect, it } from "vitest";
import app from "../src/index";

// The mock endpoint requires no secrets/bindings, so an empty env is a
// valid call — proving no env/secret dependency was introduced.
const EMPTY_ENV = {} as unknown as Env;

function makeRequest(body: unknown, init: RequestInit = {}): Request {
	return new Request("http://localhost/api/ai/training-plan", {
		method: "POST",
		headers: { "Content-Type": "application/json", ...(init.headers ?? {}) },
		body: typeof body === "string" ? body : JSON.stringify(body),
		...init,
	});
}

interface PlanResponse {
	title: string;
	rationale: string;
	warnings: string[];
	sessions: { title: string; exerciseMachineIds: string[]; notes: string | null }[];
}

async function post(body: unknown): Promise<{ status: number; json: PlanResponse }> {
	const res = await app.request(makeRequest(body), undefined, EMPTY_ENV);
	return { status: res.status, json: (await res.json()) as PlanResponse };
}

const THREE_MACHINES = ["chest_press", "lat_pulldown", "leg_press"];

describe("POST /api/ai/training-plan (mock)", () => {
	it("returns a deterministic response for a valid request", async () => {
		const body = {
			userMessage: "胸と背中を鍛えたい",
			goal: "hypertrophy",
			daysPerWeek: 3,
			availableMachineIds: THREE_MACHINES,
		};
		const a = await post(body);
		const b = await post(body);
		expect(a.status).toBe(200);
		expect(a.json).toEqual(b.json); // deterministic
		expect(a.json.sessions.length).toBe(3);
		expect(typeof a.json.title).toBe("string");
		expect(typeof a.json.rationale).toBe("string");
	});

	it("clamps daysPerWeek to 1...6 and warns", async () => {
		const high = await post({ daysPerWeek: 99, availableMachineIds: THREE_MACHINES });
		expect(high.json.sessions.length).toBe(6);
		expect(high.json.warnings.some((w) => w.includes("日数"))).toBe(true);

		const low = await post({ daysPerWeek: 0, availableMachineIds: THREE_MACHINES });
		expect(low.json.sessions.length).toBe(1);
		expect(low.json.warnings.some((w) => w.includes("日数"))).toBe(true);
	});

	it("defaults to 3 days when daysPerWeek is null/absent without a clamp warning", async () => {
		const res = await post({ availableMachineIds: THREE_MACHINES });
		expect(res.json.sessions.length).toBe(3);
		expect(res.json.warnings.some((w) => w.includes("日数"))).toBe(false);
	});

	it("uses only ids from availableMachineIds (never fabricates)", async () => {
		const res = await post({ daysPerWeek: 2, availableMachineIds: THREE_MACHINES });
		const used = res.json.sessions.flatMap((s) => s.exerciseMachineIds);
		expect(used.length).toBeGreaterThan(0);
		expect(used.every((id) => THREE_MACHINES.includes(id))).toBe(true);
	});

	it("drops unknown machine ids with a warning and never returns them", async () => {
		const res = await post({
			daysPerWeek: 1,
			availableMachineIds: ["chest_press", "totally_fake", "another_fake"],
		});
		const used = res.json.sessions.flatMap((s) => s.exerciseMachineIds);
		expect(used).not.toContain("totally_fake");
		expect(used).not.toContain("another_fake");
		expect(used).toContain("chest_press");
		expect(res.json.warnings.some((w) => w.includes("totally_fake"))).toBe(true);
	});

	it("returns empty sessions + warning when no usable machines, fabricating nothing", async () => {
		const res = await post({ daysPerWeek: 3, availableMachineIds: ["nope", "nada"] });
		expect(res.status).toBe(200);
		expect(res.json.sessions.every((s) => s.exerciseMachineIds.length === 0)).toBe(true);
		expect(res.json.warnings.length).toBeGreaterThan(0);
	});

	it("accepts an empty body without crashing", async () => {
		const res = await post({});
		expect(res.status).toBe(200);
		expect(res.json.sessions.length).toBe(3); // default days, no machines
		expect(res.json.sessions.every((s) => s.exerciseMachineIds.length === 0)).toBe(true);
	});

	it("truncates an over-long userMessage with a warning (and never echoes it)", async () => {
		const longMessage = "あ".repeat(2000);
		const res = await post({ userMessage: longMessage, availableMachineIds: THREE_MACHINES });
		expect(res.status).toBe(200);
		expect(res.json.warnings.some((w) => w.includes("切り詰め"))).toBe(true);
		// The raw response must not contain the (long) prompt content.
		expect(JSON.stringify(res.json)).not.toContain(longMessage);
	});

	it("returns invalid_request for malformed JSON", async () => {
		const res = await app.request(makeRequest("not json"), undefined, EMPTY_ENV);
		expect(res.status).toBe(400);
		expect(await res.json()).toMatchObject({ error: { code: "invalid_request" } });
	});

	it("returns invalid_request for wrong top-level field types", async () => {
		const res = await app.request(
			makeRequest({ daysPerWeek: "three", availableMachineIds: "chest_press" }),
			undefined,
			EMPTY_ENV,
		);
		expect(res.status).toBe(400);
		expect(await res.json()).toMatchObject({ error: { code: "invalid_request" } });
	});

	it("error envelope shape matches existing routes", async () => {
		const res = await app.request(makeRequest("bad"), undefined, EMPTY_ENV);
		const body = (await res.json()) as { error?: { code?: string; message?: string } };
		expect(typeof body.error?.code).toBe("string");
		expect(typeof body.error?.message).toBe("string");
	});
});

describe("existing routes are unchanged by this PR", () => {
	it("GET /health still returns { ok: true }", async () => {
		const res = await app.request("/health", undefined, EMPTY_ENV);
		expect(res.status).toBe(200);
		expect(await res.json()).toEqual({ ok: true });
	});
});
