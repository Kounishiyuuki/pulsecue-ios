/**
 * Public signing keys for a provider, fetched over HTTPS and cached.
 *
 * A `JwksProvider` is the seam that makes Apple verification testable
 * without Apple: the tests generate their own RSA keypair, publish the
 * public half through a static provider, and sign real tokens with the
 * private half. The verification path under test is then the production one,
 * not a stub.
 *
 * Caching is in-memory, per isolate. Apple rotates these keys rarely and a
 * Worker isolate is reused across requests, so a short TTL keeps the common
 * path free of network calls without a KV binding. If key lookups ever need
 * to be shared across isolates, KV is the upgrade — it is not needed to be
 * correct.
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

interface JwksDocument {
	keys?: JwkWithId[];
}

export class JwksFetchError extends Error {
	constructor(reason: string) {
		super(`could not load signing keys: ${reason}`);
		this.name = "JwksFetchError";
	}
}

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
	url: string;
	/** How long a fetched key set may be reused. */
	ttlSeconds?: number;
	/** Injectable for tests; defaults to the global `fetch`. */
	fetchImpl?: typeof fetch;
	/** Injectable clock, in milliseconds. */
	nowMs?: () => number;
}

export class RemoteJwksProvider implements JwksProvider {
	private cached: { keys: JwkWithId[]; expiresAtMs: number } | null = null;
	private readonly ttlMs: number;
	private readonly fetchImpl: typeof fetch;
	private readonly nowMs: () => number;

	constructor(private readonly options: RemoteJwksOptions) {
		this.ttlMs = (options.ttlSeconds ?? 6 * 60 * 60) * 1000;
		this.fetchImpl = options.fetchImpl ?? fetch;
		this.nowMs = options.nowMs ?? (() => Date.now());
	}

	/**
	 * Looks the key up, refetching once if the `kid` is unknown.
	 *
	 * The refetch is what makes key rotation a non-event: a token signed with
	 * a key minted after the cache was filled would otherwise be rejected for
	 * the whole TTL.
	 */
	async keyForId(kid: string): Promise<JsonWebKey | null> {
		const fromCache = await this.load(false);
		const hit = fromCache.find((key) => key.kid === kid);
		if (hit) return hit;

		const fresh = await this.load(true);
		return fresh.find((key) => key.kid === kid) ?? null;
	}

	invalidate(): void {
		this.cached = null;
	}

	private async load(force: boolean): Promise<JwkWithId[]> {
		const now = this.nowMs();
		if (!force && this.cached && this.cached.expiresAtMs > now) {
			return this.cached.keys;
		}

		let response: Response;
		try {
			response = await this.fetchImpl(this.options.url);
		} catch {
			throw new JwksFetchError("request failed");
		}
		if (!response.ok) {
			throw new JwksFetchError(`status ${response.status}`);
		}

		let document: JwksDocument;
		try {
			document = (await response.json()) as JwksDocument;
		} catch {
			throw new JwksFetchError("response was not JSON");
		}
		const keys = (document.keys ?? []).filter((key) => typeof key.kid === "string");
		if (keys.length === 0) {
			throw new JwksFetchError("key set was empty");
		}

		this.cached = { keys, expiresAtMs: now + this.ttlMs };
		return keys;
	}
}
