/**
 * In-memory stand-ins for the Workers Rate Limiting bindings.
 *
 * Each one counts per key against its own limit — the semantics of one
 * `namespace_id` — and records every call in one shared, ordered log, so a
 * test can assert which limiter ran, with which key, and in what order
 * relative to D1 and the handler.
 */

import type { ApiEnv } from "../../../src/api/types";

export const PRODUCTION_LIMITS = {
	API_IP_RATE_LIMITER: 300,
	AUTH_IP_RATE_LIMITER: 60,
	SYNC_USER_RATE_LIMITER: 30,
	ACCOUNT_USER_RATE_LIMITER: 10,
} as const;

export type LimiterName = keyof typeof PRODUCTION_LIMITS;

export interface LimiterCall {
	binding: LimiterName;
	key: string;
}

export interface FakeRateLimiters {
	bindings: Pick<ApiEnv, LimiterName>;
	calls: LimiterCall[];
	callsTo(binding: LimiterName): LimiterCall[];
}

export function fakeRateLimiters(
	limits: Record<LimiterName, number> = PRODUCTION_LIMITS,
	onCall?: (call: LimiterCall) => void,
): FakeRateLimiters {
	const calls: LimiterCall[] = [];
	const make = (binding: LimiterName): RateLimit => {
		const counts = new Map<string, number>();
		return {
			async limit({ key }) {
				const call = { binding, key };
				calls.push(call);
				onCall?.(call);
				const n = (counts.get(key) ?? 0) + 1;
				counts.set(key, n);
				return { success: n <= limits[binding] };
			},
		};
	};
	return {
		bindings: {
			API_IP_RATE_LIMITER: make("API_IP_RATE_LIMITER"),
			AUTH_IP_RATE_LIMITER: make("AUTH_IP_RATE_LIMITER"),
			SYNC_USER_RATE_LIMITER: make("SYNC_USER_RATE_LIMITER"),
			ACCOUNT_USER_RATE_LIMITER: make("ACCOUNT_USER_RATE_LIMITER"),
		},
		calls,
		callsTo: (binding) => calls.filter((c) => c.binding === binding),
	};
}
