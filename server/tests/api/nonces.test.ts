import { describe, expect, it } from "vitest";
import {
	NonceAlreadyUsedError,
	consumeNonce,
	purgeExpiredNonces,
} from "../../src/api/db/nonces";
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

	it("sweeps only nonces whose token has already expired", async () => {
		const db = await createTestDatabase();
		await consumeNonce(db, {
			nonceHash: "e".repeat(64),
			provider: "apple",
			expiresAt: 1500,
			now: 1000,
		});
		await consumeNonce(db, {
			nonceHash: "f".repeat(64),
			provider: "apple",
			expiresAt: 5000,
			now: 1000,
		});

		await purgeExpiredNonces(db, 2000);

		expect(await db.count("auth_nonces")).toBe(1);
		db.close();
	});
});
