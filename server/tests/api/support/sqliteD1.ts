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
// Applied in order, exactly as wrangler would.
const MIGRATION_FILES = [
	"0001_user_auth_foundation.sql",
	"0002_auth_nonces.sql",
	"0003_provider_credentials.sql",
	"0004_account_deletions.sql",
	"0005_workout_sync.sql",
];

// `.href`, not the URL object: this package pulls in both the Workers and
// the Node globals, and the two `URL` types are not assignable to each other.
function migrationPath(name: string): string {
	return fileURLToPath(new URL(`../../../migrations/${name}`, import.meta.url).href);
}

/** The migration text, so a test can assert on the schema itself. */
export function readMigrationSql(): string {
	return MIGRATION_FILES.map((name) =>
		readFileSync(migrationPath(name), "utf8"),
	).join("\n");
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
	readonly __execute: () => unknown[];
}

/** One statement as D1 would meter it. */
export interface RecordedQuery {
	sql: string;
	/** Bind parameters. D1 allows at most 100 per query. */
	bindings: number;
}

export interface TestDatabase extends SqlDatabase {
	close(): void;
	/** Row count helper for assertions about partial state. */
	count(table: string): Promise<number>;
	/**
	 * Every statement issued, including each one inside a `batch()`.
	 *
	 * D1 meters batched statements individually against the 1000-per-
	 * invocation limit, so a test that counted a batch as one query would
	 * report a budget the production platform does not agree with.
	 */
	recorded(): RecordedQuery[];
	resetRecording(): void;
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

	const log: RecordedQuery[] = [];
	const record = (sql: string, bound: unknown[]) => {
		log.push({ sql, bindings: bound.length });
	};

	const makeStatement = (sql: string, bound: unknown[]): BoundStatement => ({
		bind: (...values: unknown[]) => makeStatement(sql, values),
		first: async <T>() => {
			record(sql, bound);
			const row = db.prepare(sql).get(...bound);
			return row === undefined ? null : (plain(row) as T);
		},
		all: async <T>() => ({
			results: (record(sql, bound), db)
				.prepare(sql)
				.all(...bound)
				.map(plain) as T[],
		}),
		run: async () => {
			record(sql, bound);
			return db.prepare(sql).run(...bound);
		},
		__execute: () => {
			record(sql, bound);
			// D1 returns each batched statement's rows, and the upload path
			// now reads its sequence out of the batch itself. A double that
			// dropped them would make that code untestable here.
			const statement = db.prepare(sql);
			if (/^\s*select/i.test(sql)) {
				return (statement.all(...bound) as unknown[]).map((row) => ({
					...(row as Record<string, unknown>),
				}));
			}
			statement.run(...bound);
			return [];
		},
	});

	return {
		prepare: (sql: string) => makeStatement(sql, []),

		// D1 runs a batch as a single transaction. Reproducing that here is
		// what lets a test prove the production code is atomic.
		batch: async (statements: SqlStatement[]) => {
			db.exec("BEGIN");
			let rows: unknown[][];
			try {
				rows = statements.map((statement) =>
					(statement as BoundStatement).__execute(),
				);
				db.exec("COMMIT");
			} catch (error) {
				db.exec("ROLLBACK");
				throw error;
			}
			return rows.map((results) => ({
				results,
				success: true,
			})) as never;
		},

		recorded: () => [...log],
		resetRecording: () => {
			log.length = 0;
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
