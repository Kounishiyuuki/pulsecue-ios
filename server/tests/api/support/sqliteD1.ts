/**
 * A `SqlDatabase` backed by an in-memory SQLite, used to run the repository
 * tests against the **real migration file**.
 *
 * The point is that these tests exercise the actual SQL and the actual
 * constraints — UNIQUE (provider, subject), the CHECKs, the foreign keys,
 * `RETURNING seq` — rather than a hand-written fake that would happily agree
 * with a broken query.
 *
 * `batch()` matches D1's contract: the statements run inside one
 * transaction, and if any of them fails the whole thing is rolled back. A
 * double that merely ran them in sequence would report success for
 * non-atomic production code, which is exactly the false green this layer
 * exists to prevent.
 *
 * `node:sqlite` needs `--experimental-sqlite` before Node 23.4, which
 * `vitest.config.ts` adds only when the running Node requires it. It is a
 * dev-time detail: nothing here ships, and production runs on D1.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { SqlDatabase, SqlStatement } from "../../../src/api/types";

// `.href`, not the URL object: this package pulls in both the Workers and
// the Node globals, and the two `URL` types are not assignable to each other.
const MIGRATION_PATH = fileURLToPath(
	new URL("../../../migrations/0001_user_auth_foundation.sql", import.meta.url)
		.href,
);

/** The migration text, so a test can assert on the schema itself. */
export function readMigrationSql(): string {
	return readFileSync(MIGRATION_PATH, "utf8");
}

interface SqliteStatement {
	get(...params: unknown[]): unknown;
	all(...params: unknown[]): unknown[];
	run(...params: unknown[]): unknown;
}

interface SqliteLike {
	exec(sql: string): void;
	prepare(sql: string): SqliteStatement;
	close(): void;
}

/** A prepared statement that still knows how to execute itself. */
interface BoundStatement extends SqlStatement {
	readonly __execute: () => void;
}

export interface TestDatabase extends SqlDatabase {
	close(): void;
	/** Row count helper for assertions about partial state. */
	count(table: string): Promise<number>;
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

	const makeStatement = (sql: string, bound: unknown[]): BoundStatement => ({
		bind: (...values: unknown[]) => makeStatement(sql, values),
		first: async <T>() => {
			const row = db.prepare(sql).get(...bound);
			return row === undefined ? null : (plain(row) as T);
		},
		all: async <T>() => ({
			results: db
				.prepare(sql)
				.all(...bound)
				.map(plain) as T[],
		}),
		run: async () => db.prepare(sql).run(...bound),
		__execute: () => {
			db.prepare(sql).run(...bound);
		},
	});

	return {
		prepare: (sql: string) => makeStatement(sql, []),

		// D1 runs a batch as a single transaction. Reproducing that here is
		// what lets a test prove the production code is atomic.
		batch: async (statements: SqlStatement[]) => {
			db.exec("BEGIN");
			try {
				for (const statement of statements) {
					(statement as BoundStatement).__execute();
				}
				db.exec("COMMIT");
			} catch (error) {
				db.exec("ROLLBACK");
				throw error;
			}
			return statements.map(() => ({
				results: [],
				success: true,
			})) as never;
		},

		count: async (table: string) => {
			const row = db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get() as
				| { n: number }
				| undefined;
			return row?.n ?? 0;
		},

		close: () => db.close(),
	};
}

function plain(row: unknown): Record<string, unknown> {
	return { ...(row as Record<string, unknown>) };
}
