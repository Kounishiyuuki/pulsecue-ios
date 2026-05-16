import { describe, expect, it } from "vitest";
import {
	IMPORT_TOKEN_DEFAULT_TTL_SECONDS,
	IMPORT_TOKEN_SCOPE,
	base64urlEncode,
	hmacBase64Url,
	mintToken,
} from "../src/auth/tokens";

describe("mintToken", () => {
	it("returns token with payload.signature shape", async () => {
		const minted = await mintToken({
			deviceId: "abc-123",
			secret: "s3cret",
			now: new Date("2026-05-16T00:00:00Z"),
		});
		const parts = minted.token.split(".");
		expect(parts).toHaveLength(2);
		expect(parts[0]?.length).toBeGreaterThan(0);
		expect(parts[1]?.length).toBeGreaterThan(0);
	});

	it("defaults ttlSeconds to 86400", async () => {
		const minted = await mintToken({
			deviceId: "abc-123",
			secret: "s3cret",
		});
		expect(minted.ttlSeconds).toBe(IMPORT_TOKEN_DEFAULT_TTL_SECONDS);
		expect(IMPORT_TOKEN_DEFAULT_TTL_SECONDS).toBe(86_400);
	});

	it("expiresAt is now + ttlSeconds in ISO 8601", async () => {
		const now = new Date("2026-05-16T00:00:00Z");
		const minted = await mintToken({
			deviceId: "abc-123",
			secret: "s3cret",
			now,
			ttlSeconds: 100,
		});
		expect(minted.expiresAt).toBe("2026-05-16T00:01:40.000Z");
	});

	it("encodes the device id + scope into the payload", async () => {
		const minted = await mintToken({
			deviceId: "device-xyz",
			secret: "s3cret",
			now: new Date("2026-05-16T00:00:00Z"),
		});
		const payloadB64 = minted.token.split(".")[0]!;
		const json = atob(payloadB64.replace(/-/g, "+").replace(/_/g, "/"));
		const payload = JSON.parse(json) as { d: string; s: string; e: number };
		expect(payload.d).toBe("device-xyz");
		expect(payload.s).toBe(IMPORT_TOKEN_SCOPE);
		expect(payload.e).toBe(Math.floor(new Date("2026-05-16T00:00:00Z").getTime() / 1000) + IMPORT_TOKEN_DEFAULT_TTL_SECONDS);
	});

	it("is deterministic for identical input", async () => {
		const a = await mintToken({
			deviceId: "device-xyz",
			secret: "same",
			now: new Date("2026-05-16T00:00:00Z"),
		});
		const b = await mintToken({
			deviceId: "device-xyz",
			secret: "same",
			now: new Date("2026-05-16T00:00:00Z"),
		});
		expect(a.token).toBe(b.token);
	});

	it("changes signature when secret changes (rotation works)", async () => {
		const a = await mintToken({
			deviceId: "device-xyz",
			secret: "first",
			now: new Date("2026-05-16T00:00:00Z"),
		});
		const b = await mintToken({
			deviceId: "device-xyz",
			secret: "second",
			now: new Date("2026-05-16T00:00:00Z"),
		});
		expect(a.token.split(".")[0]).toBe(b.token.split(".")[0]);
		expect(a.token.split(".")[1]).not.toBe(b.token.split(".")[1]);
	});

	it("rejects an empty secret", async () => {
		await expect(
			mintToken({ deviceId: "device-xyz", secret: "" }),
		).rejects.toThrow(/secret/i);
	});

	it("rejects an empty deviceId", async () => {
		await expect(
			mintToken({ deviceId: "", secret: "s3cret" }),
		).rejects.toThrow(/deviceId/i);
	});

	it("does not equal the import API key by format alone", async () => {
		// Even if a future operator misconfigures both secrets to the
		// same value, the minted token still contains the
		// payload.signature separator and base64url-encoded JSON
		// payload, so it cannot collide with a free-form API key.
		const minted = await mintToken({
			deviceId: "device-xyz",
			secret: "PULSECUE_IMPORT_API_KEY",
		});
		expect(minted.token).not.toBe("PULSECUE_IMPORT_API_KEY");
		expect(minted.token.includes(".")).toBe(true);
	});
});

describe("hmacBase64Url", () => {
	it("returns base64url (no padding, URL-safe alphabet)", async () => {
		const sig = await hmacBase64Url("secret", "payload");
		expect(sig).toMatch(/^[A-Za-z0-9_-]+$/);
		expect(sig.endsWith("=")).toBe(false);
	});

	it("is deterministic", async () => {
		const a = await hmacBase64Url("secret", "payload");
		const b = await hmacBase64Url("secret", "payload");
		expect(a).toBe(b);
	});
});

describe("base64urlEncode", () => {
	it("matches base64url for simple inputs", () => {
		expect(base64urlEncode(new TextEncoder().encode("Hello"))).toBe("SGVsbG8");
		expect(base64urlEncode(new Uint8Array([0xfb, 0xff, 0xff]))).toBe("-___");
	});
});
