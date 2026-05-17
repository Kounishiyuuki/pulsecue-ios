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

// ---------------------------------------------------------------
// Short-lived import-token auth path (PR after #27).
// `requireImportAuthorization` accepts either:
//   1. PULSECUE_IMPORT_API_KEY (existing long-lived path, unchanged)
//   2. A short-lived token signed by PULSECUE_IMPORT_TOKEN_SECRET.
// ---------------------------------------------------------------

describe("POST /api/gym-machines/import (short-lived token path)", () => {
	const TOKEN_SECRET = "test-token-signing-secret-xyz";
	const DUAL_ENV = {
		PULSECUE_IMPORT_API_KEY: API_KEY,
		PULSECUE_IMPORT_TOKEN_SECRET: TOKEN_SECRET,
	} as unknown as Env;

	async function mintFreshToken(opts?: { ttlSeconds?: number; now?: Date; secret?: string }): Promise<string> {
		const { mintToken } = await import("../src/auth/tokens");
		const minted = await mintToken({
			deviceId: "device-test",
			secret: opts?.secret ?? TOKEN_SECRET,
			now: opts?.now,
			ttlSeconds: opts?.ttlSeconds,
		});
		return minted.token;
	}

	it("authorizes the request with a freshly-minted short-lived token", async () => {
		const token = await mintFreshToken();
		const res = await app.request(
			importRequest({ Authorization: `Bearer ${token}` }),
			undefined,
			DUAL_ENV,
		);
		// Auth passes → reaches handler → 400 invalid_body (intentional
		// invalid body in the shared `importRequest` helper).
		expect(res.status).toBe(400);
		const body = (await res.json()) as { error: { code: string } };
		expect(body.error.code).toBe("invalid_body");
	});

	it("rejects an expired short-lived token with 401 unauthorized", async () => {
		const past = new Date(Date.now() - 24 * 60 * 60 * 1000);
		const token = await mintFreshToken({ now: past, ttlSeconds: 60 });
		const res = await app.request(
			importRequest({ Authorization: `Bearer ${token}` }),
			undefined,
			DUAL_ENV,
		);
		expect(res.status).toBe(401);
		expect(await res.json()).toMatchObject({ error: { code: "unauthorized" } });
	});

	it("rejects a token signed with the wrong secret with 401", async () => {
		const token = await mintFreshToken({ secret: "different-secret" });
		const res = await app.request(
			importRequest({ Authorization: `Bearer ${token}` }),
			undefined,
			DUAL_ENV,
		);
		expect(res.status).toBe(401);
	});

	it("rejects a malformed token (missing dot) with 401", async () => {
		const res = await app.request(
			importRequest({ Authorization: "Bearer not-a-token-at-all" }),
			undefined,
			DUAL_ENV,
		);
		expect(res.status).toBe(401);
	});

	it("rejects a token forged with the wrong scope with 401", async () => {
		const {
			IMPORT_TOKEN_SCOPE,
			base64urlEncode,
			hmacBase64Url,
		} = await import("../src/auth/tokens");
		const payload = JSON.stringify({
			d: "device-test",
			e: Math.floor(Date.now() / 1000) + 3600,
			s: "wrong-scope",
		});
		void IMPORT_TOKEN_SCOPE; // imported to make the intent explicit
		const payloadB64 = base64urlEncode(new TextEncoder().encode(payload));
		const sig = await hmacBase64Url(TOKEN_SECRET, payloadB64);
		const forged = `${payloadB64}.${sig}`;
		const res = await app.request(
			importRequest({ Authorization: `Bearer ${forged}` }),
			undefined,
			DUAL_ENV,
		);
		expect(res.status).toBe(401);
	});

	it("when token secret is missing, the long-lived API key still works", async () => {
		const onlyApiKeyEnv = { PULSECUE_IMPORT_API_KEY: API_KEY } as unknown as Env;
		const res = await app.request(
			importRequest({ Authorization: `Bearer ${API_KEY}` }),
			undefined,
			onlyApiKeyEnv,
		);
		expect(res.status).toBe(400); // auth passes, body invalid
	});

	it("when token secret is missing, short-lived tokens are rejected with 401", async () => {
		const token = await mintFreshToken();
		const onlyApiKeyEnv = { PULSECUE_IMPORT_API_KEY: API_KEY } as unknown as Env;
		const res = await app.request(
			importRequest({ Authorization: `Bearer ${token}` }),
			undefined,
			onlyApiKeyEnv,
		);
		expect(res.status).toBe(401);
	});

	it("does not echo the supplied token in the 401 response body", async () => {
		const sensitiveToken = "pretend-this-is-a-secret-token-value-12345";
		const res = await app.request(
			importRequest({ Authorization: `Bearer ${sensitiveToken}` }),
			undefined,
			DUAL_ENV,
		);
		expect(res.status).toBe(401);
		const raw = await res.text();
		expect(raw).not.toContain(sensitiveToken);
		expect(raw).not.toContain(API_KEY);
		expect(raw).not.toContain(TOKEN_SECRET);
	});

	it("/api/auth/import-token still mints tokens unchanged", async () => {
		const res = await app.request(
			new Request("http://localhost/api/auth/import-token", {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({
					deviceId: "device-test",
					appVersion: "1.0.0 (1)",
					attestation: "dev-placeholder",
				}),
			}),
			undefined,
			DUAL_ENV,
		);
		expect(res.status).toBe(200);
		const body = (await res.json()) as { token: string; ttlSeconds: number };
		expect(typeof body.token).toBe("string");
		expect(body.ttlSeconds).toBe(86_400);
	});
});
