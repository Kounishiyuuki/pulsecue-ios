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
 * Creation is one atomic batch — user, identity, profile and sync cursor
 * commit together or not at all. Two devices signing in for the first time
 * at the same moment therefore cannot leave an orphan user behind: the
 * loser's whole batch is rolled back by `UNIQUE (provider, subject)`, and it
 * retries as a returning sign-in.
 *
 * Throws `AccountUnavailableError` when the matched account is being
 * deleted, so a deleting user can never be resolved as a normal one.
 */
export async function findOrCreateAccountForIdentity(
	db: SqlDatabase,
	input: IdentityInput,
	now: EpochSeconds = nowSeconds(),
): Promise<ResolvedAccount> {
	const existing = await findIdentity(db, input.provider, input.subject);
	if (existing) {
		return resolveExisting(db, existing, input, now);
	}

	try {
		return await createAccount(db, input, now);
	} catch (error) {
		// Someone else created this identity between our lookup and our
		// insert. The batch rolled back, so nothing partial is left; the
		// only correct answer now is the account they created.
		const raced = await findIdentity(db, input.provider, input.subject);
		if (!raced) throw error;
		return resolveExisting(db, raced, input, now);
	}
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
 * silently re-pointing it would merge two accounts and lose data — and
 * refuses when the target account is being deleted.
 */
export async function linkIdentityToUser(
	db: SqlDatabase,
	userId: string,
	input: IdentityInput,
	now: EpochSeconds = nowSeconds(),
): Promise<AuthIdentityRow> {
	const user = await requireActiveUser(db, userId);
	const existing = await findIdentity(db, input.provider, input.subject);
	if (existing && existing.user_id !== user.id) {
		throw new IdentityAlreadyLinkedError(input.provider);
	}
	if (existing) {
		return touchIdentity(db, existing, input, now);
	}
	return insertIdentity(db, user.id, input, now);
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
 * The account exists but is not usable: deletion has been requested.
 *
 * A distinct type so callers cannot accidentally treat it as a normal
 * account. The HTTP layer must still answer exactly as it does for an
 * unknown account — the distinction is for the code, not for the client,
 * or it becomes an account-enumeration oracle.
 */
export class AccountUnavailableError extends Error {
	constructor(
		readonly userId: string,
		readonly state: UserRow["state"],
	) {
		super(`account ${userId} is not available (state=${state})`);
		this.name = "AccountUnavailableError";
	}
}

/**
 * Marks the account for deletion **and** revokes every one of its sessions
 * in the same atomic batch.
 *
 * The two must not drift apart. A user left `deleting` with a live session
 * is an authentication bypass; an `active` user whose sessions were all
 * revoked is a silent lockout. Committing them together makes both states
 * unreachable.
 */
export async function markUserDeleting(
	db: SqlDatabase,
	userId: string,
	now: EpochSeconds = nowSeconds(),
): Promise<UserRow> {
	await requireUser(db, userId);
	await db.batch([
		db
			.prepare(
				`UPDATE users SET state = 'deleting', deleted_at = ?, updated_at = ? WHERE id = ?`,
			)
			.bind(now, now, userId),
		db
			.prepare(
				`UPDATE sessions SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL`,
			)
			.bind(now, userId),
	]);
	return requireUser(db, userId);
}

/** Loads a user and refuses anything that is not `active`. */
export async function requireActiveUser(
	db: SqlDatabase,
	userId: string,
): Promise<UserRow> {
	const user = await requireUser(db, userId);
	if (user.state !== "active") {
		throw new AccountUnavailableError(user.id, user.state);
	}
	return user;
}

// MARK: - Internals

async function resolveExisting(
	db: SqlDatabase,
	identity: AuthIdentityRow,
	input: IdentityInput,
	now: EpochSeconds,
): Promise<ResolvedAccount> {
	const user = await requireActiveUser(db, identity.user_id);
	const touched = await touchIdentity(db, identity, input, now);
	return { user, identity: touched, created: false };
}

/**
 * One batch, four rows. If any statement fails — most likely the unique
 * index on `(provider, subject)` under a concurrent first sign-in — D1
 * rolls the whole batch back, so there is never a user without a profile
 * or a sync cursor for a later request to trip over.
 */
async function createAccount(
	db: SqlDatabase,
	input: IdentityInput,
	now: EpochSeconds,
): Promise<ResolvedAccount> {
	const userId = newId();
	const identityId = newId();

	await db.batch([
		db
			.prepare(
				`INSERT INTO users (id, state, created_at, updated_at) VALUES (?, 'active', ?, ?)`,
			)
			.bind(userId, now, now),
		db
			.prepare(
				`INSERT INTO auth_identities
				   (id, user_id, provider, subject, email, email_verified, created_at, last_seen_at)
				 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			)
			.bind(
				identityId,
				userId,
				input.provider,
				input.subject,
				input.email ?? null,
				input.emailVerified ? 1 : 0,
				now,
				now,
			),
		db
			.prepare(
				`INSERT INTO user_profiles (user_id, display_name, created_at, updated_at)
				 VALUES (?, ?, ?, ?)`,
			)
			.bind(userId, input.displayName ?? null, now, now),
		db
			.prepare(`INSERT INTO user_change_seq (user_id, seq) VALUES (?, 0)`)
			.bind(userId),
	]);

	const user = await requireUser(db, userId);
	const identity = await findIdentity(db, input.provider, input.subject);
	if (!identity) throw new Error("identity insert did not persist");
	return { user, identity, created: true };
}

async function requireUser(db: SqlDatabase, userId: string): Promise<UserRow> {
	const user = await findUserById(db, userId);
	if (!user) throw new UserNotFoundError(userId);
	return user;
}

async function insertIdentity(
	db: SqlDatabase,
	userId: string,
	input: IdentityInput,
	now: EpochSeconds,
): Promise<AuthIdentityRow> {
	await db
		.prepare(
			`INSERT INTO auth_identities
			   (id, user_id, provider, subject, email, email_verified, created_at, last_seen_at)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		)
		.bind(
			newId(),
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
