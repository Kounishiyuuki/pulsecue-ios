import { describe, expect, it } from "vitest";
import { JwksFetchError, RemoteJwksProvider } from "../../src/api/auth/jwks";

function keySet(...kids: string[]) {
	return { keys: kids.map((kid) => ({ kid, kty: "RSA", n: "x", e: "AQAB" })) };
}

function fakeFetch(responses: Array<() => Response>) {
	let calls = 0;
	const impl = (async () => {
		const next = responses[Math.min(calls, responses.length - 1)];
		calls += 1;
		if (!next) throw new Error("no response configured");
		return next();
	}) as unknown as typeof fetch;
	return { impl, calls: () => calls };
}

const ok = (body: unknown) => () =>
	new Response(JSON.stringify(body), { status: 200 });

describe("RemoteJwksProvider", () => {
	it("fetches once and serves the rest from cache", async () => {
		const fetcher = fakeFetch([ok(keySet("k1"))]);
		const provider = new RemoteJwksProvider({
			url: "https://example.test/keys",
			fetchImpl: fetcher.impl,
			nowMs: () => 0,
		});

		expect(await provider.keyForId("k1")).not.toBeNull();
		expect(await provider.keyForId("k1")).not.toBeNull();
		expect(fetcher.calls()).toBe(1);
	});

	it("refetches once for an unknown kid, so key rotation is not an outage", async () => {
		const fetcher = fakeFetch([ok(keySet("old")), ok(keySet("old", "new"))]);
		const provider = new RemoteJwksProvider({
			url: "https://example.test/keys",
			fetchImpl: fetcher.impl,
			nowMs: () => 0,
		});

		await provider.keyForId("old");
		const rotated = await provider.keyForId("new");

		expect(rotated).not.toBeNull();
		expect(fetcher.calls()).toBe(2);
	});

	it("gives up on a kid that is still unknown after refetching", async () => {
		const fetcher = fakeFetch([ok(keySet("k1"))]);
		const provider = new RemoteJwksProvider({
			url: "https://example.test/keys",
			fetchImpl: fetcher.impl,
			nowMs: () => 0,
		});

		expect(await provider.keyForId("missing")).toBeNull();
		// One cached read plus one forced refetch, and no retry storm.
		expect(fetcher.calls()).toBe(2);
	});

	it("refetches once the TTL has passed", async () => {
		const fetcher = fakeFetch([ok(keySet("k1"))]);
		let now = 0;
		const provider = new RemoteJwksProvider({
			url: "https://example.test/keys",
			ttlSeconds: 60,
			fetchImpl: fetcher.impl,
			nowMs: () => now,
		});

		await provider.keyForId("k1");
		now = 61_000;
		await provider.keyForId("k1");

		expect(fetcher.calls()).toBe(2);
	});

	it("surfaces an unreachable key service instead of pretending the key is unknown", async () => {
		// The distinction matters: one is a 503, the other a 401.
		const provider = new RemoteJwksProvider({
			url: "https://example.test/keys",
			fetchImpl: (async () => {
				throw new Error("network down");
			}) as unknown as typeof fetch,
		});

		await expect(provider.keyForId("k1")).rejects.toBeInstanceOf(JwksFetchError);
	});

	it("rejects a non-200 and an empty key set", async () => {
		const bad = new RemoteJwksProvider({
			url: "https://example.test/keys",
			fetchImpl: (async () => new Response("nope", { status: 500 })) as unknown as typeof fetch,
		});
		await expect(bad.keyForId("k1")).rejects.toBeInstanceOf(JwksFetchError);

		const empty = new RemoteJwksProvider({
			url: "https://example.test/keys",
			fetchImpl: (async () =>
				new Response(JSON.stringify({ keys: [] }), { status: 200 })) as unknown as typeof fetch,
		});
		await expect(empty.keyForId("k1")).rejects.toBeInstanceOf(JwksFetchError);
	});

	it("forgets everything on invalidate", async () => {
		const fetcher = fakeFetch([ok(keySet("k1"))]);
		const provider = new RemoteJwksProvider({
			url: "https://example.test/keys",
			fetchImpl: fetcher.impl,
			nowMs: () => 0,
		});

		await provider.keyForId("k1");
		provider.invalidate();
		await provider.keyForId("k1");

		expect(fetcher.calls()).toBe(2);
	});

	it("refuses a non-HTTPS endpoint at construction", async () => {
		// The URL is a module constant in every caller. This is the tripwire
		// that keeps a future refactor from making it request-controlled.
		expect(
			() => new RemoteJwksProvider({ url: "http://example.test/keys" }),
		).toThrow();
		expect(
			() => new RemoteJwksProvider({ url: "file:///etc/passwd" }),
		).toThrow();
	});
});

