/**
 * `DELETE /v1/me` — the user destroys their PulseCue account.
 *
 * Two things happen in a fixed order, and the order is the design:
 *
 *   1. The account becomes `deleting` and **every session is revoked**, in
 *      one commit. From this instant the account cannot be signed into or
 *      used, whatever happens next.
 *   2. Provider revocation is attempted once, synchronously, so the common
 *      case finishes while the user is still on the screen.
 *
 * If step 2 fails the answer is `202 Accepted`, not an error: the deletion is
 * real and irreversible from the user's point of view, it is simply not
 * finished. **The account is never returned to `active`.** Rolling back
 * because Apple had a bad minute would resurrect an account the user asked to
 * destroy.
 *
 * Retrying the HTTP call is safe and, in practice, impossible: step 1 revoked
 * the session that authorised this request, so a second attempt cannot even
 * authenticate. A client seeing `401` after a delete should read it as done.
 */

import type { Context } from "hono";
import {
	type DeletionDependencies,
	processAccountDeletion,
} from "../auth/accountDeletionService";
import { requestAccountDeletion } from "../db/accountDeletion";
import { newId } from "../db/ids";
import type { AuthedEnv } from "../types";

export interface DeleteMeDependencies {
	appleConfig: DeletionDependencies["appleConfig"];
	cipher: DeletionDependencies["cipher"];
	fetchImpl?: typeof fetch;
	now?: () => number;
}

export function makeDeleteMeHandler(deps: DeleteMeDependencies) {
	return async (c: Context<AuthedEnv>) => {
		const user = c.get("user");
		const now = deps.now?.() ?? Math.floor(Date.now() / 1000);
		const correlationId = newId();

		// The whole handler is two phases, and which one failed decides what
		// the client is told. `transitionCommitted` is the boundary between
		// them, kept as an explicit value rather than implied by control flow.
		let transitionCommitted = false;
		let outcome: Awaited<ReturnType<typeof processAccountDeletion>>;

		try {
			// ── PHASE 1: the durable transition ───────────────────────────
			//
			// One batch: the account becomes `deleting` and every session is
			// revoked. Until it commits nothing has been accepted — a failure
			// rolls the batch back, so the account is still `active` and the
			// request genuinely did not happen.
			await requestAccountDeletion(c.env.DB, user.id, now);
			transitionCommitted = true;

			// ── PHASE 2: processing ───────────────────────────────────────
			//
			// From here the deletion IS durably accepted: the account is
			// `deleting`, every session including the caller's is revoked, and
			// the tracking row exists for a future retry.
			outcome = await processAccountDeletion(
				{
					db: c.env.DB,
					appleConfig: deps.appleConfig,
					cipher: deps.cipher,
					fetchImpl: deps.fetchImpl,
				},
				user.id,
				now,
			);
		} catch (error) {
			if (!transitionCommitted) {
				// Phase 1 failed. Nothing was accepted and nothing was
				// changed, so this is a genuine service failure and is allowed
				// to surface as one. Reporting an un-accepted deletion as
				// accepted would be the worse lie of the two, and the caller's
				// session still works so they can retry.
				throw error;
			}

			// Phase 2 failed *after* the transition committed. The request
			// succeeded; it simply has not finished. A 500 here would tell the
			// user their deletion failed while their account is already
			// `deleting` and every session is dead — the response contradicting
			// the state is the bug.
			console.error(
				JSON.stringify({
					event: "account_deletion_processing_failed",
					correlationId,
					// Deliberately absent: user id, provider subject, email,
					// credential material, and the underlying error — repository
					// errors quote the values they failed on.
				}),
			);
			return acceptedButPending(c, correlationId);
		}

		if (outcome.status === "pending") {
			console.warn(
				JSON.stringify({
					event: "account_deletion_pending",
					reason: outcome.reason,
					correlationId,
					// Deliberately absent: user id, provider subject, email.
				}),
			);
			return acceptedButPending(c, correlationId);
		}

		return c.json({ status: "deleted" });
	};
}

/**
 * `202`: the deletion is durably accepted and irreversible, and not finished.
 *
 * Never says "deleted" or "completed". The caller's session is already gone,
 * so retrying the same bearer answers `401` — this response is the one and
 * only acknowledgement that the request was accepted, and it has to be
 * truthful about what has and has not happened.
 */
function acceptedButPending(c: Context<AuthedEnv>, correlationId: string) {
	return c.json(
		{
			status: "pending",
			// Worded so no substring of this response can be mistaken for a
			// completion claim — "being deleted" reads as "deleted" to a naive
			// client check, and this is the one response that must never be
			// over-read.
			message: "Your account deletion is in progress",
			correlationId,
		},
		202,
	);
}
