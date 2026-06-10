import { describe, expect, it } from "vitest";
import app from "../src/index";

//
// Mock-auth tests for POST /api/ai/training-plan. These exercise the
// opt-in `AI_TRAINING_PLAN_AUTH_MODE=mock` gate using clearly FAKE,
// test-only token values. No real secrets, no provider, no network.
//

// Clearly-fake, test-only token values (never real secrets).
const VALID_TOKEN = "fake-valid-ai-training-plan-token";
const EXPIRED_TOKEN = "fake-expired-ai-training-plan-token";
const WRONG_SCOPE_TOKEN = "fake-wrong-scope-ai-token";

// Auth disabled (no mode) — must behave exactly as before.
const NO_AUTH_ENV = {} as unknown as Env;

// Mock-auth enabled with the fake tokens wired in.
const MOCK_AUTH_ENV = {
	AI_TRAINING_PLAN_AUTH_MODE: "mock",
	AI_TRAINING_PLAN_MOCK_VALID_TOKEN: VALID_TOKEN,
	AI_TRAINING_PLAN_MOCK_EXPIRED_TOKEN: EXPIRED_TOKEN,
	AI_TRAINING_PLAN_MOCK_WRONG_SCOPE_TOKEN: WRONG_SCOPE_TOKEN,
} as unknown as Env;

const THREE_MACHINES = ["chest_press", "lat_pulldown", "leg_press"];

function makeRequest(body: unknown, headers: Record<string, string> = {}): Request {
	return new Request("http://localhost/api/ai/training-plan", {
		method: "POST",
		headers: { "Content-Type": "application/json", ...headers },
		body: typeof body === "string" ? body : JSON.stringify(body),
	});
}

interface RawResult {
	status: number;
	text: string;
	json: any;
}

async function call(
	env: Env,
	body: unknown,
	headers: Record<string, string> = {},
): Promise<RawResult> {
	const res = await app.request(makeRequest(body, headers), undefined, env);
	const text = await res.text();
	let json: any = null;
	try {
		json = JSON.parse(text);
	} catch {
		/* non-JSON body */
	}
	return { status: res.status, text, json };
}

const VALID_BODY = {
	userMessage: "胸と背中を鍛えたい",
	goal: "hypertrophy",
	daysPerWeek: 3,
	availableMachineIds: THREE_MACHINES,
};

function bearer(token: string): Record<string, string> {
	return { Authorization: `Bearer ${token}` };
}

describe("POST /api/ai/training-plan mock auth", () => {
	it("auth disabled: keeps existing unauthenticated behavior (200, no header)", async () => {
		const res = await call(NO_AUTH_ENV, VALID_BODY);
		expect(res.status).toBe(200);
		expect(res.json.sessions.length).toBe(3);
	});

	it("auth disabled: ignores any Authorization header (still 200)", async () => {
		const res = await call(NO_AUTH_ENV, VALID_BODY, bearer("anything-goes"));
		expect(res.status).toBe(200);
	});

	it("mock + missing Authorization → 401 unauthorized", async () => {
		const res = await call(MOCK_AUTH_ENV, VALID_BODY);
		expect(res.status).toBe(401);
		expect(res.json.error.code).toBe("unauthorized");
	});

	it("mock + malformed Authorization → 401 unauthorized", async () => {
		const res = await call(MOCK_AUTH_ENV, VALID_BODY, {
			Authorization: VALID_TOKEN, // missing "Bearer " prefix
		});
		expect(res.status).toBe(401);
		expect(res.json.error.code).toBe("unauthorized");
	});

	it("mock + empty Bearer token → 401 unauthorized", async () => {
		const res = await call(MOCK_AUTH_ENV, VALID_BODY, { Authorization: "Bearer " });
		expect(res.status).toBe(401);
		expect(res.json.error.code).toBe("unauthorized");
	});

	it("mock + unknown/invalid token → 401 unauthorized", async () => {
		const res = await call(MOCK_AUTH_ENV, VALID_BODY, bearer("not-a-known-token"));
		expect(res.status).toBe(401);
		expect(res.json.error.code).toBe("unauthorized");
	});

	it("mock + expired token → 401 token_expired", async () => {
		const res = await call(MOCK_AUTH_ENV, VALID_BODY, bearer(EXPIRED_TOKEN));
		expect(res.status).toBe(401);
		expect(res.json.error.code).toBe("token_expired");
	});

	it("mock + wrong-scope token → 403 invalid_scope", async () => {
		const res = await call(MOCK_AUTH_ENV, VALID_BODY, bearer(WRONG_SCOPE_TOKEN));
		expect(res.status).toBe(403);
		expect(res.json.error.code).toBe("invalid_scope");
	});

	it("mock + valid token → 200 deterministic plan response", async () => {
		const a = await call(MOCK_AUTH_ENV, VALID_BODY, bearer(VALID_TOKEN));
		const b = await call(MOCK_AUTH_ENV, VALID_BODY, bearer(VALID_TOKEN));
		expect(a.status).toBe(200);
		expect(a.json.sessions.length).toBe(3);
		expect(typeof a.json.title).toBe("string");
		expect(typeof a.json.rationale).toBe("string");
		expect(a.json).toEqual(b.json); // deterministic
	});

	it("auth error envelope carries a safe requestId and no token/userMessage", async () => {
		const distinctiveMessage = "PLEASE_DO_NOT_ECHO_THIS_MESSAGE";
		const res = await call(
			MOCK_AUTH_ENV,
			{ ...VALID_BODY, userMessage: distinctiveMessage },
			bearer("some-invalid-token-value"),
		);
		expect(res.status).toBe(401);
		expect(typeof res.json.error.requestId).toBe("string");
		expect(res.json.error.requestId.length).toBeGreaterThan(0);
		// The response must not echo the token or the userMessage.
		expect(res.text).not.toContain("some-invalid-token-value");
		expect(res.text).not.toContain(distinctiveMessage);
	});

	it("valid token: still drops unknown machine ids with a warning", async () => {
		const res = await call(
			MOCK_AUTH_ENV,
			{ daysPerWeek: 2, availableMachineIds: [...THREE_MACHINES, "__not_real__"] },
			bearer(VALID_TOKEN),
		);
		expect(res.status).toBe(200);
		const ids = res.json.sessions.flatMap(
			(s: { exerciseMachineIds: string[] }) => s.exerciseMachineIds,
		);
		expect(ids).not.toContain("__not_real__");
		expect(res.json.warnings.some((w: string) => w.includes("__not_real__"))).toBe(true);
	});

	it("valid token: malformed JSON still returns 400 invalid_request after auth passes", async () => {
		const res = await call(MOCK_AUTH_ENV, "not json", bearer(VALID_TOKEN));
		expect(res.status).toBe(400);
		expect(res.json.error.code).toBe("invalid_request");
	});

	it("mock mode with no configured valid token rejects everything (fail-closed)", async () => {
		const env = { AI_TRAINING_PLAN_AUTH_MODE: "mock" } as unknown as Env;
		const res = await call(env, VALID_BODY, bearer(VALID_TOKEN));
		expect(res.status).toBe(401);
		expect(res.json.error.code).toBe("unauthorized");
	});
});
