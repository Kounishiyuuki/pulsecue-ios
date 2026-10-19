import { describe, expect, it } from "vitest";
import {
	NonceAlreadyUsedError,
	NonceStoreUnavailableError,
	NONCE_PURGE_BATCH_LIMIT,
	consumeNonce,
	purgeReplayableNonces,
} from "../../src/api/db/nonces";
import { APPLE_CLOCK_SKEW_SECONDS } from "../../src/api/auth/apple";
import type { SqlDatabase, SqlStatement } from "../../src/api/types";
import { createTestDatabase } from "./support/sqliteD1";

describe("single-use nonces", () => {
	it("accepts a nonce once and refuses it thereafter", async () => {
		const db = await createTestDatabase();
		const params = {
			nonceHash: "a".repeat(64),
			provider: "apple" as const,
			expiresAt: 2000,
			now: 1000,
		};

		await consumeNonce(db, params);
		await expect(consumeNonce(db, params)).rejects.toBeInstanceOf(
			NonceAlreadyUsedError,
		);
		expect(await db.count("auth_nonces")).toBe(1);
		db.close();
	});

	it("lets exactly one of two concurrent claims through", async () => {
		const db = await createTestDatabase();
		const params = {
			nonceHash: "b".repeat(64),
			provider: "apple" as const,
			expiresAt: 2000,
			now: 1000,
		};

		const outcomes = await Promise.allSettled([
			consumeNonce(db, params),
			consumeNonce(db, params),
		]);

		expect(outcomes.filter((o) => o.status === "fulfilled")).toHaveLength(1);
		expect(outcomes.filter((o) => o.status === "rejected")).toHaveLength(1);
		db.close();
	});

	it("keeps different nonces independent", async () => {
		const db = await createTestDatabase();
		await consumeNonce(db, {
			nonceHash: "c".repeat(64),
			provider: "apple",
			expiresAt: 2000,
			now: 1000,
		});
		await consumeNonce(db, {
			nonceHash: "d".repeat(64),
			provider: "google",
			expiresAt: 2000,
			now: 1000,
		});
		expect(await db.count("auth_nonces")).toBe(2);
		db.close();
	});

	it("calls a database outage an outage, not a replay", async () => {
		// A failed INSERT used to mean "already used" unconditionally, which
		// turns a D1 incident into "invalid credentials" for every user at
		// once — a 401 where a 503 belongs. The row is absent here, so the
		// only honest answer is that the store is unavailable.
		const failing = failingDatabase({ selectFinds: false });

		await expect(
			consumeNonce(failing, {
				nonceHash: "1".repeat(64),
				provider: "google",
				expiresAt: 2000,
				now: 1000,
			}),
		).rejects.toBeInstanceOf(NonceStoreUnavailableError);
	});

	it("calls it an outage when even the follow-up lookup fails", async () => {
		const failing = failingDatabase({ selectThrows: true });

		await expect(
			consumeNonce(failing, {
				nonceHash: "2".repeat(64),
				provider: "google",
				expiresAt: 2000,
				now: 1000,
			}),
		).rejects.toBeInstanceOf(NonceStoreUnavailableError);
	});

	it("still calls a real duplicate a replay, without reading the driver's error text", async () => {
		// The classification must not depend on D1's error wording, which
		// differs from the SQLite double's and changes between versions.
		const failing = failingDatabase({ selectFinds: true });

		await expect(
			consumeNonce(failing, {
				nonceHash: "3".repeat(64),
				provider: "google",
				expiresAt: 2000,
				now: 1000,
			}),
		).rejects.toBeInstanceOf(NonceAlreadyUsedError);
	});
});

