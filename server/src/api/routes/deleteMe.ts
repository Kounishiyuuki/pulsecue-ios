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

		// Irreversible from here. Sessions die first so that nothing can act
		// as this user while revocation is in flight.
		await requestAccountDeletion(c.env.DB, user.id, now);

		const outcome = await processAccountDeletion(
			{
				db: c.env.DB,
				appleConfig: deps.appleConfig,
				cipher: deps.cipher,
				fetchImpl: deps.fetchImpl,
			},
			user.id,
			now,
		);

		if (outcome.status === "pending") {
			console.warn(
				JSON.stringify({
					event: "account_deletion_pending",
					reason: outcome.reason,
					correlationId,
					// Deliberately absent: user id, provider subject, email.
				}),
			);
			return c.json(
				{
					status: "pending",
					message: "Your account is being deleted",
					correlationId,
				},
				202,
			);
		}

		return c.json({ status: "deleted" });
	};
}
