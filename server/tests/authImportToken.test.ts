import { describe, expect, it } from "vitest";
import app from "../src/index";

const IMPORT_API_KEY = "test-import-api-key-abc123";
const TOKEN_SECRET = "test-token-signing-secret-xyz";

const ENV = {
	PULSECUE_IMPORT_API_KEY: IMPORT_API_KEY,
	PULSECUE_IMPORT_TOKEN_SECRET: TOKEN_SECRET,
} as unknown as Env;

function makeRequest(body: unknown, init: RequestInit = {}): Request {
	return new Request("http://localhost/api/auth/import-token", {
		method: "POST",
		headers: { "Content-Type": "application/json", ...(init.headers ?? {}) },
		body: typeof body === "string" ? body : JSON.stringify(body),
		...init,
	});
}

const validBody = {
	deviceId: "9F3C2F8E-1E1B-4C2D-9B8C-1F0E2D3A4B5C",
	appVersion: "1.0.0 (1)",
	attestation: "dev-placeholder-assertion",
};

describe("POST /api/auth/import-token", () => {
	it("returns 400 invalid_body for malformed JSON", async () => {
		const res = await app.request(
			makeRequest("not json"),
			undefined,
			ENV,
		);
		expect(res.status).toBe(400);
		expect(await res.json()).toMatchObject({
			error: { code: "invalid_body" },
		});
	});

	it("returns 400 invalid_body when deviceId is missing", async () => {
		const res = await app.request(
			makeRequest({ appVersion: "1.0", attestation: "x" }),
			undefined,
			ENV,
		);
		expect(res.status).toBe(400);
		const body = (await res.json()) as { error: { code: string; message: string } };
		expect(body.error.code).toBe("invalid_body");
		expect(body.error.message.toLowerCase()).toContain("deviceid");
	});

	it("returns 400 invalid_body when appVersion is missing", async () => {
		const res = await app.request(
			makeRequest({ deviceId: "d", attestation: "x" }),
			undefined,
			ENV,
		);
		expect(res.status).toBe(400);
		const body = (await res.json()) as { error: { code: string; message: string } };
		expect(body.error.code).toBe("invalid_body");
		expect(body.error.message.toLowerCase()).toContain("appversion");
	});

	it("returns 400 invalid_body when attestation is missing", async () => {
		const res = await app.request(
			makeRequest({ deviceId: "d", appVersion: "1.0" }),
			undefined,
			ENV,
		);
		expect(res.status).toBe(400);
		const body = (await res.json()) as { error: { code: string; message: string } };
		expect(body.error.code).toBe("invalid_body");
		expect(body.error.message.toLowerCase()).toContain("attestation");
	});

	it("returns 400 invalid_body when attestation is empty / whitespace", async () => {
		const res = await app.request(
			makeRequest({ deviceId: "d", appVersion: "1.0", attestation: "   " }),
			undefined,
			ENV,
		);
		expect(res.status).toBe(400);
		expect(await res.json()).toMatchObject({
			error: { code: "invalid_body" },
		});
	});

	it("returns 500 internal_error if token secret is not configured", async () => {
		const res = await app.request(
			makeRequest(validBody),
			undefined,
			{ PULSECUE_IMPORT_API_KEY: IMPORT_API_KEY } as unknown as Env,
		);
		expect(res.status).toBe(500);
		expect(await res.json()).toMatchObject({
			error: { code: "internal_error" },
		});
	});

	it("returns 200 with token/expiresAt/ttlSeconds for a valid request", async () => {
		const res = await app.request(
			makeRequest(validBody),
			undefined,
			ENV,
		);
		expect(res.status).toBe(200);
		const body = (await res.json()) as {
			token: string;
			expiresAt: string;
			ttlSeconds: number;
		};
		expect(typeof body.token).toBe("string");
		expect(body.token.length).toBeGreaterThan(0);
		expect(body.ttlSeconds).toBe(86_400);
		// ISO 8601 sanity
		expect(new Date(body.expiresAt).toString()).not.toBe("Invalid Date");
	});

	it("token is not equal to PULSECUE_IMPORT_API_KEY", async () => {
		const res = await app.request(
			makeRequest(validBody),
			undefined,
			ENV,
		);
		const body = (await res.json()) as { token: string };
		expect(body.token).not.toBe(IMPORT_API_KEY);
		expect(body.token).not.toContain(IMPORT_API_KEY);
	});

	it("response body does not include either long-lived secret", async () => {
		const res = await app.request(
			makeRequest(validBody),
			undefined,
			ENV,
		);
		const raw = await res.text();
		expect(raw).not.toContain(IMPORT_API_KEY);
		expect(raw).not.toContain(TOKEN_SECRET);
	});

	it("error envelope shape matches existing routes", async () => {
		const res = await app.request(
			makeRequest({}),
			undefined,
			ENV,
		);
		const body = (await res.json()) as { error?: { code?: string; message?: string } };
		expect(body.error).toBeDefined();
		expect(typeof body.error?.code).toBe("string");
		expect(typeof body.error?.message).toBe("string");
	});
});

describe("existing routes are unchanged by this PR", () => {
	it("GET /health still returns { ok: true }", async () => {
		const res = await app.request("/health", undefined, ENV);
		expect(res.status).toBe(200);
		expect(await res.json()).toEqual({ ok: true });
	});

	it("POST /api/gym-machines/import still requires the long-lived API key", async () => {
		const res = await app.request(
			new Request("http://localhost/api/gym-machines/import", {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({ gymName: "x", officialUrl: "https://example.com/" }),
			}),
			undefined,
			ENV,
		);
		expect(res.status).toBe(401);
		expect(await res.json()).toMatchObject({
			error: { code: "unauthorized" },
		});
	});
});
