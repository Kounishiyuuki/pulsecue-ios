/**
 * The Apple client secret: an ES256 JWT PulseCue signs about itself.
 *
 * Apple's token and revoke endpoints do not take a static shared secret.
 * They take a short-lived JWT signed with the `.p8` private key from the
 * developer account, which is what proves the caller is this app's team.
 * The shape is fixed by Apple:
 *
 *   header  alg ES256, kid = the Key ID of the .p8
 *   iss     the Team ID
 *   aud     https://appleid.apple.com
 *   sub     the client id (the app's bundle identifier / Services ID)
 *   iat/exp a validity window, at most six months
 *
 * PulseCue mints a short-lived one per request rather than caching a
 * six-month secret. A secret that lives for minutes cannot be replayed for
 * half a year if a log or a heap dump ever leaks it, and minting is a single
 * ECDSA signature.
 *
 * The private key never appears in this repository. It arrives as a Worker
 * secret holding the PKCS#8 PEM text of the .p8, and the tests generate
 * their own throwaway P-256 keypair so the production signing path runs
 * without any Apple credential existing.
 */

import { base64urlEncode } from "./jwt";

export const APPLE_TOKEN_AUDIENCE = "https://appleid.apple.com";

/** Apple caps the secret at six months; minutes is all that is needed. */
export const CLIENT_SECRET_TTL_SECONDS = 5 * 60;

export class AppleClientSecretConfigError extends Error {
	constructor(reason: string) {
		// Never quotes the key, or any part of it.
		super(`apple client secret is not configured: ${reason}`);
		this.name = "AppleClientSecretConfigError";
	}
}

export interface AppleClientSecretConfig {
	/** The app's bundle identifier / Services ID. Becomes `sub`. */
	clientId: string;
	/** Apple Developer Team ID. Becomes `iss`. */
	teamId: string;
	/** Key ID of the .p8. Becomes the header `kid`. */
	keyId: string;
	/** PKCS#8 PEM text of the .p8 private key. A Worker secret. */
	privateKeyPem: string;
}

/**
 * Reads the config, or returns `null` when Apple is simply not configured
 * for this deployment.
 *
 * Null is not "allow anything": the caller refuses the whole flow. It exists
 * so a local or test deployment without Apple credentials boots normally
 * instead of crashing, while still being unable to sign anyone in.
 *
 * A *partial* config throws instead — half-configured is a mistake someone
 * made, and failing loudly beats silently behaving like "not configured".
 */
export function appleClientSecretConfigFromEnv(env: {
	APPLE_CLIENT_ID?: string;
	APPLE_TEAM_ID?: string;
	APPLE_KEY_ID?: string;
	APPLE_PRIVATE_KEY?: string;
}): AppleClientSecretConfig | null {
	const parts = {
		clientId: env.APPLE_CLIENT_ID ?? "",
		teamId: env.APPLE_TEAM_ID ?? "",
		keyId: env.APPLE_KEY_ID ?? "",
		privateKeyPem: env.APPLE_PRIVATE_KEY ?? "",
	};
	const present = Object.values(parts).filter((value) => value.length > 0);
	if (present.length === 0) return null;
	if (present.length !== 4) {
		const missing = Object.entries(parts)
			.filter(([, value]) => value.length === 0)
			.map(([name]) => name)
			.join(", ");
		throw new AppleClientSecretConfigError(`missing ${missing}`);
	}
	return parts;
}

/** Signs one client secret. `now` is injectable so the window is testable. */
export async function createAppleClientSecret(
	config: AppleClientSecretConfig,
	now: number = Math.floor(Date.now() / 1000),
): Promise<string> {
	const key = await importPkcs8EcKey(config.privateKeyPem);

	const header = base64urlEncode(
		new TextEncoder().encode(
			JSON.stringify({ alg: "ES256", kid: config.keyId, typ: "JWT" }),
		),
	);
	const claims = base64urlEncode(
		new TextEncoder().encode(
			JSON.stringify({
				iss: config.teamId,
				iat: now,
				exp: now + CLIENT_SECRET_TTL_SECONDS,
				aud: APPLE_TOKEN_AUDIENCE,
				sub: config.clientId,
			}),
		),
	);
	const signingInput = `${header}.${claims}`;

	// WebCrypto emits the raw r‖s pair for ECDSA, which is exactly what JWS
	// ES256 wants — no DER unwrapping, unlike most server-side crypto stacks.
	const signature = await crypto.subtle.sign(
		{ name: "ECDSA", hash: "SHA-256" },
		key,
		new TextEncoder().encode(signingInput) as unknown as BufferSource,
	);

	return `${signingInput}.${base64urlEncode(new Uint8Array(signature))}`;
}

async function importPkcs8EcKey(pem: string): Promise<CryptoKey> {
	const body = pem
		.replace(/-----BEGIN [A-Z ]*PRIVATE KEY-----/, "")
		.replace(/-----END [A-Z ]*PRIVATE KEY-----/, "")
		.replace(/\s+/g, "");
	if (body.length === 0) {
		throw new AppleClientSecretConfigError("private key is empty");
	}

	let der: Uint8Array;
	try {
		const binary = atob(body);
		der = new Uint8Array(binary.length);
		for (let i = 0; i < binary.length; i += 1) der[i] = binary.charCodeAt(i);
	} catch {
		throw new AppleClientSecretConfigError("private key is not base64 PEM");
	}

	try {
		return await crypto.subtle.importKey(
			"pkcs8",
			der as unknown as BufferSource,
			{ name: "ECDSA", namedCurve: "P-256" },
			false,
			["sign"],
		);
	} catch {
		throw new AppleClientSecretConfigError("private key is not a P-256 PKCS#8 key");
	}
}
