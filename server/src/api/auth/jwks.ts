/**
 * Public signing keys for a provider, fetched over HTTPS and cached.
 *
 * A `JwksProvider` is the seam that makes provider verification testable
 * without the provider: the tests generate their own RSA keypair, publish the
 * public half through a static provider, and sign real tokens with the
 * private half. The verification path under test is then the production one,
 * not a stub.
 *
 * Caching is in-memory, per isolate. Apple and Google both rotate these keys
 * rarely and a Worker isolate is reused across requests, so a short TTL keeps
 * the common path free of network calls without a KV binding. If key lookups
 * ever need to be shared across isolates, KV is the upgrade — it is not
 * needed to be correct.
 *
 * Two things this file is deliberately strict about, because both are
 * reachable by an unauthenticated request:
 *
 *   Key set shape — a fetched document is untrusted input. `keys` must be an
 *     array of objects with a non-empty, *unique* `kid`, and a key is only
 *     usable if it carries the material and (when stated) the `kty`/`use`/
 *     `alg` this service verifies with. A malformed or ambiguous set fails
 *     closed rather than degrading into "try whatever is in there".
 *
 *   Fetch amplification — an unknown `kid` triggers a refetch so that key
 *     rotation is not an outage, but a caller who can mint tokens with
 *     arbitrary `kid` values could otherwise turn one cheap request into one
 *     outbound fetch. A cooldown plus single-flight bounds that to roughly
 *     one refetch per cooldown window per isolate, no matter how many
 *     requests arrive. A short backoff after a failed fetch covers the other
 *     shape of the same problem: once the cache has expired and the provider
 *     is down, a serial stream of requests would otherwise each start their
 *     own doomed fetch.
 */

export interface JwksProvider {
	/** The key with this `kid`, or `null` when the set does not have it. */
	keyForId(kid: string): Promise<JsonWebKey | null>;
	/** Drops any cache, so a rotated key can be picked up immediately. */
	invalidate(): void;
}

interface JwkWithId extends JsonWebKey {
	kid?: string;
}

export class JwksFetchError extends Error {
	constructor(reason: string) {
		super(`could not load signing keys: ${reason}`);
		this.name = "JwksFetchError";
	}
}

/**
 * What a key has to be for this service to verify with it.
 *
 * `use` and `alg` are optional members in RFC 7517 — an omitted `use` means
 * the key is unrestricted — so a key that omits them is accepted, while a key
 * that *states* a different purpose or algorithm is not. Stating and
 * disagreeing is the case that matters: it means the key is not for this.
 */
export interface JwksKeyRequirements {
	kty: string;
	use: string;
	alg: string;
	/** Members without which the key cannot be imported at all. */
	requiredMembers: readonly string[];
}

/** Both Apple and Google publish RS256 signature keys. */
export const RSA_SIGNING_KEY_REQUIREMENTS: JwksKeyRequirements = {
	kty: "RSA",
	use: "sig",
	alg: "RS256",
	requiredMembers: ["n", "e"],
};

/** Fixed keys. Used by tests and by any future offline verification. */
export class StaticJwksProvider implements JwksProvider {
	constructor(private readonly keys: JwkWithId[]) {}

	async keyForId(kid: string): Promise<JsonWebKey | null> {
		return this.keys.find((key) => key.kid === kid) ?? null;
	}

	invalidate(): void {
		// Nothing is cached.
	}
}

export interface RemoteJwksOptions {
	/** Must be HTTPS and fixed by the provider module — never request input. */
	url: string;
	/** How long a fetched key set may be reused. */
	ttlSeconds?: number;
	/** Shape a key must have to be considered usable. */
	requirements?: JwksKeyRequirements;
	/**
	 * Minimum gap between two unknown-`kid` refetches. Rotation is picked up
	 * within this window; a flood of bogus `kid`s costs one fetch, not one
	 * per request.
	 */
	unknownKidCooldownSeconds?: number;
	/**
	 * How long to fail fast after a fetch failed, instead of retrying on the
	 * next request. Kept short: the point is to stop hammering a provider
	 * that is already struggling, not to extend its outage into ours.
	 */
	failureBackoffSeconds?: number;
	/** Injectable for tests; defaults to the global `fetch`. */
	fetchImpl?: typeof fetch;
	/** Injectable clock, in milliseconds. */
	nowMs?: () => number;
}

export class RemoteJwksProvider implements JwksProvider {
	private cached: { keys: JwkWithId[]; expiresAtMs: number } | null = null;
	/** Shared by concurrent callers, so N requests cause one fetch. */
	private inFlight: Promise<JwkWithId[]> | null = null;
	/** Only unknown-`kid` refetches; a cold load must not start the clock. */
	private lastForcedFetchAtMs: number | null = null;
	/** Set when a fetch throws, cleared when one succeeds. */
	private lastFailedFetchAtMs: number | null = null;
	private readonly ttlMs: number;
	private readonly cooldownMs: number;
	private readonly failureBackoffMs: number;
	private readonly requirements: JwksKeyRequirements;
	private readonly fetchImpl: typeof fetch;
	private readonly nowMs: () => number;

	constructor(private readonly options: RemoteJwksOptions) {
		// The URL is a module constant in every caller. Checking it here means
		// no future refactor can make it request-controlled without tripping
		// this, which is the difference between a key fetch and an SSRF.
		if (!options.url.startsWith("https://")) {
			throw new Error("JWKS url must be https");
		}
		this.ttlMs = (options.ttlSeconds ?? 6 * 60 * 60) * 1000;
		this.cooldownMs = (options.unknownKidCooldownSeconds ?? 60) * 1000;
		this.failureBackoffMs = (options.failureBackoffSeconds ?? 5) * 1000;
		this.requirements = options.requirements ?? RSA_SIGNING_KEY_REQUIREMENTS;
		this.fetchImpl = options.fetchImpl ?? fetch;
		this.nowMs = options.nowMs ?? (() => Date.now());
	}

