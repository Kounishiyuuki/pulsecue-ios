/**
 * Carrying out an account deletion.
 *
 * Deletion is local work plus a call to someone else's service, and the two
 * fail differently. The local part — mark the account, revoke the sessions —
 * is immediate and atomic. Revoking the Apple refresh token is a network call
 * that can be down for an hour.
 *
 * The rule the whole file is built around: **a failed provider revocation
 * never puts the account back.** It stays `deleting`, its sessions stay
 * revoked, and the work is retried. Returning a user to `active` because
 * Apple had a bad minute would silently resurrect an account they asked to
 * destroy.
 *
 * `processAccountDeletion` is written to be called from anywhere: the DELETE
 * route calls it once, synchronously, so the common case finishes while the
 * user is still looking at the screen; a future scheduled invocation can call
 * it for whatever is due. No queue or cron exists yet, and none is created
 * here — this is the boundary one would attach to.
 */

import {
	type DeletionErrorCode,
	findAccountDeletion,
	findUserForDeletion,
	hardDeleteUser,
	listDueAccountDeletions,
	recordDeletionAttempt,
} from "../db/accountDeletion";
import { listIdentities } from "../db/accounts";
import type { TokenCipher } from "../crypto/tokenCipher";
import type { EpochSeconds, SqlDatabase } from "../types";
import type { AppleClientSecretConfig } from "./appleClientSecret";
import { revokeAppleIdentityCredential } from "./appleRevocation";

export type DeletionOutcome =
	/** Everything revoked and the user is gone. */
	| { status: "completed" }
	/** A provider is unreachable. The account stays deleting; try later. */
	| { status: "pending"; reason: DeletionErrorCode }
	/** No such deletion in flight — already finished, or never started. */
	| { status: "notPending" };

export interface DeletionDependencies {
	db: SqlDatabase;
	/**
	 * Null when Apple is unconfigured. Deletion then cannot revoke, and says
	 * so rather than pretending it did.
	 */
	appleConfig: AppleClientSecretConfig | null;
	cipher: TokenCipher | null;
	fetchImpl?: typeof fetch;
}

/**
 * Attempts to finish one account's deletion.
 *
 * Order matters: every provider credential is revoked *before* the rows are
 * removed, because removing them first would destroy the only copy of the
 * refresh token and leave the Apple grant alive forever with nothing left to
 * revoke it with.
 */
export async function processAccountDeletion(
	deps: DeletionDependencies,
	userId: string,
	now: EpochSeconds = Math.floor(Date.now() / 1000),
): Promise<DeletionOutcome> {
	const pending = await findAccountDeletion(deps.db, userId);
	if (!pending) return { status: "notPending" };

	const user = await findUserForDeletion(deps.db, userId);
	if (!user) {
		// The user is already gone; the row should have cascaded with it.
		return { status: "completed" };
	}

	const identities = await listIdentities(deps.db, userId);
	let blockedBy: DeletionErrorCode | null = null;

	for (const identity of identities) {
		// Google is not skipped by accident. PulseCue holds no Google refresh
		// token — the ID token flow never issues one — so there is nothing to
		// revoke, and inventing a revocation call for a credential that does
		// not exist would be a fiction. Deleting a PulseCue account is not
		// deleting a Google account, and the identity row goes with the user.
		if (identity.provider !== "apple") continue;

		if (!deps.appleConfig || !deps.cipher) {
			// Unconfigured cannot revoke. Say so and keep the account deleting
			// rather than reporting a revocation that never happened.
			blockedBy = "provider_unavailable";
			continue;
		}

		const outcome = await revokeAppleIdentityCredential({
			db: deps.db,
			cipher: deps.cipher,
			config: deps.appleConfig,
			authIdentityId: identity.id,
			fetchImpl: deps.fetchImpl,
			now,
		});

		if (outcome.status === "retryable") {
			// A 5xx or a network failure may heal; a 4xx usually needs an
			// operator. Neither is evidence the token was revoked, so both
			// block completion — only the recorded code differs, so whoever
			// looks later can tell which they are dealing with.
			blockedBy =
				outcome.reason === "providerRejected"
					? "provider_rejected"
					: "provider_unavailable";
			continue;
		}
		if (outcome.status === "unrevocable") {
			// The stored ciphertext cannot be opened — a lost key, a wrong key
			// version, a corrupt row, or an AAD mismatch.
			//
			// An earlier version deleted the account anyway, reasoning that an
			// unreadable ciphertext is not a usable credential. That reasoning
			// is about *our* copy, and it answers the wrong question. The
			// credential at Apple is unaffected by whether we can read our
			// copy of it: the grant is still live, and hard-deleting here would
			// destroy the only record that it exists while reporting the
			// deletion as complete. Apple's requirement is that the token is
			// revoked, and we would have neither revoked it nor be able to.
			//
			// So the deletion stays owed. The account remains `deleting`, its
			// sessions remain revoked, sign-in remains impossible, and the
			// credential material is kept — because it is the only thing that
			// could ever be recovered if the key is restored. An operator gets
			// a fixed code with no PII in it.
			console.error(
				JSON.stringify({
					event: "account_deletion_credential_unreadable",
					code: "credential_unreadable",
					// No user id, no identity id, no ciphertext.
				}),
			);
			blockedBy = "credential_unreadable";
			continue;
		}
		// "revoked" (an Apple 2xx) and "nothingToRevoke" (no credential ever
		// stored) are the only two outcomes that leave nothing owed.
	}

	if (blockedBy) {
		await recordDeletionAttempt(deps.db, userId, blockedBy, now);
		return { status: "pending", reason: blockedBy };
	}

	// Only now, and only under these conditions:
	//
	//   * every Apple credential was revoked with a confirmed HTTP 2xx, or
	//   * there was no provider credential to revoke in the first place.
	//
	// Google reaches the second case by construction: the ID token flow never
	// issues a refresh token, so there is nothing to revoke and no revocation
	// is invented for it.
	//
	// Anything else set `blockedBy` above and returned already. The cascade
	// therefore cannot destroy a record of an Apple grant that is still live.
	await hardDeleteUser(deps.db, userId);
	return { status: "completed" };
}

/**
 * Retries every deletion that is due.
 *
 * The boundary a scheduled invocation would call. Nothing invokes it yet —
 * creating a Cron trigger is a production resource change and is not part of
 * this work — but it exists, and is tested, so wiring it up later is
 * configuration rather than design.
 */
export async function processDueAccountDeletions(
	deps: DeletionDependencies,
	now: EpochSeconds = Math.floor(Date.now() / 1000),
	limit = 50,
): Promise<{ completed: number; stillPending: number }> {
	const due = await listDueAccountDeletions(deps.db, now, limit);
	let completed = 0;
	let stillPending = 0;

	for (const row of due) {
		const outcome = await processAccountDeletion(deps, row.user_id, now);
		if (outcome.status === "pending") stillPending += 1;
		else completed += 1;
	}

	return { completed, stillPending };
}
