import { describe, expect, it } from "vitest";
import app from "../src/index";
import { extractBearerToken } from "../src/auth";

const API_KEY = "test-import-key-abc123";
const ENV = { PULSECUE_IMPORT_API_KEY: API_KEY } as unknown as Env;

function importRequest(headers: Record<string, string>): Request {
	return new Request("http://localhost/api/gym-machines/import", {
		method: "POST",
		headers: { "Content-Type": "application/json", ...headers },
		// Intentionally invalid body: a request that clears auth should
		// reach the handler and fail validation (400), not auth (401).
		// This proves the middleware called next() without a network fetch.
		body: JSON.stringify({ gymName: "" }),
	});
}

describe("extractBearerToken", () => {
	it("returns null for a missing header", () => {
		expect(extractBearerToken(undefined)).toBeNull();
	});

	it("returns null for a malformed header", () => {
		expect(extractBearerToken("Token abc")).toBeNull();
		expect(extractBearerToken("Bearer")).toBeNull();
		expect(extractBearerToken("Bearer   ")).toBeNull();
		expect(extractBearerToken("abc123")).toBeNull();
	});

	it("extracts the token from a well-formed header", () => {
		expect(extractBearerToken("Bearer abc123")).toBe("abc123");
		expect(extractBearerToken("bearer abc123")).toBe("abc123");
	});
});

describe("POST /api/gym-machines/import auth", () => {
	it("rejects a request with no Authorization header", async () => {
		const res = await app.request(importRequest({}), undefined, ENV);
		expect(res.status).toBe(401);
		const body = await res.json();
		expect(body).toEqual({
			error: { code: "unauthorized", message: "A valid API key is required" },
		});
	});

	it("rejects a malformed Authorization header", async () => {
		const res = await app.request(
			importRequest({ Authorization: "Token something" }),
			undefined,
			ENV,
		);
		expect(res.status).toBe(401);
		expect(await res.json()).toMatchObject({
			error: { code: "unauthorized" },
		});
	});

	it("rejects a wrong API key", async () => {
		const res = await app.request(
			importRequest({ Authorization: "Bearer wrong-key" }),
			undefined,
			ENV,
		);
		expect(res.status).toBe(401);
		expect(await res.json()).toMatchObject({
			error: { code: "unauthorized" },
		});
	});

	it("rejects every request when the secret is not configured", async () => {
		const res = await app.request(
			importRequest({ Authorization: `Bearer ${API_KEY}` }),
			undefined,
			{} as unknown as Env,
		);
		expect(res.status).toBe(401);
	});

	it("allows the request to proceed with the correct API key", async () => {
		const res = await app.request(
			importRequest({ Authorization: `Bearer ${API_KEY}` }),
			undefined,
			ENV,
		);
		// Auth passed: the request reached the handler and failed body
		// validation instead of being blocked at 401.
		expect(res.status).toBe(400);
		const body = (await res.json()) as { error: { code: string } };
		expect(body.error.code).toBe("invalid_body");
	});
});

describe("GET /health", () => {
	it("remains public with no Authorization header", async () => {
		const res = await app.request("/health", undefined, ENV);
		expect(res.status).toBe(200);
		expect(await res.json()).toEqual({ ok: true });
	});
});
