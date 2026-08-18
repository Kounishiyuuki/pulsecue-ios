/**
 * Bindings and shared types for the `pulsecue-api` Worker.
 *
 * This is a separate Worker from `pulsecue-gym-machine-api`. That one is
 * machine-to-machine: a static import key and short-lived HMAC tokens, with
 * no concept of a user. This one owns accounts and per-user data, so its
 * authorization model is entirely different and the two are kept apart
 * rather than sharing a router.
 */

export interface ApiEnv {
	/** D1 binding declared in `wrangler.api.jsonc`. */
	DB: D1Database;
	/**
	 * The bundle identifier Apple issues identity tokens for — the `aud`
	 * every token must carry. Not a secret (it is visible in the app), but
	 * it is environment-specific, so it is configured rather than compiled
	 * in. Verification refuses to run when it is unset: an empty audience
	 * would otherwise mean "accept a token minted for any Apple client".
	 */
	APPLE_AUDIENCE?: string;
	/**
	 * The `aud` every Google ID token must carry: PulseCue's **Web
	 * application ("server") OAuth client id**, the same value the iOS app
	 * sets as `GIDServerClientID`.
	 *
	 * Not the iOS OAuth client id. That one is `GIDClientID` and the reversed
	 * URL scheme on the app side, and it never appears in `aud` — configuring
	 * it here would reject every real token.
	 *
	 * Not a secret (a client id is public), but environment-specific, so it is
	 * configured rather than compiled in. Verification refuses to run when it
	 * is unset: an empty audience would mean "accept a token minted for any
	 * Google client", including one an attacker registered.
	 */
	GOOGLE_AUDIENCE?: string;

	// --- Apple token lifecycle ---
	//
	// These four are required *together* to exchange an authorization code and
	// to revoke a refresh token. None has a value in this repository: the
	// first three are configuration, `APPLE_PRIVATE_KEY` is a Worker secret.
	// With none of them set, Apple sign-in refuses rather than degrading into
	// an account that cannot be deleted per Apple's requirements.

	/** The app's bundle identifier / Services ID. Becomes the secret's `sub`. */
	APPLE_CLIENT_ID?: string;
	/** Apple Developer Team ID. Becomes the client secret's `iss`. */
	APPLE_TEAM_ID?: string;
	/** Key ID of the .p8 signing key. Becomes the client secret's `kid`. */
	APPLE_KEY_ID?: string;
	/**
	 * PKCS#8 PEM text of the .p8 private key. **A Worker secret** — set with
	 * `wrangler secret put`. Never in wrangler.api.jsonc, never committed.
	 */
	APPLE_PRIVATE_KEY?: string;

	/**
	 * Base64 of 32 random bytes: the AES-256-GCM key that encrypts stored
	 * refresh tokens. **A Worker secret.** Unset means Apple sign-in refuses —
	 * storing the token in plaintext is not an alternative.
	 */
	APPLE_TOKEN_ENCRYPTION_KEY?: string;
	/** Defaults to 1. Written into each row so a rotation stays readable. */
	APPLE_TOKEN_ENCRYPTION_KEY_VERSION?: string;
	/** Optional decrypt-only predecessor, for a rotation in progress. */
	APPLE_TOKEN_ENCRYPTION_KEY_PREVIOUS?: string;
	APPLE_TOKEN_ENCRYPTION_KEY_PREVIOUS_VERSION?: string;
}

/**
 * What `requireSession` puts on the context for authenticated handlers.
 *
 * Declared here rather than in the middleware because *every* route shares
 * one Hono env — including the sign-in routes, which never read these. One
 * env keeps handlers interchangeable; the alternative is a cast at every
 * mount point, which is exactly where a type error would have been useful.
 */
export interface AuthVariables {
	session: SessionRow;
	user: UserRow;
}

export type AuthedEnv = { Bindings: ApiEnv; Variables: AuthVariables };

/**
 * The slice of `D1Database` the repositories actually use.
 *
 * Depending on the narrow shape rather than the whole binding is what lets
 * the tests run the real migration against an in-memory SQLite and exercise
 * the real SQL, with no Cloudflare runtime involved.
 */
export interface SqlDatabase {
	prepare(query: string): SqlStatement;
	batch<T = unknown>(statements: SqlStatement[]): Promise<D1Result<T>[]>;
}

export interface SqlStatement {
	bind(...values: unknown[]): SqlStatement;
	first<T = unknown>(): Promise<T | null>;
	all<T = unknown>(): Promise<{ results: T[] }>;
	run(): Promise<unknown>;
}

/** Unix epoch seconds, UTC — the only time representation the schema uses. */
export type EpochSeconds = number;

export type AuthProvider = "apple" | "google";
export type UserState = "active" | "deleting";

export interface UserRow {
	id: string;
	state: UserState;
	created_at: EpochSeconds;
	updated_at: EpochSeconds;
	deleted_at: EpochSeconds | null;
}

export interface AuthIdentityRow {
	id: string;
	user_id: string;
	provider: AuthProvider;
	subject: string;
	email: string | null;
	email_verified: 0 | 1;
	created_at: EpochSeconds;
	last_seen_at: EpochSeconds;
}

export interface UserProfileRow {
	user_id: string;
	display_name: string | null;
	locale: string | null;
	created_at: EpochSeconds;
	updated_at: EpochSeconds;
}

export interface ProviderCredentialRow {
	id: string;
	auth_identity_id: string;
	provider: AuthProvider;
	/** Base64 AES-256-GCM ciphertext. Blank once revoked. */
	encrypted_refresh_token: string;
	/** Base64 96-bit IV, fresh per write. Blank once revoked. */
	encryption_iv: string;
	encryption_key_version: number;
	created_at: EpochSeconds;
	updated_at: EpochSeconds;
	revoked_at: EpochSeconds | null;
}

export interface AccountDeletionRow {
	user_id: string;
	requested_at: EpochSeconds;
	attempts: number;
	last_attempt_at: EpochSeconds | null;
	/** A fixed code from a closed set in code. Never a provider message. */
	last_error_code: string | null;
	next_attempt_at: EpochSeconds;
}

export interface SessionRow {
	id: string;
	user_id: string;
	token_sha256: string;
	created_at: EpochSeconds;
	last_used_at: EpochSeconds;
	expires_at: EpochSeconds;
	revoked_at: EpochSeconds | null;
	device_name: string | null;
}
