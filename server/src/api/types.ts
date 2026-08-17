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
	 * The PulseCue iOS OAuth client id Google issues ID tokens for — the
	 * `aud` every token must carry. Not a secret (it is visible in the app's
	 * URL scheme), but environment-specific, so it is configured rather than
	 * compiled in. Verification refuses to run when it is unset: an empty
	 * audience would mean "accept a token minted for any Google client",
	 * including one an attacker registered.
	 */
	GOOGLE_AUDIENCE?: string;
}

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
