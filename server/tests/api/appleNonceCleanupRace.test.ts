/**
 * A sign-in that is in flight while the nonce sweep runs.
 *
 * The sweep deletes a nonce once its token is expired by
 * `isAppleIdentityTokenExpired`. A request verified one second earlier can
 * stall, let the sweep delete the original row, and then INSERT the same
 * nonce successfully — the primary key no longer stands in its way. The
 * route must still refuse before the exchange, on its own: the fake Apple
 * here would answer every exchange with success, so a 401 can only come from
 * the replay guard.
 *
 * No sleeps: the request is held at an exact statement by a barrier, and the
 * clock is a value the test moves.
 */

import { Hono } from "hono";
import { describe, expect, it } from "vitest";
import {
	APPLE_CLOCK_SKEW_SECONDS,
	isAppleIdentityTokenExpired,
	verifyAppleIdentityToken,
} from "../../src/api/auth/apple";
import { TokenCipher } from "../../src/api/crypto/tokenCipher";
import { purgeReplayableNonces } from "../../src/api/db/nonces";
import { makeAppleAuthHandler } from "../../src/api/routes/authApple";
import type { ApiEnv, SqlDatabase } from "../../src/api/types";
import { TEST_AUDIENCE, appleClaims, createTestSigner, hashedNonce } from "./support/appleTokens";
import {
	TEST_APPLE_SUBJECT,
	appleTokenResponseFor,
	createTestAppleSigningKey,
	fakeAppleEndpoint,
	testEncryptionKey,
} from "./support/appleProduction";
import { type TestDatabase, createTestDatabase } from "./support/sqliteD1";

const SKEW = APPLE_CLOCK_SKEW_SECONDS;
/** The identity token's `exp`. */
const E = 1_800_000_600;
const RAW_NONCE = "race-nonce";
const LAST_VALID = E + SKEW - 1;
const FIRST_EXPIRED = E + SKEW;

function barrier() {
	let release!: () => void;
	const released = new Promise<void>((resolve) => {
		release = resolve;
	});
	return { released, release };
}

/**
 * The test database, with the nonce INSERT optionally held until released.
 * `reached` resolves once the request is parked on it.
 */
function holdableDb(db: TestDatabase) {
	let hold: { reached: () => void; released: Promise<void> } | null = null;
	let nonceInserts = 0;
	const wrapped: SqlDatabase = {
		prepare(query) {
			const statement = db.prepare(query);
			if (!/INSERT INTO auth_nonces/.test(query)) return statement;
			const bind = statement.bind.bind(statement);
			statement.bind = (...values: unknown[]) => {
				const bound = bind(...values);
				const run = bound.run.bind(bound);
				bound.run = async () => {
					nonceInserts += 1;
					if (hold) {
						const current = hold;
						hold = null;
						current.reached();
						await current.released;
					}
					return run();
				};
				return bound;
			};
			return statement;
		},
		batch: (statements) => db.batch(statements),
	};
	return {
		db: wrapped,
		nonceInserts: () => nonceInserts,
		holdNextNonceInsert() {
			const reached = barrier();
			const gate = barrier();
			hold = { reached: reached.release, released: gate.released };
			return { reached: reached.released, release: gate.release };
		},
	};
}

async function setup() {
	const raw = await createTestDatabase();
	const held = holdableDb(raw);
	const signer = await createTestSigner();
	const key = await createTestAppleSigningKey();
	// Every exchange that reaches Apple succeeds. A rejection in these tests
	// therefore cannot be the exchange failing.
	const apple = fakeAppleEndpoint(() =>
		appleTokenResponseFor(signer, {
			sub: TEST_APPLE_SUBJECT,
			audience: key.config.clientId,
			now: E - 100,
		}),
	);
	// `queue` is read first, one value per read; then `now`.
	const clock = { now: E - 100, queue: [] as number[], reads: [] as number[] };
	const app = new Hono<{ Bindings: ApiEnv }>();
	app.post(
		"/v1/auth/apple",
		makeAppleAuthHandler({
			jwks: signer.jwks,
			audience: TEST_AUDIENCE,
			clientSecret: key.config,
			cipher: new TokenCipher({ version: 1, material: testEncryptionKey() }),
			fetchImpl: apple.fetchImpl,
			now: () => {
				const t = clock.queue.shift() ?? clock.now;
				clock.reads.push(t);
				return t;
			},
		}),
	);
	const env = { DB: held.db, APPLE_AUDIENCE: TEST_AUDIENCE } as unknown as ApiEnv;
	const identityToken = await signer.sign(
		await appleClaims({
			sub: TEST_APPLE_SUBJECT,
			nonce: await hashedNonce(RAW_NONCE),
			iat: E - 600,
			exp: E,
		}),
	);
	const body = JSON.stringify({
		identityToken,
		authorizationCode: "test-authorization-code",
		rawNonce: RAW_NONCE,
	});
	const post = (init: RequestInit = { body }) =>
		app.request(
			"/v1/auth/apple",
			{ method: "POST", headers: { "content-type": "application/json" }, ...init },
			env,
		);
	return { raw, held, apple, clock, post, body };
}

