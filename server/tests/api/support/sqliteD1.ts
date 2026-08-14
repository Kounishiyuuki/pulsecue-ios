/**
 * A `SqlDatabase` backed by an in-memory SQLite, used to run the repository
 * tests against the **real migration file**.
 *
 * The point is that these tests exercise the actual SQL and the actual
 * constraints — UNIQUE (provider, subject), the CHECK on `state`, the
 * foreign keys, `RETURNING seq` — rather than a hand-written fake that
 * would happily agree with a broken query.
 *
 * `node:sqlite` needs `--experimental-sqlite` on Node 23, which
 * `vitest.config.ts` passes to the test workers. It is a dev-time detail
 * only: nothing here ships, and production runs on D1.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { SqlDatabase, SqlStatement } from "../../../src/api/types";

const MIGRATION_PATH = fileURLToPath(
	new URL("../../../migrations/0001_user_auth_foundation.sql", import.meta.url),
);

/** The migration text, so a test can assert on the schema itself. */
export function readMigrationSql(): string {
	return readFileSync(MIGRATION_PATH, "utf8");
}

interface SqliteLike {
	exec(sql: string): void;
	prepare(sql: string): {
		get(...params: unknown[]): unknown;
		all(...params: unknown[]): unknown[];
		run(...params: unknown[]): unknown;
	};
	close(): void;
}

export interface TestDatabase extends SqlDatabase {
	close(): void;
}

/**
 * Creates an empty database with the migration applied.
 *
 * SQLite returns `[Object: null prototype]` rows, which are awkward to
 * compare in assertions, so rows are copied into plain objects on the way
 * out — the only translation this adapter performs.
 */
export async function createTestDatabase(): Promise<TestDatabase> {
	const { DatabaseSync } = (await import("node:sqlite")) as unknown as {
		DatabaseSync: new (path: string) => SqliteLike;
	};
	const db = new DatabaseSync(":memory:");
	db.exec(readMigrationSql());

	const makeStatement = (sql: string, bound: unknown[] = []): SqlStatement => ({
		bind: (...values: unknown[]) => makeStatement(sql, values),
		first: async <T>() => {
			const row = db.prepare(sql).get(...bound);
			return row === undefined ? null : (plain(row) as T);
		},
		all: async <T>() => ({
			results: db.prepare(sql).all(...bound).map(plain) as T[],
		}),
		run: async () => db.prepare(sql).run(...bound),
	});

	return {
		prepare: (sql: string) => makeStatement(sql),
		batch: async <T>(statements: SqlStatement[]) => {
			const results = [];
			for (const statement of statements) {
				await statement.run();
				results.push({ results: [] as T[], success: true } as never);
			}
			return results;
		},
		close: () => db.close(),
	};
}

function plain(row: unknown): Record<string, unknown> {
	return { ...(row as Record<string, unknown>) };
}