describe("the sweep a scheduler should run", () => {
	it("keeps a nonce for as long as the verifier would still accept its token", async () => {
		// The cleanup must lag the verifier's skew allowance. Sweeping at
		// exactly `expires_at` would delete the replay protection for a token
		// that is still inside its accepted window — a cleanup job that
		// manufactures the vulnerability the table exists to prevent.
		const db = await createTestDatabase();
		const expiresAt = 10_000;
		await consumeNonce(db, {
			nonceHash: "1".repeat(64),
			provider: "apple",
			expiresAt,
			now: 9_000,
		});

		const removed = await purgeReplayableNonces(
			db,
			// One second before the verifier stops accepting the token.
			expiresAt + APPLE_CLOCK_SKEW_SECONDS - 1,
		);

		expect(removed).toBe(0);
		expect(await db.count("auth_nonces")).toBe(1);
		db.close();
	});

	it("sweeps once the token can no longer be accepted at all", async () => {
		const db = await createTestDatabase();
		const expiresAt = 10_000;
		await consumeNonce(db, {
			nonceHash: "2".repeat(64),
			provider: "apple",
			expiresAt,
			now: 9_000,
		});

		const removed = await purgeReplayableNonces(
			db,
			expiresAt + APPLE_CLOCK_SKEW_SECONDS,
		);

		expect(removed).toBe(1);
		expect(await db.count("auth_nonces")).toBe(0);
		db.close();
	});

	it("leaves live nonces alone and reports what it removed", async () => {
		const db = await createTestDatabase();
		for (const [hash, expiresAt] of [
			["3".repeat(64), 1_000],
			["4".repeat(64), 2_000],
			["5".repeat(64), 90_000],
		] as const) {
			await consumeNonce(db, {
				nonceHash: hash,
				provider: "apple",
				expiresAt,
				now: 500,
			});
		}

		const removed = await purgeReplayableNonces(db, 10_000);

		expect(removed).toBe(2);
		expect(await db.count("auth_nonces")).toBe(1);
		db.close();
	});

	it("is a no-op on an empty table", async () => {
		const db = await createTestDatabase();
		expect(await purgeReplayableNonces(db, 10_000)).toBe(0);
		db.close();
	});

	it("draws the boundary at expires_at <= now - skew", async () => {
		const db = await createTestDatabase();
		const now = 10_000;
		const cutoff = now - APPLE_CLOCK_SKEW_SECONDS;
		for (const [hash, expiresAt] of [
			["6".repeat(64), cutoff - 1],
			["7".repeat(64), cutoff],
			["8".repeat(64), cutoff + 1],
		] as const) {
			await consumeNonce(db, { nonceHash: hash, provider: "apple", expiresAt, now: 1 });
		}

		expect(await purgeReplayableNonces(db, now)).toBe(2);
		const left = await db
			.prepare(`SELECT nonce_sha256 FROM auth_nonces`)
			.all<{ nonce_sha256: string }>();
		expect(left.results.map((row) => row.nonce_sha256)).toEqual(["8".repeat(64)]);
		db.close();
	});

	it("removes at most the batch limit per call, oldest first, and carries the rest over", async () => {
		const db = await createTestDatabase();
		for (let i = 0; i < NONCE_PURGE_BATCH_LIMIT + 1; i += 1) {
			await consumeNonce(db, {
				nonceHash: i.toString(16).padStart(64, "0"),
				provider: "apple",
				// The newest stale row is the one carried over.
				expiresAt: 1_000 + i,
				now: 1,
			});
		}

		expect(await purgeReplayableNonces(db, 10_000)).toBe(NONCE_PURGE_BATCH_LIMIT);
		const left = await db
			.prepare(`SELECT expires_at FROM auth_nonces`)
			.all<{ expires_at: number }>();
		expect(left.results).toEqual([{ expires_at: 1_000 + NONCE_PURGE_BATCH_LIMIT }]);
		expect(await purgeReplayableNonces(db, 10_000)).toBe(1);
		expect(await purgeReplayableNonces(db, 10_000)).toBe(0);
		db.close();
	});

	it("never reads nonce hashes into the Worker", async () => {
		const db = await createTestDatabase();
		await consumeNonce(db, { nonceHash: "9".repeat(64), provider: "apple", expiresAt: 1, now: 1 });
		db.resetRecording();

		await purgeReplayableNonces(db, 10_000);

		const issued = db.recorded();
		expect(issued).toHaveLength(1);
		expect(issued[0]?.sql).toMatch(/^\s*DELETE FROM auth_nonces/);
		db.close();
	});

	it("only the skew-aware sweep is exported", async () => {
		// A cleanup with no skew would delete replay protection for tokens the
		// verifier still accepts; it must not come back as a convenience.
		const exported = await import("../../src/api/db/nonces");
		const purgeFunctions = Object.entries(exported)
			.filter(([name, value]) => typeof value === "function" && /purge/i.test(name))
			.map(([name]) => name);
		expect(purgeFunctions).toEqual([
			"purgeReplayableNonces",
		]);
	});
});

/**
 * A database whose INSERT always fails, with an error message that says
 * nothing about why.
 *
 * That opacity is the point: it is how these tests prove the replay/outage
 * classification is drawn from the table's contents rather than from a
 * driver-specific error string.
 */
function failingDatabase(behavior: {
	selectFinds?: boolean;
	selectThrows?: boolean;
}): SqlDatabase {
	const statement = (sql: string, bound: unknown[]): SqlStatement => ({
		bind: (...values: unknown[]) => statement(sql, values),
		first: async <T>() => {
			if (behavior.selectThrows) throw new Error("boom");
			return behavior.selectFinds ? ({ 1: 1 } as T) : null;
		},
		all: async <T>() => ({ results: [] as T[] }),
		run: async () => {
			if (sql.trimStart().toUpperCase().startsWith("INSERT")) {
				throw new Error("boom");
			}
			return undefined;
		},
	});

	return {
		prepare: (sql: string) => statement(sql, []),
		batch: async () => {
			throw new Error("boom");
		},
	};
}
