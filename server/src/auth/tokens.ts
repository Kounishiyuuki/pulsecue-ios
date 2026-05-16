//
//  tokens.ts
//  server
//
//  Pure helpers for the short-lived import-token mint endpoint. The
//  token is a compact `<payload>.<signature>` envelope:
//
//    payload = base64url(JSON.stringify({ d, e, s }))
//      d: deviceId from the request
//      e: expiry (unix seconds, UTC)
//      s: scope, hard-coded to "gym-machines:import"
//    signature = base64url(HMAC-SHA256(payload, PULSECUE_IMPORT_TOKEN_SECRET))
//
//  Goals:
//   - **Different from `PULSECUE_IMPORT_API_KEY`** by both content and
//     format (the long-lived key has no dot separator).
//   - Statelessly verifiable by a future PR — the import endpoint can
//     re-HMAC the payload to validate, without storing anything.
//   - No PII beyond the deviceId the caller supplied.
//
//  This file deliberately does not touch the Hono context or any I/O
//  so it can be unit-tested in isolation.
//

export const IMPORT_TOKEN_SCOPE = "gym-machines:import";
export const IMPORT_TOKEN_DEFAULT_TTL_SECONDS = 86_400;

export interface MintedToken {
	/// Bearer string the client sends as `Authorization: Bearer <token>`.
	token: string;
	/// ISO 8601 expiry timestamp in UTC.
	expiresAt: string;
	/// Seconds from `now` until `expiresAt`. Always equals `ttlSeconds`
	/// passed into `mintToken` (or the default), never `expiresAt - now`
	/// to avoid sub-second drift between fields.
	ttlSeconds: number;
}

interface MintTokenInput {
	deviceId: string;
	secret: string;
	now?: Date;
	ttlSeconds?: number;
}

/// Returns a freshly-minted, signed bearer token for the given device.
/// Throws if `secret` is empty (fail-closed: a missing secret must
/// never produce a token that the import endpoint cannot later
/// verify).
export async function mintToken({
	deviceId,
	secret,
	now = new Date(),
	ttlSeconds = IMPORT_TOKEN_DEFAULT_TTL_SECONDS,
}: MintTokenInput): Promise<MintedToken> {
	if (secret.length === 0) {
		throw new Error("PULSECUE_IMPORT_TOKEN_SECRET is empty");
	}
	if (deviceId.length === 0) {
		throw new Error("deviceId is empty");
	}

	const expirySeconds = Math.floor(now.getTime() / 1000) + ttlSeconds;
	const payloadJson = JSON.stringify({
		d: deviceId,
		e: expirySeconds,
		s: IMPORT_TOKEN_SCOPE,
	});

	const payloadB64 = base64urlEncode(new TextEncoder().encode(payloadJson));
	const signatureB64 = await hmacBase64Url(secret, payloadB64);
	const token = `${payloadB64}.${signatureB64}`;

	return {
		token,
		expiresAt: new Date(expirySeconds * 1000).toISOString(),
		ttlSeconds,
	};
}

/// Lower-level HMAC helper exposed for tests; verifies that two
/// independent calls with the same secret + payload produce the
/// same signature.
export async function hmacBase64Url(secret: string, message: string): Promise<string> {
	const encoder = new TextEncoder();
	const key = await crypto.subtle.importKey(
		"raw",
		encoder.encode(secret),
		{ name: "HMAC", hash: "SHA-256" },
		false,
		["sign"],
	);
	const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(message));
	return base64urlEncode(new Uint8Array(signature));
}

export function base64urlEncode(bytes: Uint8Array): string {
	let binary = "";
	for (let i = 0; i < bytes.length; i += 1) {
		binary += String.fromCharCode(bytes[i] ?? 0);
	}
	const standard = btoa(binary);
	return standard.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
