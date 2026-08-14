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
});
