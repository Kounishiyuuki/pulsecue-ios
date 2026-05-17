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

export function base64urlDecode(input: string): Uint8Array | null {
	if (input.length === 0) return null;
	const standard = input.replace(/-/g, "+").replace(/_/g, "/");
	// btoa/atob require padding to a multiple of 4.
	const padded = standard.padEnd(Math.ceil(standard.length / 4) * 4, "=");
	let binary: string;
	try {
		binary = atob(padded);
	} catch {
		return null;
	}
	const bytes = new Uint8Array(binary.length);
	for (let i = 0; i < binary.length; i += 1) {
		bytes[i] = binary.charCodeAt(i) & 0xff;
	}
	return bytes;
}

/// Parsed payload returned by `verifyImportToken` on success.
/// Callers receive only safe, structured fields; the raw signature
/// is never re-exposed.
export interface ImportTokenPayload {
	deviceId: string;
	expiresAtUnixSeconds: number;
	scope: typeof IMPORT_TOKEN_SCOPE;
}

/// Verifies a `<base64url-payload>.<base64url-signature>` import
/// token minted by `mintToken`. Returns the parsed payload on
/// success, `null` on **any** failure (malformed, bad signature,
/// wrong scope, expired, missing secret, etc.).
///
/// Failure-mode rationale: callers are expected to treat `null` as
/// "401 unauthorized" without surfacing why. Encoding distinct error
/// reasons would leak how the token validator scores partial matches
/// (signature vs scope vs expiry), making targeted forgery easier.
export async function verifyImportToken(
	token: string,
	secret: string,
	now: Date = new Date(),
): Promise<ImportTokenPayload | null> {
	if (typeof token !== "string" || token.length === 0) return null;
	if (typeof secret !== "string" || secret.length === 0) return null;

	const parts = token.split(".");
	if (parts.length !== 2) return null;
	const payloadB64 = parts[0];
	const signatureB64 = parts[1];
	if (!payloadB64 || !signatureB64) return null;

	const signatureBytes = base64urlDecode(signatureB64);
	if (signatureBytes === null) return null;

	const encoder = new TextEncoder();
	let key: CryptoKey;
	try {
		key = await crypto.subtle.importKey(
			"raw",
			encoder.encode(secret),
			{ name: "HMAC", hash: "SHA-256" },
			false,
			["verify"],
		);
	} catch {
		return null;
	}

	let signatureValid: boolean;
	try {
		// `crypto.subtle.verify` is constant-time inside the runtime;
		// returns `false` for both length mismatch and content mismatch
		// without leaking which.
		signatureValid = await crypto.subtle.verify(
			"HMAC",
			key,
			signatureBytes,
			encoder.encode(payloadB64),
		);
	} catch {
		return null;
	}
	if (!signatureValid) return null;

	const payloadBytes = base64urlDecode(payloadB64);
	if (payloadBytes === null) return null;

	let parsed: unknown;
	try {
		parsed = JSON.parse(new TextDecoder().decode(payloadBytes));
	} catch {
		return null;
	}
	if (typeof parsed !== "object" || parsed === null) return null;
	const obj = parsed as { d?: unknown; e?: unknown; s?: unknown };

	if (typeof obj.d !== "string" || obj.d.length === 0) return null;
	if (typeof obj.e !== "number" || !Number.isFinite(obj.e)) return null;
	if (obj.s !== IMPORT_TOKEN_SCOPE) return null;

	const nowSeconds = Math.floor(now.getTime() / 1000);
	if (obj.e <= nowSeconds) return null;

	return {
		deviceId: obj.d,
		expiresAtUnixSeconds: obj.e,
		scope: IMPORT_TOKEN_SCOPE,
	};
}