	/**
	 * Looks the key up, refetching at most once per cooldown when the `kid` is
	 * unknown.
	 *
	 * The refetch is what makes key rotation a non-event: a token signed with
	 * a key minted after the cache was filled would otherwise be rejected for
	 * the whole TTL. The cooldown is what keeps that from being a free
	 * outbound request for anyone who can invent a `kid`.
	 */
	async keyForId(kid: string): Promise<JsonWebKey | null> {
		const fromCache = await this.load(false);
		const hit = fromCache.find((key) => key.kid === kid);
		if (hit) return hit;

		if (!this.mayForceRefresh()) return null;

		const fresh = await this.load(true);
		return fresh.find((key) => key.kid === kid) ?? null;
	}

	invalidate(): void {
		this.cached = null;
		// An explicit invalidation is an operator saying "rotation happened
		// now"; holding it behind the anti-storm cooldown or the failure
		// backoff would defeat it.
		this.lastForcedFetchAtMs = null;
		this.lastFailedFetchAtMs = null;
	}

	private mayForceRefresh(): boolean {
		if (this.lastForcedFetchAtMs === null) return true;
		return this.nowMs() - this.lastForcedFetchAtMs >= this.cooldownMs;
	}

	private async load(force: boolean): Promise<JwkWithId[]> {
		const now = this.nowMs();
		if (!force && this.cached && this.cached.expiresAtMs > now) {
			return this.cached.keys;
		}
		// Whoever gets here first does the fetch; everyone else waits on it.
		// Without this, a burst of concurrent unknown-`kid` requests would each
		// open their own connection to the provider.
		if (this.inFlight) return this.inFlight;

		// Once the cache has expired, single-flight no longer helps a *serial*
		// stream of requests: each one arrives after the last failure resolved
		// and starts its own fetch. A provider that is down would take one
		// outbound request per inbound request. Fail fast for a short while
		// instead — the answer is the same 503 either way.
		if (
			this.lastFailedFetchAtMs !== null &&
			now - this.lastFailedFetchAtMs < this.failureBackoffMs
		) {
			throw new JwksFetchError("a recent fetch failed");
		}

		const pending = this.fetchKeys(force).finally(() => {
			this.inFlight = null;
		});
		this.inFlight = pending;
		return pending;
	}

	private async fetchKeys(forced: boolean): Promise<JwkWithId[]> {
		if (forced) this.lastForcedFetchAtMs = this.nowMs();
		try {
			const keys = await this.fetchAndParse();
			this.lastFailedFetchAtMs = null;
			return keys;
		} catch (error) {
			this.lastFailedFetchAtMs = this.nowMs();
			throw error;
		}
	}

	private async fetchAndParse(): Promise<JwkWithId[]> {
		let response: Response;
		try {
			response = await this.fetchImpl(this.options.url);
		} catch {
			throw new JwksFetchError("request failed");
		}
		if (!response.ok) {
			throw new JwksFetchError(`status ${response.status}`);
		}

		let document: unknown;
		try {
			document = await response.json();
		} catch {
			throw new JwksFetchError("response was not JSON");
		}

		const keys = parseKeySet(document, this.requirements);
		this.cached = { keys, expiresAtMs: this.nowMs() + this.ttlMs };
		return keys;
	}
}

/**
 * Validates a fetched key set and returns the keys this service can verify
 * with. Throws `JwksFetchError` for anything structurally wrong — a bad
 * document is a provider or network problem, never a bad credential, and the
 * caller turns the two into different HTTP statuses.
 */
function parseKeySet(
	document: unknown,
	requirements: JwksKeyRequirements,
): JwkWithId[] {
	if (typeof document !== "object" || document === null) {
		throw new JwksFetchError("key set was not an object");
	}
	const rawKeys = (document as { keys?: unknown }).keys;
	if (!Array.isArray(rawKeys)) {
		throw new JwksFetchError("key set has no keys array");
	}

	const seen = new Set<string>();
	const usable: JwkWithId[] = [];
	for (const entry of rawKeys) {
		if (typeof entry !== "object" || entry === null) {
			throw new JwksFetchError("key set contains a non-object key");
		}
		const key = entry as JwkWithId;
		if (typeof key.kid !== "string" || key.kid.length === 0) {
			throw new JwksFetchError("key set contains a key without a kid");
		}
		// Two keys under one `kid` make "which key signed this" ambiguous, and
		// picking either one is a guess. Refuse the whole set.
		if (seen.has(key.kid)) {
			throw new JwksFetchError("key set contains a duplicate kid");
		}
		seen.add(key.kid);

		if (isUsable(key, requirements)) usable.push(key);
	}

	if (usable.length === 0) {
		throw new JwksFetchError("key set had no usable keys");
	}
	return usable;
}

function isUsable(key: JwkWithId, requirements: JwksKeyRequirements): boolean {
	if (key.kty !== requirements.kty) return false;
	// Absent means unrestricted (RFC 7517); present and different means the
	// key is for something else.
	if (key.use !== undefined && key.use !== requirements.use) return false;
	if (key.alg !== undefined && key.alg !== requirements.alg) return false;
	for (const member of requirements.requiredMembers) {
		const value = (key as unknown as Record<string, unknown>)[member];
		if (typeof value !== "string" || value.length === 0) return false;
	}
	return true;
}
