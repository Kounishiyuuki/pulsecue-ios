import type { Context } from "hono";
import { z } from "zod";
import { extractReadableText } from "../parser/extractText";
import { matchMachines, type MachineCandidate } from "../parser/matchMachines";
import { validateOfficialUrl } from "../parser/url";

const BodySchema = z.object({
	gymName: z.string().trim().min(1, "gymName is required").max(200),
	officialUrl: z.string().trim().min(1, "officialUrl is required").max(2048),
});

const FETCH_TIMEOUT_MS = 8_000;
const MAX_RESPONSE_BYTES = 2 * 1024 * 1024;
const USER_AGENT = "PulseCueImportBot/0.1 (+https://github.com/Kounishiyuuki/pulsecue-ios)";

export interface ImportResponse {
	gymName: string;
	officialUrl: string;
	candidates: MachineCandidate[];
	warnings: string[];
}

export async function importGymMachinesHandler(c: Context): Promise<Response> {
	const rawBody = await safeReadJson(c);
	if (!rawBody.ok) {
		return c.json(errorBody("invalid_body", rawBody.message), 400);
	}

	const parsed = BodySchema.safeParse(rawBody.value);
	if (!parsed.success) {
		const message = parsed.error.issues
			.map((issue) => `${issue.path.join(".") || "body"}: ${issue.message}`)
			.join("; ");
		return c.json(errorBody("invalid_body", message), 400);
	}

	const urlCheck = validateOfficialUrl(parsed.data.officialUrl);
	if (!urlCheck.ok) {
		return c.json(errorBody(urlCheck.code, urlCheck.message), 400);
	}

	const fetchResult = await fetchOfficialPage(urlCheck.url);
	if (!fetchResult.ok) {
		return c.json(errorBody("fetch_failed", fetchResult.message), 502);
	}

	const text = extractReadableText(fetchResult.body);
	const candidates = matchMachines(text);
	const warnings: string[] = [];

	if (candidates.length === 0) {
		warnings.push(
			"No known machines were detected. The page may render its machine list with JavaScript or use names outside of our catalog.",
		);
	}
	if (text.length < 200) {
		warnings.push(
			"The page returned very little readable text. Machine names may be loaded dynamically.",
		);
	}

	const response: ImportResponse = {
		gymName: parsed.data.gymName,
		officialUrl: urlCheck.url.toString(),
		candidates,
		warnings,
	};
	return c.json(response);
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

async function fetchOfficialPage(
	url: URL,
): Promise<{ ok: true; body: string } | { ok: false; message: string }> {
	const controller = new AbortController();
	const timeout = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);

	try {
		const response = await fetch(url.toString(), {
			method: "GET",
			redirect: "follow",
			signal: controller.signal,
			headers: {
				"User-Agent": USER_AGENT,
				Accept: "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8",
				"Accept-Language": "ja,en;q=0.8",
			},
		});

		if (!response.ok) {
			return {
				ok: false,
				message: `Upstream returned HTTP ${response.status}`,
			};
		}

		const body = await readBodyWithLimit(response, MAX_RESPONSE_BYTES);
		return { ok: true, body };
	} catch (error) {
		if (error instanceof Error && error.name === "AbortError") {
			return { ok: false, message: "Upstream fetch timed out" };
		}
		return {
			ok: false,
			message: error instanceof Error ? error.message : "Upstream fetch failed",
		};
	} finally {
		clearTimeout(timeout);
	}
}

async function readBodyWithLimit(
	response: Response,
	limit: number,
): Promise<string> {
	const reader = response.body?.getReader();
	if (!reader) return "";
	const decoder = new TextDecoder("utf-8", { fatal: false, ignoreBOM: false });
	let total = 0;
	let result = "";
	while (true) {
		const { value, done } = await reader.read();
		if (done) break;
		if (!value) continue;
		total += value.byteLength;
		if (total > limit) {
			result += decoder.decode(
				value.subarray(0, Math.max(0, value.byteLength - (total - limit))),
				{ stream: false },
			);
			await reader.cancel();
			break;
		}
		result += decoder.decode(value, { stream: true });
	}
	result += decoder.decode();
	return result;
}

function errorBody(code: string, message: string) {
	return { error: { code, message } };
}