describe("key set validation", () => {
	const providerFor = (body: unknown) =>
		new RemoteJwksProvider({
			url: "https://example.test/keys",
			fetchImpl: (async () =>
				new Response(JSON.stringify(body), { status: 200 })) as unknown as typeof fetch,
			nowMs: () => 0,
		});

	/** A fetched document is untrusted input; every one of these fails closed. */
	const malformed: Array<[string, unknown]> = [
		["not an object", "just a string"],
		["no keys member", { notKeys: [] }],
		["keys is not an array", { keys: { kid: "k1" } }],
		["a key that is not an object", { keys: ["k1"] }],
		["a key with no kid", { keys: [{ kty: "RSA", n: "x", e: "AQAB" }] }],
		["a key with an empty kid", { keys: [{ kid: "", kty: "RSA", n: "x", e: "AQAB" }] }],
		["a key with a non-string kid", { keys: [{ kid: 7, kty: "RSA", n: "x", e: "AQAB" }] }],
	];

	for (const [description, body] of malformed) {
		it(`rejects ${description}`, async () => {
			await expect(providerFor(body).keyForId("k1")).rejects.toBeInstanceOf(
				JwksFetchError,
			);
		});
	}

	it("rejects a set with a duplicate kid rather than guessing which one signed", async () => {
		const body = {
			keys: [
				{ kid: "k1", kty: "RSA", n: "aaa", e: "AQAB" },
				{ kid: "k1", kty: "RSA", n: "bbb", e: "AQAB" },
			],
		};
		await expect(providerFor(body).keyForId("k1")).rejects.toBeInstanceOf(
			JwksFetchError,
		);
	});

	it("will not use a key of the wrong type, purpose or algorithm", async () => {
		const wrong: Array<[string, unknown]> = [
			["kty", { kid: "k1", kty: "EC", crv: "P-256", x: "a", y: "b" }],
			["use", { kid: "k1", kty: "RSA", use: "enc", n: "x", e: "AQAB" }],
			["alg", { kid: "k1", kty: "RSA", alg: "RS512", n: "x", e: "AQAB" }],
		];
		for (const [member, key] of wrong) {
			await expect(
				providerFor({ keys: [key] }).keyForId("k1"),
				`wrong ${member} should not be usable`,
			).rejects.toBeInstanceOf(JwksFetchError);
		}
	});

	it("will not use an RSA key that is missing its modulus or exponent", async () => {
		const missing: unknown[] = [
			{ kid: "k1", kty: "RSA", e: "AQAB" },
			{ kid: "k1", kty: "RSA", n: "x" },
			{ kid: "k1", kty: "RSA", n: "", e: "AQAB" },
			{ kid: "k1", kty: "RSA", n: 123, e: "AQAB" },
		];
		for (const key of missing) {
			await expect(providerFor({ keys: [key] }).keyForId("k1")).rejects.toBeInstanceOf(
				JwksFetchError,
			);
		}
	});

	it("keeps the usable keys when the provider also publishes others", async () => {
		// A provider adding an EC key for some other product must not take
		// sign-in down.
		const provider = providerFor({
			keys: [
				{ kid: "ec", kty: "EC", crv: "P-256", x: "a", y: "b" },
				{ kid: "rsa", kty: "RSA", use: "sig", alg: "RS256", n: "x", e: "AQAB" },
			],
		});

		expect(await provider.keyForId("rsa")).not.toBeNull();
		expect(await provider.keyForId("ec")).toBeNull();
	});

	it("accepts a key that omits the optional use and alg members", async () => {
		// RFC 7517 makes both optional, and an omitted `use` means
		// unrestricted. Requiring them would be a self-inflicted outage.
		const provider = providerFor({
			keys: [{ kid: "k1", kty: "RSA", n: "x", e: "AQAB" }],
		});
		expect(await provider.keyForId("k1")).not.toBeNull();
	});
});

