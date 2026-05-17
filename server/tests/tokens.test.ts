import { describe, expect, it } from "vitest";
import {
	IMPORT_TOKEN_DEFAULT_TTL_SECONDS,
	IMPORT_TOKEN_SCOPE,
	base64urlDecode,
	base64urlEncode,
	hmacBase64Url,
	mintToken,
	verifyImportToken,
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

describe("base64urlDecode", () => {
	it("round-trips with base64urlEncode", () => {
		for (const text of ["", "Hello", "abc 日本語 zzz", "?ÿ"]) {
			const encoded = base64urlEncode(new TextEncoder().encode(text));
			const decoded = base64urlDecode(encoded);
			if (text === "") {
				expect(decoded).toBeNull();
				continue;
			}
			expect(decoded).not.toBeNull();
			expect(new TextDecoder().decode(decoded!)).toBe(text);
		}
	});

	it("returns null for non-base64 input", () => {
		expect(base64urlDecode("***not-base64***")).toBeNull();
	});
});

describe("verifyImportToken", () => {
	const SECRET = "verify-test-secret";
	const NOW = new Date("2026-05-17T00:00:00Z");

	async function freshToken() {
		return (await mintToken({ deviceId: "device-vt", secret: SECRET, now: NOW, ttlSeconds: 3600 })).token;
	}

	it("returns the parsed payload on a freshly-minted token", async () => {
		const token = await freshToken();
		const result = await verifyImportToken(token, SECRET, NOW);
		expect(result).not.toBeNull();
		expect(result?.deviceId).toBe("device-vt");
		expect(result?.scope).toBe(IMPORT_TOKEN_SCOPE);
		expect(result?.expiresAtUnixSeconds).toBe(
			Math.floor(NOW.getTime() / 1000) + 3600,
		);
	});

	it("returns null for an empty token", async () => {
		expect(await verifyImportToken("", SECRET, NOW)).toBeNull();
	});

	it("returns null for an empty secret", async () => {
		const token = await freshToken();
		expect(await verifyImportToken(token, "", NOW)).toBeNull();
	});

	it("returns null for a token without the dot separator", async () => {
		expect(await verifyImportToken("nopart", SECRET, NOW)).toBeNull();
	});

	it("returns null for a token with too many parts", async () => {
		const token = await freshToken();
		expect(await verifyImportToken(`${token}.extra`, SECRET, NOW)).toBeNull();
	});

	it("returns null when the signature is forged", async () => {
		const token = await freshToken();
		const [payload] = token.split(".");
		const forged = `${payload}.AAAAAAAAAAAA`;
		expect(await verifyImportToken(forged, SECRET, NOW)).toBeNull();
	});

	it("returns null when the secret used for verification is different", async () => {
		const token = await freshToken();
		expect(await verifyImportToken(token, "wrong-secret", NOW)).toBeNull();
	});

	it("returns null for an expired token", async () => {
		const issuedAt = new Date("2026-05-15T00:00:00Z");
		const token = (
			await mintToken({ deviceId: "device-vt", secret: SECRET, now: issuedAt, ttlSeconds: 60 })
		).token;
		// 1 hour later: token expired (60s TTL)
		const verifyAt = new Date(issuedAt.getTime() + 60 * 60 * 1000);
		expect(await verifyImportToken(token, SECRET, verifyAt)).toBeNull();
	});

	it("returns null for a token with the wrong scope", async () => {
		// Manually forge a payload + signature with a different scope
		// but the correct signing secret — verification must still
		// reject on the scope check.
		const forgedPayload = {
			d: "device-vt",
			e: Math.floor(NOW.getTime() / 1000) + 3600,
			s: "some-other-scope",
		};
		const payloadJson = JSON.stringify(forgedPayload);
		const payloadB64 = base64urlEncode(new TextEncoder().encode(payloadJson));
		const sig = await hmacBase64Url(SECRET, payloadB64);
		const forgedToken = `${payloadB64}.${sig}`;
		expect(await verifyImportToken(forgedToken, SECRET, NOW)).toBeNull();
	});

	it("returns null when the payload is not valid JSON", async () => {
		const garbagePayload = base64urlEncode(new TextEncoder().encode("not json"));
		const sig = await hmacBase64Url(SECRET, garbagePayload);
		expect(await verifyImportToken(`${garbagePayload}.${sig}`, SECRET, NOW)).toBeNull();
	});

	it("returns null when payload fields are missing", async () => {
		const incomplete = JSON.stringify({ d: "device-vt", s: IMPORT_TOKEN_SCOPE });
		const payloadB64 = base64urlEncode(new TextEncoder().encode(incomplete));
		const sig = await hmacBase64Url(SECRET, payloadB64);
		expect(await verifyImportToken(`${payloadB64}.${sig}`, SECRET, NOW)).toBeNull();
	});
});
