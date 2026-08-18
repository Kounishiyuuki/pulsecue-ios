/**
 * Repository for encrypted provider refresh tokens.
 *
 * Nothing here ever sees a plaintext token except as a function argument on
 * the way in or out of `TokenCipher`. Rows carry ciphertext, a per-write IV
 * and the key version; the AAD binds each ciphertext to the identity it was
 * written for, so a row moved to another identity fails to open rather than
 * revoking the wrong person's Apple account.
 */

import type {
	AuthProvider,
	EpochSeconds,
	ProviderCredentialRow,
	SqlDatabase,
	SqlStatement,
} from "../types";
import {
	type TokenCipher,
	TokenDecryptError,
} from "../crypto/tokenCipher";
import { newId, nowSeconds } from "./ids";
import {
	type IssuedSession,
	type PendingSession,
	completeSession,
	explainRefusedSession,
	prepareSession,
} from "./sessions";

/**
 * What the stored token is for. Part of the AAD, so a credential kept for one
 * purpose cannot be opened as if it were kept for another.
 */
export const REFRESH_TOKEN_PURPOSE = "provider-refresh-token";

export async function findCredentialForIdentity(
	db: SqlDatabase,
	authIdentityId: string,
): Promise<ProviderCredentialRow | null> {
	return db
		.prepare(`SELECT * FROM provider_credentials WHERE auth_identity_id = ?`)
		.bind(authIdentityId)
		.first<ProviderCredentialRow>();
}

export interface CredentialInput {
	authIdentityId: string;
	provider: AuthProvider;
	refreshToken: string;
}

/**
 * Builds the upsert for a credential, encrypting on the way.
 *
 * Returned rather than run so the caller can commit it in the same batch as
 * whatever else must land with it. A repeat sign-in replaces the row — and
 * gets a fresh IV, because re-encrypting under a reused IV is how AES-GCM
 * stops protecting anything.
 */
export async function prepareCredentialUpsert(
	db: SqlDatabase,
	cipher: TokenCipher,
	input: CredentialInput,
	now: EpochSeconds = nowSeconds(),
): Promise<SqlStatement> {
	const sealed = await cipher.seal(input.refreshToken, {
		authIdentityId: input.authIdentityId,
		provider: input.provider,
		purpose: REFRESH_TOKEN_PURPOSE,
	});

	return db
		.prepare(
			`INSERT INTO provider_credentials
			   (id, auth_identity_id, provider, encrypted_refresh_token,
			    encryption_iv, encryption_key_version, created_at, updated_at, revoked_at)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
			 ON CONFLICT (auth_identity_id) DO UPDATE SET
			   -- Re-asserted on update, not only on insert. Without this the
			   -- conflict path keeps the row's existing provider, so the
			   -- foreign key never sees a mismatch — and a caller passing the
			   -- wrong provider would silently overwrite the ciphertext with
			   -- one sealed under a different AAD, leaving a row nobody can
			   -- decrypt. Setting it makes the constraint fire and the whole
			   -- statement fail, so the stored credential survives intact.
			   provider                = excluded.provider,
			   encrypted_refresh_token = excluded.encrypted_refresh_token,
			   encryption_iv           = excluded.encryption_iv,
			   encryption_key_version  = excluded.encryption_key_version,
			   updated_at              = excluded.updated_at,
			   -- A fresh sign-in un-revokes: there is a live credential again.
			   revoked_at              = NULL`,
		)
		.bind(
			newId(),
			input.authIdentityId,
			input.provider,
			sealed.ciphertext,
			sealed.iv,
			sealed.keyVersion,
			now,
			now,
		);
}

/**
 * Stores the credential and issues a session **in one batch**.
 *
 * The ordering rule this enforces is the important part: a live session must
 * never exist for an account whose provider credential was not stored. Apple
 * requires revocation at account deletion, and revocation needs the refresh
 * token — so a session without one is an account that cannot be deleted
 * properly. D1 rolls the batch back if either statement fails, which makes
 * the half-state unreachable rather than merely unlikely.
 */
export async function saveCredentialAndIssueSession(
	db: SqlDatabase,
	cipher: TokenCipher,
	params: {
		userId: string;
		credential: CredentialInput;
		deviceName?: string | null;
		now?: EpochSeconds;
	},
): Promise<IssuedSession> {
	const now = params.now ?? nowSeconds();
	const upsert = await prepareCredentialUpsert(db, cipher, params.credential, now);
	const pending: PendingSession = await prepareSession(db, params.userId, {
		deviceName: params.deviceName ?? null,
		now,
	});

	try {
		await db.batch([upsert, pending.statement]);
	} catch (error) {
		// The session INSERT raising is what makes this atomic. A `deleting`
		// user trips the trigger from migration 0003, the batch rolls back,
		// and the credential UPSERT goes with it — where the old guarded
		// INSERT wrote zero rows, succeeded, and left the credential
		// committed with no session beside it.
		throw await explainRefusedSession(db, params.userId, error);
	}
	return completeSession(db, params.userId, pending);
}

/**
 * Opens a stored credential.
 *
 * Returns `null` when there is nothing to revoke — no row, or one already
 * revoked. Throws `TokenDecryptError` when a row exists but cannot be read,
 * which is a real problem the caller must not silently treat as "no
 * credential": that would report a revocation that never happened.
 */
export async function readRefreshToken(
	db: SqlDatabase,
	cipher: TokenCipher,
	authIdentityId: string,
): Promise<string | null> {
	const row = await findCredentialForIdentity(db, authIdentityId);
	if (!row || row.revoked_at !== null) return null;
	if (row.encrypted_refresh_token.length === 0) return null;

	return cipher.open(
		{
			ciphertext: row.encrypted_refresh_token,
			iv: row.encryption_iv,
			keyVersion: row.encryption_key_version,
		},
		{
			authIdentityId: row.auth_identity_id,
			provider: row.provider,
			purpose: REFRESH_TOKEN_PURPOSE,
		},
	);
}

/**
 * Marks the credential revoked and erases the material in the same statement.
 *
 * The row is kept, blank, rather than deleted: a deletion retry needs to be
 * able to tell "already revoked" from "never had one", and an empty
 * ciphertext cannot be decrypted back into a usable Apple credential no
 * matter who reads the table later.
 */
export async function markCredentialRevoked(
	db: SqlDatabase,
	authIdentityId: string,
	now: EpochSeconds = nowSeconds(),
): Promise<void> {
	await db
		.prepare(
			`UPDATE provider_credentials
			    SET encrypted_refresh_token = '',
			        encryption_iv           = '',
			        revoked_at              = ?,
			        updated_at              = ?
			  WHERE auth_identity_id = ? AND revoked_at IS NULL`,
		)
		.bind(now, now, authIdentityId)
		.run();
}

/** Removes the row outright. Used by hard delete, where nothing is kept. */
export async function deleteCredentialsForIdentity(
	db: SqlDatabase,
	authIdentityId: string,
): Promise<void> {
	await db
		.prepare(`DELETE FROM provider_credentials WHERE auth_identity_id = ?`)
		.bind(authIdentityId)
		.run();
}

export { TokenDecryptError };
