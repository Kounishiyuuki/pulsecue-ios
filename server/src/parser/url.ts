/**
 * URL validation for the gym machine import endpoint. Only http and
 * https schemes are accepted. Hostnames that resolve to obvious local
 * or private addresses are rejected by name to keep the Worker from
 * being used as an SSRF relay; this is a best-effort string check,
 * not a substitute for a properly authenticated egress proxy.
 */

export type UrlValidationResult =
	| { ok: true; url: URL }
	| { ok: false; code: UrlValidationError; message: string };

export type UrlValidationError =
	| "missing"
	| "malformed"
	| "unsupported_scheme"
	| "private_host";

const BLOCKED_HOSTS = new Set([
	"localhost",
	"localhost.localdomain",
	"ip6-localhost",
	"ip6-loopback",
	"broadcasthost",
]);

const BLOCKED_IPV4_PREFIXES = [
	"10.",
	"127.",
	"169.254.",
	"192.168.",
	"0.",
];

export function validateOfficialUrl(input: unknown): UrlValidationResult {
	if (typeof input !== "string" || input.trim().length === 0) {
		return {
			ok: false,
			code: "missing",
			message: "officialUrl is required",
		};
	}

	let parsed: URL;
	try {
		parsed = new URL(input.trim());
	} catch {
		return {
			ok: false,
			code: "malformed",
			message: "officialUrl is not a valid URL",
		};
	}

	if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
		return {
			ok: false,
			code: "unsupported_scheme",
			message: "officialUrl must use http or https",
		};
	}

	if (!parsed.hostname) {
		return {
			ok: false,
			code: "malformed",
			message: "officialUrl is missing a hostname",
		};
	}

	if (isBlockedHost(parsed.hostname)) {
		return {
			ok: false,
			code: "private_host",
			message: "officialUrl points to a local or private host",
		};
	}

	return { ok: true, url: parsed };
}

function isBlockedHost(hostname: string): boolean {
	const lowered = hostname.toLowerCase().replace(/^\[|\]$/g, "");
	if (BLOCKED_HOSTS.has(lowered)) return true;

	if (lowered === "::1" || lowered.startsWith("fe80:") || lowered.startsWith("fc00:") || lowered.startsWith("fd")) {
		return true;
	}

	if (BLOCKED_IPV4_PREFIXES.some((prefix) => lowered.startsWith(prefix))) {
		return true;
	}

	if (lowered.startsWith("172.")) {
		const second = Number.parseInt(lowered.split(".")[1] ?? "", 10);
		if (Number.isFinite(second) && second >= 16 && second <= 31) {
			return true;
		}
	}

	return false;
}