/** Everything a sign-in can write about an account. */
async function accountState(db: TestDatabase) {
	const rows = async (table: string) =>
		(await db.prepare(`SELECT * FROM ${table} ORDER BY rowid`).all()).results;
	return {
		users: await rows("users"),
		identities: await rows("auth_identities"),
		sessions: await rows("sessions"),
		credentials: await rows("provider_credentials"),
	};
}

describe("one expiry boundary", () => {
	it("is valid at exp + skew - 1 and expired at exp + skew", () => {
		expect(isAppleIdentityTokenExpired(E, LAST_VALID)).toBe(false);
		expect(isAppleIdentityTokenExpired(E, FIRST_EXPIRED)).toBe(true);
	});

	it("is the boundary the verifier applies", async () => {
		const signer = await createTestSigner();
		const identityToken = await signer.sign(
			await appleClaims({ nonce: await hashedNonce(RAW_NONCE), iat: E - 600, exp: E }),
		);
		const verify = (now: number) =>
			verifyAppleIdentityToken({
				identityToken,
				rawNonce: RAW_NONCE,
				audience: TEST_AUDIENCE,
				jwks: signer.jwks,
				now,
			});

		await expect(verify(LAST_VALID)).resolves.toMatchObject({ expiresAt: E });
		await expect(verify(FIRST_EXPIRED)).rejects.toThrow("expired");
	});

	it("is the boundary the sweep applies", async () => {
		const { raw, held } = await setup();
		await held.db
			.prepare(`INSERT INTO auth_nonces (nonce_sha256, provider, used_at, expires_at) VALUES (?, 'apple', 1, ?)`)
			.bind("f".repeat(64), E)
			.run();

		expect(await purgeReplayableNonces(raw, LAST_VALID)).toBe(0);
		expect(await purgeReplayableNonces(raw, FIRST_EXPIRED)).toBe(1);
		raw.close();
	});
});

describe("an Apple sign-in in flight across the nonce sweep", () => {
	it("refuses a replay whose nonce the sweep deleted mid-request, before the exchange", async () => {
		const { raw, held, apple, clock, post } = await setup();

		// The original sign-in, well inside the token's life.
		expect((await post()).status).toBe(200);
		expect(apple.requests).toHaveLength(1);
		const before = await accountState(raw);

		// The replay is verified at the last valid second, then parked on
		// its nonce INSERT.
		clock.now = LAST_VALID;
		const parked = held.holdNextNonceInsert();
		const replay = post();
		await parked.reached;

		// Meanwhile the sweep runs at the boundary and deletes the original row.
		expect(await purgeReplayableNonces(raw, FIRST_EXPIRED)).toBe(1);
		expect(await raw.count("auth_nonces")).toBe(0);

		clock.now = FIRST_EXPIRED;
		parked.release();
		const response = await replay;

		expect(response.status).toBe(401);
		expect(((await response.json()) as { error: { code: string } }).error.code).toBe(
			"invalid_credentials",
		);
		// The INSERT did succeed — that is the race — and the row is left for
		// the next sweep rather than deleted on the spot.
		expect(await raw.count("auth_nonces")).toBe(1);
		// Refused by the replay guard itself: Apple was never asked.
		expect(apple.requests).toHaveLength(1);
		expect(await accountState(raw)).toEqual(before);
		raw.close();
	});

	it("refuses without claiming when the token expired between verification and the claim", async () => {
		const { raw, held, apple, clock, post } = await setup();
		// Verification reads LAST_VALID; every later read is FIRST_EXPIRED.
		clock.queue = [LAST_VALID];
		clock.now = FIRST_EXPIRED;

		const response = await post();

		expect(response.status).toBe(401);
		expect(held.nonceInserts()).toBe(0);
		expect(await raw.count("auth_nonces")).toBe(0);
		expect(apple.requests).toHaveLength(0);
		expect(await accountState(raw)).toEqual({
			users: [],
			identities: [],
			sessions: [],
			credentials: [],
		});
		raw.close();
	});

	it("still signs in when every read is the last valid second", async () => {
		const { raw, apple, clock, post } = await setup();
		clock.now = LAST_VALID;

		const response = await post();

		expect(response.status).toBe(200);
		expect(apple.requests).toHaveLength(1);
		// Downstream work runs on a time read after the claim, not on the
		// verification time.
		expect(clock.reads).toEqual([LAST_VALID, LAST_VALID, LAST_VALID]);
		raw.close();
	});

	it("verifies on a time read after the body, not before it", async () => {
		const { raw, held, apple, clock, post, body } = await setup();
		const bodyRequested = barrier();
		const bodyGate = barrier();
		const stream = new ReadableStream<Uint8Array>({
			async pull(controller) {
				bodyRequested.release();
				await bodyGate.released;
				controller.enqueue(new TextEncoder().encode(body));
				controller.close();
			},
		});
		clock.now = LAST_VALID;

		const pending = post({ body: stream, duplex: "half" } as RequestInit);
		await bodyRequested.released;
		clock.now = FIRST_EXPIRED;
		bodyGate.release();
		const response = await pending;

		expect(response.status).toBe(401);
		expect(clock.reads[0]).toBe(FIRST_EXPIRED);
		expect(held.nonceInserts()).toBe(0);
		expect(apple.requests).toHaveLength(0);
		raw.close();
	});
});
