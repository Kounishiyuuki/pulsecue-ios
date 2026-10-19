/**
 * One outbound request to an identity provider, bounded by a single total
 * deadline that covers the response *and* whatever part of its body the
 * caller needs.
 *
 * Why not `Promise.race(fetch, sleep)`: that only stops the caller waiting.
 * The connection and the body reader keep running, and an isolate that sees
 * a slow provider for long enough accumulates them. Here the timer aborts
 * the real request through its `AbortSignal`, which per the Fetch standard
 * also errors a body that is still streaming.
 *
 * The deadline stays live until `consume` has finished, not merely until
 * headers arrive. A provider that sends `200` and then stalls the body is
 * as stuck as one that never answers, and an earlier shape — timeout around
 * `fetch`, then an unbounded `response.text()` — would have hung on it.
 *
 * `consume` is also raced against the abort. That is insurance for a
 * runtime whose body reader does not settle on abort; the underlying
 * request is aborted either way, so the race never leaves work running.
 */

export type ProviderRequestPhase = "before_headers" | "body_read";
export type ProviderRequestReason =
	| "timeout"
	| "transport_error"
	| "body_read_failed";

/**
 * The only error this module throws. It carries fixed codes and nothing
 * else: the original error (an `AbortError`, a socket message) is dropped,
 * so it cannot reach a log line or a client.
 */
export class ProviderRequestError extends Error {
	constructor(
		readonly phase: ProviderRequestPhase,
		readonly reason: ProviderRequestReason,
	) {
		super(`provider request failed: ${phase} ${reason}`);
		this.name = "ProviderRequestError";
	}
}

export async function fetchWithDeadline<T>(
	fetchImpl: typeof fetch,
	url: string,
	init: RequestInit,
	timeoutMs: number,
	consume: (response: Response) => Promise<T>,
): Promise<T> {
	const controller = new AbortController();
	let timedOut = false;
	let rejectOnAbort!: (reason: unknown) => void;
	const aborted = new Promise<never>((_, reject) => {
		rejectOnAbort = reject;
	});
	// Nobody may be awaiting it when the timer fires (the request already
	// failed on its own); that must not surface as an unhandled rejection.
	aborted.catch(() => {});

	const timer = setTimeout(() => {
		timedOut = true;
		controller.abort();
		rejectOnAbort(new Error("deadline exceeded"));
	}, timeoutMs);

	try {
		let response: Response;
		try {
			response = await Promise.race([
				fetchImpl(url, { ...init, signal: controller.signal }),
				aborted,
			]);
		} catch {
			throw new ProviderRequestError(
				"before_headers",
				timedOut ? "timeout" : "transport_error",
			);
		}

		try {
			return await Promise.race([consume(response), aborted]);
		} catch {
			throw new ProviderRequestError(
				"body_read",
				timedOut ? "timeout" : "body_read_failed",
			);
		}
	} finally {
		clearTimeout(timer);
	}
}

/**
 * Releases a body the caller has no use for, without waiting on it.
 *
 * Best effort by design: a decision that is already made from the status
 * line must not depend on whether the provider closes the stream.
 */
export function discardBody(response: Response): void {
	try {
		response.body?.cancel().catch(() => {});
	} catch {
		// A locked or already-closed stream has nothing left to release.
	}
}
