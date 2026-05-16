//
//  authImportToken.ts
//  server
//
//  Mint endpoint for short-lived bearer tokens used by the gym
//  machine import flow. Implements `POST /api/auth/import-token` per
//  `Docs/import-token-endpoint-spec.md`.
//
//  This PR is server-only and intentionally leaves the import
//  endpoint's auth (long-lived `PULSECUE_IMPORT_API_KEY` bearer)
//  unchanged. A later PR will teach the import endpoint to also
//  accept signed short-lived tokens minted here, after the App
//  Attest verification path is hardened.
//
//  Attestation validation here is a **placeholder**: any non-empty
//  string is accepted. Production must verify a real App Attest
//  assertion before the Worker is publicly exposed. The placeholder
//  posture is documented in `server/README.md`.
//

import type { Context } from "hono";
import { z } from "zod";
import {
	IMPORT_TOKEN_DEFAULT_TTL_SECONDS,
	mintToken,
} from "../auth/tokens";

const BodySchema = z.object({
	deviceId: z.string().trim().min(1, "deviceId is required").max(200),
	appVersion: z.string().trim().min(1, "appVersion is required").max(100),
	attestation: z.string().trim().min(1, "attestation is required").max(8192),
});

export async function authImportTokenHandler(c: Context): Promise<Response> {
	// 1. Body validation
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
	const { deviceId, appVersion, attestation } = parsed.data;

	// 2. Attestation validation (placeholder).
	//    The schema's `min(1)` already covers missing/empty, but we
	//    keep an explicit guard here so the failure code is the more
	//    specific `invalid_attestation` rather than `invalid_body` —
	//    matching the spec's error table.
	if (attestation.length === 0) {
		return c.json(
			errorBody(
				"invalid_attestation",
				"attestation is required (production builds must send a real App Attest assertion)",
			),
			401,
		);
	}

	// 3. Token secret must be configured.
	const secret = c.env.PULSECUE_IMPORT_TOKEN_SECRET ?? "";
	if (secret.length === 0) {
		console.error("import_token_secret_missing");
		return c.json(
			errorBody(
				"internal_error",
				"Token minting is not configured on this Worker",
			),
			500,
		);
	}

	// 4. Mint. Never logs the token value; only the deviceId hash is
	//    safe to surface here, and only when audit logging is added
	//    in a follow-up.
	try {
		const minted = await mintToken({
			deviceId,
			secret,
			ttlSeconds: IMPORT_TOKEN_DEFAULT_TTL_SECONDS,
		});
		void appVersion; // captured for future audit logging; not used yet
		return c.json({
			token: minted.token,
			expiresAt: minted.expiresAt,
			ttlSeconds: minted.ttlSeconds,
		});
	} catch (error) {
		console.error("token_mint_failed", error);
		return c.json(
			errorBody("internal_error", "Failed to mint token"),
			500,
		);
	}
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

function errorBody(code: string, message: string) {
	return { error: { code, message } };
}
