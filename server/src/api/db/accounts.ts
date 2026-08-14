/**
 * Repository layer for users, provider identities and profiles.
 *
 * No HTTP, no token verification, no Apple/Google specifics: by the time a
 * function here is called, a caller in PR 2 / PR 3 has already verified a
 * provider token and extracted its `sub`. Keeping verification out of this
 * file is what makes the account rules testable on their own.
 */

import type {
	AuthIdentityRow,
	AuthProvider,
	EpochSeconds,
	SqlDatabase,
	UserRow,
} from "../types";
import { newId, nowSeconds } from "./ids";

export interface IdentityInput {
	provider: AuthProvider;
	/** The provider's `sub`, taken from a server-verified token. */
	subject: string;
	email?: string | null;
	emailVerified?: boolean;
	displayName?: string | null;
}

export interface ResolvedAccount {
	user: UserRow;
	identity: AuthIdentityRow;
	/** True when this call created the user rather than matching one. */
	created: boolean;
}

/**
 * Finds the account for a provider identity, creating one on first sight.
 *
 * Matching is **only** on `(provider, subject)`. Email is stored for display
 * and is never a lookup or merge key: Apple's private relay can hand out a
 * different address for the same person, and trusting an address would let
 * whoever controls it take over an existing account.
 *
 * A returning user updates `last_seen_at` and refreshes the display fields
 * the provider chose to send, but never changes which user they are.
 */
export async function findOrCreateAccountForIdentity(
	db: SqlDatabase,
	input: IdentityInput,
	now: EpochSeconds = nowSeconds(),
): Promise<ResolvedAccount> {
	const existing = await findIdentity(db, input.provider, input.subject);

	if (existing) {
		const user = await requireUser(db, existing.user_id);
		const identity = await touchIdentity(db, existing, input, now);
		return { user, identity, created: false };
	}

	const user = await insertUser(db, now);
	const identity = await insertIdentity(db, user.id, input, now);
	await insertProfile(db, user.id, input.displayName ?? null, now);
	await initialiseChangeSeq(db, user.id);
	return { user, identity, created: true };
}

export async function findIdentity(
	db: SqlDatabase,
	provider: AuthProvider,
	subject: string,
): Promise<AuthIdentityRow | null> {
	return db
		.prepare(
			`SELECT * FROM auth_identities WHERE provider = ? AND subject = ?`,
		)
		.bind(provider, subject)
		.first<AuthIdentityRow>();
}

export async function findUserById(
	db: SqlDatabase,
	userId: string,
): Promise<UserRow | null> {
	return db
		.prepare(`SELECT * FROM users WHERE id = ?`)
		.bind(userId)
		.first<UserRow>();
}

export async function listIdentities(
	db: SqlDatabase,
	userId: string,
): Promise<AuthIdentityRow[]> {
	const { results } = await db
		.prepare(
			`SELECT * FROM auth_identities WHERE user_id = ? ORDER BY created_at ASC`,
		)
		.bind(userId)
		.all<AuthIdentityRow>();
	return results;
}

/**
 * Attaches a second provider to an account the caller is *already*
 * authenticated as. Refuses when the identity belongs to someone else —
 * silently re-pointing it would merge two accounts and lose data.
 */
export async function linkIdentityToUser(
	db: SqlDatabase,
	userId: string,
	input: IdentityInput,
	now: EpochSeconds = nowSeconds(),
): Promise<AuthIdentityRow> {
	const existing = await findIdentity(db, input.provider, input.subject);
	if (existing && existing.user_id !== userId) {
		throw new IdentityAlreadyLinkedError(input.provider);
	}
	if (existing) {
		return touchIdentity(db, existing, input, now);
	}
	await requireUser(db, userId);
	return insertIdentity(db, userId, input, now);
}

export class IdentityAlreadyLinkedError extends Error {
	constructor(readonly provider: AuthProvider) {
		super(`${provider} identity is already linked to another account`);
		this.name = "IdentityAlreadyLinkedError";
	}
}

export class UserNotFoundError extends Error {
	constructor(readonly userId: string) {
		super(`user ${userId} not found`);
		this.name = "UserNotFoundError";
	}
}

/**
 * Marks the account for deletion. Soft first: the rows are purged by a
 * follow-up job so a mistaken request is recoverable and so provider
 * revocation can be retried. Session revocation is the caller's job (PR 7)
 * and must happen in the same request.
 */
export async function markUserDeleting(
	db: SqlDatabase,
	userId: string,
	now: EpochSeconds = nowSeconds(),
): Promise<UserRow> {
	await db
		.prepare(
			`UPDATE users SET state = 'deleting', deleted_at = ?, updated_at = ? WHERE id = ?`,
		)
		.bind(now, now, userId)
		.run();
	return requireUser(db, userId);
}

// MARK: - Internals

async function requireUser(db: SqlDatabase, userId: string): Promise<UserRow> {
	const user = await findUserById(db, userId);
	if (!user) throw new UserNotFoundError(userId);
	return user;
}

async function insertUser(
	db: SqlDatabase,
	now: EpochSeconds,
): Promise<UserRow> {
	const id = newId();
	await db
		.prepare(
			`INSERT INTO users (id, state, created_at, updated_at) VALUES (?, 'active', ?, ?)`,
		)
		.bind(id, now, now)
		.run();
	return requireUser(db, id);
}

async function insertIdentity(
	db: SqlDatabase,
	userId: string,
	input: IdentityInput,
	now: EpochSeconds,
): Promise<AuthIdentityRow> {
	const id = newId();
	await db
		.prepare(
			`INSERT INTO auth_identities
			   (id, user_id, provider, subject, email, email_verified, created_at, last_seen_at)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		)
		.bind(
			id,
			userId,
			input.provider,
			input.subject,
			input.email ?? null,
			input.emailVerified ? 1 : 0,
			now,
			now,
		)
		.run();
	const row = await findIdentity(db, input.provider, input.subject);
	if (!row) throw new Error("identity insert did not persist");
	return row;
}

/**
 * Refreshes display fields and `last_seen_at` on a returning sign-in. A
 * provider that omits the email (Apple after the first authorization) must
 * not blank out what is already stored.
 */
async function touchIdentity(
	db: SqlDatabase,
	existing: AuthIdentityRow,
	input: IdentityInput,
	now: EpochSeconds,
): Promise<AuthIdentityRow> {
	const email = input.email ?? existing.email;
	const emailVerified =
		input.email === undefined || input.email === null
			? existing.email_verified
			: input.emailVerified
				? 1
				: 0;
	await db
		.prepare(
			`UPDATE auth_identities SET email = ?, email_verified = ?, last_seen_at = ? WHERE id = ?`,
		)
		.bind(email, emailVerified, now, existing.id)
		.run();
	const row = await findIdentity(db, existing.provider, existing.subject);
	if (!row) throw new Error("identity update did not persist");
	return row;
}

async function insertProfile(
	db: SqlDatabase,
	userId: string,
	displayName: string | null,
	now: EpochSeconds,
): Promise<void> {
	await db
		.prepare(
			`INSERT INTO user_profiles (user_id, display_name, created_at, updated_at)
			 VALUES (?, ?, ?, ?)`,
		)
		.bind(userId, displayName, now, now)
		.run();
}

async function initialiseChangeSeq(
	db: SqlDatabase,
	userId: string,
): Promise<void> {
	await db
		.prepare(`INSERT INTO user_change_seq (user_id, seq) VALUES (?, 0)`)
		.bind(userId)
		.run();
}
