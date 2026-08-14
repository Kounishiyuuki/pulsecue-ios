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

import type { EpochSeconds, SessionRow, SqlDatabase } from "../types";
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

export async function createSession(
	db: SqlDatabase,
	userId: string,
	options: { deviceName?: string | null; now?: EpochSeconds } = {},
): Promise<IssuedSession> {
	const now = options.now ?? nowSeconds();
	const token = generateSessionToken();
	const id = newId();
	await db
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
		)
		.run();
	const session = await findSessionById(db, id);
	if (!session) throw new Error("session insert did not persist");
	return { token, session };
}

/**
 * Resolves a bearer token to a session, or `null` when it is unknown,
 * revoked or expired. The three are deliberately indistinguishable to the
 * caller so a failure cannot be probed for which one it was.
 */
export async function findActiveSessionByToken(
	db: SqlDatabase,
	token: string,
	now: EpochSeconds = nowSeconds(),
): Promise<SessionRow | null> {
	return db
		.prepare(
			`SELECT * FROM sessions
			 WHERE token_sha256 = ? AND revoked_at IS NULL AND expires_at > ?`,
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
