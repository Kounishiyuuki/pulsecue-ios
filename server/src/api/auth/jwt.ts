/**
 * The bit of JWT handling this service needs: decode a compact token and
 * verify an RS256 signature against a JWK.
 *
 * Written rather than pulled in because the requirement is narrow — one
 * algorithm, one key format, verification only — and because a JWT library
 * that silently accepts `alg: none` or an HMAC token signed with the public
 * key is the classic way this goes wrong. `verifyRs256` refuses anything
 * that is not RS256 before it touches the signature.
 *
 * Nothing here knows about Apple or Google. Provider rules live next to the
 * provider.
 */

export interface JwtHeader {
	alg: string;
	kid?: string;
	typ?: string;
}

export interface JwtClaims {
	iss?: string;
	sub?: string;
	aud?: string | string[];
	exp?: number;
	iat?: number;
	nonce?: string;
	email?: string;
	/** Apple sends this as a string or a boolean depending on the flow. */
	email_verified?: boolean | string;
	[claim: string]: unknown;
}

export interface DecodedJwt {
	header: JwtHeader;
	claims: JwtClaims;
	/** The `header.payload` bytes the signature covers. */
	signingInput: Uint8Array;
	signature: Uint8Array;
}

export class JwtMalformedError extends Error {
	constructor(reason: string) {
		super(`malformed token: ${reason}`);
		this.name = "JwtMalformedError";
	}
}

export class JwtSignatureError extends Error {
	constructor(reason: string) {
		super(`signature rejected: ${reason}`);
		this.name = "JwtSignatureError";
	}
}

/** Splits and decodes a compact JWT. Performs no validation of its own. */
export function decodeJwt(token: string): DecodedJwt {
	const parts = token.split(".");
	if (parts.length !== 3) {
		throw new JwtMalformedError("expected three dot-separated segments");
	}
	const [headerPart, payloadPart, signaturePart] = parts as [
		string,
		string,
		string,
	];
	if (!headerPart || !payloadPart || !signaturePart) {
		throw new JwtMalformedError("empty segment");
	}

	let header: JwtHeader;
	let claims: JwtClaims;
	try {
		header = JSON.parse(new TextDecoder().decode(base64urlDecode(headerPart)));
		claims = JSON.parse(new TextDecoder().decode(base64urlDecode(payloadPart)));
	} catch {
		throw new JwtMalformedError("segment is not base64url JSON");
	}
	if (typeof header?.alg !== "string") {
		throw new JwtMalformedError("header has no alg");
	}

	return {
		header,
		claims,
		signingInput: new TextEncoder().encode(`${headerPart}.${payloadPart}`),
		signature: base64urlDecode(signaturePart),
	};
}

/**
 * Verifies an RS256 signature against a public JWK.
 *
 * The algorithm is checked against the *header* first and only RS256 is
 * allowed, so `none` and a symmetric algorithm are both rejected before any
 * key material is used.
 */
export async function verifyRs256(
	decoded: DecodedJwt,
	jwk: JsonWebKey,
): Promise<void> {
	if (decoded.header.alg !== "RS256") {
		throw new JwtSignatureError(`unsupported alg ${decoded.header.alg}`);
	}
	let key: CryptoKey;
	try {
		key = await crypto.subtle.importKey(
			"jwk",
			{ ...jwk, alg: "RS256", ext: true, key_ops: ["verify"] },
			{ name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
			false,
			["verify"],
		);
	} catch {
		throw new JwtSignatureError("key could not be imported");
	}

	const ok = await crypto.subtle.verify(
		"RSASSA-PKCS1-v1_5",
		key,
		// `BufferSource` in the Workers types; the copies keep both the Node
		// and Workers lib definitions happy.
		decoded.signature as unknown as BufferSource,
		decoded.signingInput as unknown as BufferSource,
	);
	if (!ok) throw new JwtSignatureError("does not match the key");
}

export function base64urlDecode(value: string): Uint8Array {
	const padded = value.replace(/-/g, "+").replace(/_/g, "/");
	const binary = atob(padded.padEnd(Math.ceil(padded.length / 4) * 4, "="));
	const bytes = new Uint8Array(binary.length);
	for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
	return bytes;
}

export function base64urlEncode(bytes: Uint8Array): string {
	let binary = "";
	for (const byte of bytes) binary += String.fromCharCode(byte);
	return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Lowercase hex SHA-256, used for nonce comparison and nonce storage. */
export async function sha256Hex(value: string): Promise<string> {
	const digest = await crypto.subtle.digest(
		"SHA-256",
		new TextEncoder().encode(value),
	);
	return Array.from(new Uint8Array(digest))
		.map((byte) => byte.toString(16).padStart(2, "0"))
		.join("");
}
