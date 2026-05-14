import { describe, expect, it } from "vitest";
import { validateOfficialUrl } from "../src/parser/url";

describe("validateOfficialUrl", () => {
	it("accepts https URLs", () => {
		const result = validateOfficialUrl("https://example.com/path");
		expect(result.ok).toBe(true);
	});

	it("accepts http URLs", () => {
		const result = validateOfficialUrl("http://example.com");
		expect(result.ok).toBe(true);
	});

	it("rejects missing or empty input", () => {
		expect(validateOfficialUrl(undefined)).toMatchObject({ ok: false, code: "missing" });
		expect(validateOfficialUrl("")).toMatchObject({ ok: false, code: "missing" });
		expect(validateOfficialUrl("   ")).toMatchObject({ ok: false, code: "missing" });
	});

	it("rejects malformed URLs", () => {
		expect(validateOfficialUrl("not a url")).toMatchObject({
			ok: false,
			code: "malformed",
		});
	});

	it("rejects unsupported schemes", () => {
		expect(validateOfficialUrl("file:///etc/passwd")).toMatchObject({
			ok: false,
			code: "unsupported_scheme",
		});
		expect(validateOfficialUrl("ftp://example.com")).toMatchObject({
			ok: false,
			code: "unsupported_scheme",
		});
		expect(validateOfficialUrl("javascript:alert(1)")).toMatchObject({
			ok: false,
			code: "unsupported_scheme",
		});
	});

	it("rejects localhost and private addresses", () => {
		expect(validateOfficialUrl("http://localhost/")).toMatchObject({
			ok: false,
			code: "private_host",
		});
		expect(validateOfficialUrl("http://127.0.0.1/")).toMatchObject({
			ok: false,
			code: "private_host",
		});
		expect(validateOfficialUrl("http://192.168.1.5/")).toMatchObject({
			ok: false,
			code: "private_host",
		});
		expect(validateOfficialUrl("http://10.0.0.1/")).toMatchObject({
			ok: false,
			code: "private_host",
		});
		expect(validateOfficialUrl("http://172.16.0.1/")).toMatchObject({
			ok: false,
			code: "private_host",
		});
	});
});
