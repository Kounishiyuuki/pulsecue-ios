/**
 * Opaque server sessions.
 *
 * PulseCue issues a random token and stores only its SHA-256. A database
 * disclosure therefore hands out no usable session, and revocation is a
 * single UPDATE that takes effect on the very next request — which is the
 * whole reason sessions are stored rather than self-contained: unlink and
 * account deletion must invalidate access immediately.
 *
 * The plaintext token exists exactly once, in the response that created it,
 * and lives in the iOS Keychain from then on.
 */

import type {
	EpochSeconds,
	SessionRow,
	SqlDatabase,
	SqlStatement,
	UserRow,
} from "../types";
import { AccountUnavailableError, UserNotFoundError } from "./accounts";
import { newId, nowSeconds } from "./ids";

/** Absolute lifetime. No sliding extension — see `shouldRotate`. */
export const SESSION_TTL_SECONDS = 60 * 24 * 60 * 60; // 60 days

/** 256 bits of randomness, base64url, no padding. */
export function generateSessionToken(): string {
	const bytes = new Uint8Array(32);
	crypto.getRandomValues(bytes);
	let binary = "";
	for (const byte of bytes) binary += String.fromCharCode(byte);
	return btoa(binary)
		.replace(/\+/g, "-")
		.replace(/\//g, "_")
		.replace(/=+$/, "");
}

/** Lowercase hex SHA-256 — the only form ever written to the database. */
export async function hashSessionToken(token: string): Promise<string> {
	const digest = await crypto.subtle.digest(
		"SHA-256",
		new TextEncoder().encode(token),
	);
	return Array.from(new Uint8Array(digest))
		.map((byte) => byte.toString(16).padStart(2, "0"))
		.join("");
}

export interface IssuedSession {
	/** Returned to the client once and never stored in plaintext. */
	token: string;
	session: SessionRow;
}

/**
 * Issues a session, but only for an `active` user.
 *
 * The state test lives in a **trigger** (migration 0003), not in the INSERT.
 * That distinction is the whole point: a guarded `INSERT … WHERE EXISTS`
 * writes zero rows for a `deleting` user and *succeeds*, so a batch
 * containing it commits everything else. The trigger makes the same case a
 * statement failure, which is what a batch can actually roll back.
 */
export async function createSession(
	db: SqlDatabase,
	userId: string,
	options: { deviceName?: string | null; now?: EpochSeconds } = {},
): Promise<IssuedSession> {
	const pending = await prepareSession(db, userId, options);
	try {
		await pending.statement.run();
	} catch (error) {
		throw await explainRefusedSession(db, userId, error);
	}
	return completeSession(db, userId, pending);
}

/**
 * Turns a refused session INSERT into the error the caller expects.
 *
 * The trigger and the foreign key both raise, and they mean different things
 * — being deleted versus never existing — so the state is read back rather
 * than guessed from the driver's message, which differs between D1 and the
 * SQLite double the tests run against.
 */
export async function explainRefusedSession(
	db: SqlDatabase,
	userId: string,
	original: unknown,
): Promise<unknown> {
	const user = await db
		.prepare(`SELECT state FROM users WHERE id = ?`)
		.bind(userId)
		.first<{ state: UserRow["state"] }>();
	if (!user) return new UserNotFoundError(userId);
	if (user.state !== "active") {
		return new AccountUnavailableError(userId, user.state);
	}
	// The user is fine, so this was something else entirely — a constraint
	// elsewhere in the batch, or a real database fault. Do not disguise it as
	// an account problem.
	return original;
}

/**
 * A session INSERT that has been built but not run.
 *
 * Exists so a caller can commit session creation *together with* something
 * else, in one batch. Apple sign-in needs exactly that: the encrypted refresh
 * token must be stored before a session exists, because a session without a
 * stored credential is an account that cannot meet Apple's
 * revoke-on-deletion requirement. Handing out the statement keeps the two
 * atomic without either repository having to know about the other.
 */
export interface PendingSession {
	statement: SqlStatement;
	id: string;
	/** The plaintext token — meaningful only once the insert commits. */
	token: string;
}

export async function prepareSession(
	db: SqlDatabase,
	userId: string,
	options: { deviceName?: string | null; now?: EpochSeconds } = {},
): Promise<PendingSession> {
	const now = options.now ?? nowSeconds();
	const token = generateSessionToken();
	const id = newId();
	// Unconditional on purpose. The `active` check is the trigger in migration
	// 0003, so a refusal is a statement *failure* that rolls a batch back —
	// where the old `WHERE EXISTS` form quietly wrote nothing and let the rest
	// of the batch commit.
	const statement = db
		.prepare(
			`INSERT INTO sessions
			   (id, user_id, token_sha256, created_at, last_used_at, expires_at, device_name)
			 VALUES (?, ?, ?, ?, ?, ?, ?)`,
		)
		.bind(
			id,
			userId,
			await hashSessionToken(token),
			now,
			now,
			now + SESSION_TTL_SECONDS,
			options.deviceName ?? null,
		);
	return { statement, id, token };
}

/** Loads the row a `PendingSession` should have written, or says why not. */
export async function completeSession(
	db: SqlDatabase,
	userId: string,
	pending: PendingSession,
): Promise<IssuedSession> {
	const session = await findSessionById(db, pending.id);
	if (!session) {
		// Either the user does not exist or it is being deleted. Both are a
		// refusal to issue; the caller decides how to answer without leaking
		// which one it was.
		const user = await db
			.prepare(`SELECT state FROM users WHERE id = ?`)
			.bind(userId)
			.first<{ state: UserRow["state"] }>();
		if (!user) throw new UserNotFoundError(userId);
		throw new AccountUnavailableError(userId, user.state);
	}
	return { token: pending.token, session };
}

/**
 * Resolves a bearer token to a session, or `null` when it is unknown,
 * revoked, expired, or owned by an account that is being deleted. All four
 * are deliberately indistinguishable to the caller, so a failed request
 * cannot be probed for which one it was.
 *
 * The join on `users` is what makes deletion fail closed even if a
 * revocation were somehow missed: state is checked on every single
 * authenticated request, not only at revoke time.
 */
export async function findActiveSessionByToken(
	db: SqlDatabase,
	token: string,
	now: EpochSeconds = nowSeconds(),
): Promise<SessionRow | null> {
	return db
		.prepare(
			`SELECT s.* FROM sessions AS s
			 JOIN users AS u ON u.id = s.user_id
			 WHERE s.token_sha256 = ?
			   AND s.revoked_at IS NULL
			   AND s.expires_at > ?
			   AND u.state = 'active'
			   AND u.deleted_at IS NULL`,
		)
		.bind(await hashSessionToken(token), now)
		.first<SessionRow>();
}

export async function findSessionById(
	db: SqlDatabase,
	id: string,
): Promise<SessionRow | null> {
	return db
		.prepare(`SELECT * FROM sessions WHERE id = ?`)
		.bind(id)
		.first<SessionRow>();
}

export async function touchSession(
	db: SqlDatabase,
	id: string,
	now: EpochSeconds = nowSeconds(),
): Promise<void> {
	await db
		.prepare(`UPDATE sessions SET last_used_at = ? WHERE id = ?`)
		.bind(now, id)
		.run();
}

/** Logout. Already-revoked sessions keep their original revocation time. */
export async function revokeSession(
	db: SqlDatabase,
	id: string,
	now: EpochSeconds = nowSeconds(),
): Promise<void> {
	await db
		.prepare(
			`UPDATE sessions SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL`,
		)
		.bind(now, id)
		.run();
}

/**
 * Every session for a user, in one statement. Used by unlink and by account
 * deletion, where leaving even one live session behind would be a real
 * security failure.
 */
export async function revokeAllSessionsForUser(
	db: SqlDatabase,
	userId: string,
	now: EpochSeconds = nowSeconds(),
): Promise<void> {
	await db
		.prepare(
			`UPDATE sessions SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL`,
		)
		.bind(now, userId)
		.run();
}

/**
 * Whether the client should trade this session for a fresh one. Rotation at
 * the halfway mark keeps a regularly-used app signed in without ever
 * extending a session past its absolute expiry.
 */
export function shouldRotate(
	session: SessionRow,
	now: EpochSeconds = nowSeconds(),
): boolean {
	const lifetime = session.expires_at - session.created_at;
	if (lifetime <= 0) return true;
	return now - session.created_at >= lifetime / 2;
}