describe("unknown-kid fetch amplification", () => {
	it("does not refetch again for the next unknown kid inside the cooldown", async () => {
		// An unauthenticated caller can put any `kid` in a token header. One
		// forced refetch per cooldown, not one per request.
		const fetcher = fakeFetch([ok(keySet("k1"))]);
		let now = 0;
		const provider = new RemoteJwksProvider({
			url: "https://example.test/keys",
			unknownKidCooldownSeconds: 60,
			fetchImpl: fetcher.impl,
			nowMs: () => now,
		});

		for (let i = 0; i < 25; i += 1) {
			now += 100; // well inside the cooldown
			expect(await provider.keyForId(`bogus-${i}`)).toBeNull();
		}

		// The cold load plus exactly one forced refetch.
		expect(fetcher.calls()).toBe(2);
	});

	it("allows another refetch once the cooldown has passed, so rotation still lands", async () => {
		// The key only appears on the third fetch, so the test can tell a
		// cooldown-blocked lookup from one that was allowed through.
		const fetcher = fakeFetch([
			ok(keySet("old")),
			ok(keySet("old")),
			ok(keySet("old", "new")),
		]);
		let now = 0;
		const provider = new RemoteJwksProvider({
			url: "https://example.test/keys",
			unknownKidCooldownSeconds: 60,
			fetchImpl: fetcher.impl,
			nowMs: () => now,
		});

		expect(await provider.keyForId("new")).toBeNull(); // 2 calls, cooldown starts
		now = 61_000;
		expect(await provider.keyForId("new")).not.toBeNull();
		expect(fetcher.calls()).toBe(3);
	});

	it("collapses a burst of concurrent unknown kids into one round of fetches", async () => {
		// Without single-flight, 50 simultaneous requests would open 50
		// connections to the provider.
		let calls = 0;
		const impl = (async () => {
			calls += 1;
			// Yield, so every caller is in flight before the first resolves.
			await new Promise((resolve) => setTimeout(resolve, 0));
			return new Response(JSON.stringify(keySet("k1")), { status: 200 });
		}) as unknown as typeof fetch;
		const provider = new RemoteJwksProvider({
			url: "https://example.test/keys",
			fetchImpl: impl,
			nowMs: () => 0,
		});

		const results = await Promise.all(
			Array.from({ length: 50 }, (_, i) => provider.keyForId(`bogus-${i}`)),
		);

		expect(results.every((key) => key === null)).toBe(true);
		expect(calls).toBeLessThanOrEqual(2);
	});

	it("still serves a burst for a known kid from a single fetch", async () => {
		let calls = 0;
		const impl = (async () => {
			calls += 1;
			await new Promise((resolve) => setTimeout(resolve, 0));
			return new Response(JSON.stringify(keySet("k1")), { status: 200 });
		}) as unknown as typeof fetch;
		const provider = new RemoteJwksProvider({
			url: "https://example.test/keys",
			fetchImpl: impl,
			nowMs: () => 0,
		});

		const results = await Promise.all(
			Array.from({ length: 50 }, () => provider.keyForId("k1")),
		);

		expect(results.every((key) => key !== null)).toBe(true);
		expect(calls).toBe(1);
	});

	it("backs off briefly instead of refetching per request while the provider is down", async () => {
		// Once the cache has expired, single-flight no longer helps a serial
		// stream: each request arrives after the last failure resolved. Without
		// a backoff, a provider outage costs one outbound fetch per inbound
		// request.
		let calls = 0;
		const impl = (async () => {
			calls += 1;
			throw new Error("network down");
		}) as unknown as typeof fetch;
		let now = 0;
		const provider = new RemoteJwksProvider({
			url: "https://example.test/keys",
			failureBackoffSeconds: 5,
			fetchImpl: impl,
			nowMs: () => now,
		});

		for (let i = 0; i < 20; i += 1) {
			now += 100;
			// Still a 503-shaped failure either way — only the fetch is skipped.
			await expect(provider.keyForId("k1")).rejects.toBeInstanceOf(JwksFetchError);
		}

		expect(calls).toBe(1);
	});

	it("retries once the failure backoff has passed", async () => {
		let calls = 0;
		const impl = (async () => {
			calls += 1;
			if (calls === 1) throw new Error("network down");
			return new Response(JSON.stringify(keySet("k1")), { status: 200 });
		}) as unknown as typeof fetch;
		let now = 0;
		const provider = new RemoteJwksProvider({
			url: "https://example.test/keys",
			failureBackoffSeconds: 5,
			fetchImpl: impl,
			nowMs: () => now,
		});

		await expect(provider.keyForId("k1")).rejects.toBeInstanceOf(JwksFetchError);
		now = 5_000;
		expect(await provider.keyForId("k1")).not.toBeNull();
		expect(calls).toBe(2);
	});

	it("does not let a past failure block a later request once a fetch succeeds", async () => {
		let calls = 0;
		const impl = (async () => {
			calls += 1;
			if (calls === 1) throw new Error("network down");
			return new Response(JSON.stringify(keySet("k1")), { status: 200 });
		}) as unknown as typeof fetch;
		let now = 0;
		const provider = new RemoteJwksProvider({
			url: "https://example.test/keys",
			ttlSeconds: 1,
			failureBackoffSeconds: 5,
			fetchImpl: impl,
			nowMs: () => now,
		});

		await expect(provider.keyForId("k1")).rejects.toBeInstanceOf(JwksFetchError);
		now = 5_000;
		expect(await provider.keyForId("k1")).not.toBeNull();
		// The success cleared the failure, so the expired-cache refetch runs.
		now = 6_001;
		expect(await provider.keyForId("k1")).not.toBeNull();
		expect(calls).toBe(3);
	});

	it("serves a valid cache without noticing an earlier failure", async () => {
		// The backoff must never turn a working cache into a 503.
		let calls = 0;
		const impl = (async () => {
			calls += 1;
			if (calls === 1) return new Response(JSON.stringify(keySet("k1")), { status: 200 });
			throw new Error("network down");
		}) as unknown as typeof fetch;
		let now = 0;
		const provider = new RemoteJwksProvider({
			url: "https://example.test/keys",
			failureBackoffSeconds: 5,
			fetchImpl: impl,
			nowMs: () => now,
		});

		expect(await provider.keyForId("k1")).not.toBeNull();
		// An unknown kid forces a refetch, which fails.
		expect(await provider.keyForId("nope").catch(() => null)).toBeNull();
		now += 100;
		// The known kid still resolves from the still-valid cache.
		expect(await provider.keyForId("k1")).not.toBeNull();
	});

	it("lets invalidate bypass the cooldown, so an operator can force a rotation", async () => {
		const fetcher = fakeFetch([
			ok(keySet("old")),
			ok(keySet("old")),
			ok(keySet("old", "new")),
		]);
		const provider = new RemoteJwksProvider({
			url: "https://example.test/keys",
			unknownKidCooldownSeconds: 3600,
			fetchImpl: fetcher.impl,
			nowMs: () => 0,
		});

		expect(await provider.keyForId("new")).toBeNull(); // cooldown now active
		provider.invalidate();
		expect(await provider.keyForId("new")).not.toBeNull();
	});
});
