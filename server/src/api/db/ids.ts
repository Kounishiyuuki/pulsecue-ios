/**
 * Identifier and clock helpers.
 *
 * `now` is injectable everywhere in the repository layer so expiry and
 * revocation can be tested without waiting or mocking global time.
 */

import type { EpochSeconds } from "../types";

/** A v4 UUID from the Workers runtime's Web Crypto. */
export function newId(): string {
	return crypto.randomUUID();
}

/** Current time as unix epoch seconds, UTC. */
export function nowSeconds(): EpochSeconds {
	return Math.floor(Date.now() / 1000);
}
