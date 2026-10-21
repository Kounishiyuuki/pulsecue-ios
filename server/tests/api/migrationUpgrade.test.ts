import { readFileSync, readdirSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { readMigrationSql } from "./support/sqliteD1";

const directory = fileURLToPath(new URL("../../migrations/", import.meta.url).href);
const migrations = readdirSync(directory).filter((name) => name.endsWith(".sql")).sort();
const read = (name: string) => readFileSync(`${directory}/${name}`, "utf8");

// D1 enables foreign keys before executing migrations. Setting the pragma
// inside BEGIN is a SQLite no-op, so do not rely on the migration's pragma.
function apply(db: DatabaseSync, names: string[]) {
	for (const name of names) {
		db.exec("BEGIN");
		try {
			db.exec(read(name));
			db.exec("COMMIT");
		} catch (error) {
			db.exec("ROLLBACK");
			throw error;
		}
		expect(db.prepare("PRAGMA foreign_key_check").all(), name).toEqual([]);
	}
}

function rows(db: DatabaseSync, sql: string) {
	return db.prepare(sql).all().map((row) => ({ ...row }));
}

const triggers = [
	"sessions_require_active_user",
	"trg_users_create_storage_usage",
	...["workout_sessions", "step_results"].flatMap((table) => [
		`trg_${table}_require_active_user_insert`,
		`trg_${table}_require_active_user_update`,
		`trg_${table}_tombstone_is_terminal`,
		`trg_${table}_count_insert`,
		`trg_${table}_count_delete`,
		`trg_${table}_owner_is_immutable`,
	]),
].sort();

describe("sequential release migrations", () => {
	it("keeps the shared API test schema in sync with discovered migration files", () => {
		expect(readMigrationSql()).toBe(migrations.map(read).join("\n"));
	});

	it.each([0, 1, 2, 3, 4, 5])("upgrades schema prefix %i transactionally without losing existing data", (prefix) => {
		const db = new DatabaseSync(":memory:");
		try {
			db.exec("PRAGMA foreign_keys = ON");
			apply(db, migrations.slice(0, prefix));
			if (prefix > 0) {
				db.exec(`
					INSERT INTO users (id,state,created_at,updated_at) VALUES ('busy','active',1,1), ('empty','active',1,1);
					INSERT INTO auth_identities (id,user_id,provider,subject,created_at,last_seen_at)
					VALUES ('identity','busy','apple','subject',1,1);
					INSERT INTO sessions (id,user_id,token_sha256,created_at,last_used_at,expires_at)
					VALUES ('session','busy','hash',1,1,999);
				`);
			}
			if (prefix >= 5) {
				db.exec(`
					INSERT INTO workout_sessions (id,user_id,started_at,change_seq,updated_at,deleted_at)
					VALUES ('live','busy',1,1,1,NULL), ('gone','busy',1,2,2,2);
					INSERT INTO step_results (id,user_id,session_id,exercise_name,order_index,change_seq,updated_at,deleted_at)
					VALUES ('live','busy','live','squat',0,1,1,NULL), ('gone','busy','gone','squat',0,2,2,2);
				`);
			}
			apply(db, migrations.slice(prefix));
			expect(rows(db, "SELECT name FROM sqlite_master WHERE type='trigger' ORDER BY name").map((row) => row.name)).toEqual(triggers);
			if (prefix === 0) return;
			expect(rows(db, "SELECT id, token_sha256 FROM sessions")).toEqual([{ id: "session", token_sha256: "hash" }]);
			expect(rows(db, "SELECT user_id, session_count, step_result_count FROM user_storage_usage ORDER BY user_id")).toEqual([
				{ user_id: "busy", session_count: prefix >= 5 ? 2 : 0, step_result_count: prefix >= 5 ? 2 : 0 },
				{ user_id: "empty", session_count: 0, step_result_count: 0 },
			]);
			// Both the backfilled counters and cascades must remain operational.
			db.exec("DELETE FROM users WHERE id='busy'");
			for (const table of ["sessions", "auth_identities", "workout_sessions", "step_results"]) {
				expect(rows(db, `SELECT COUNT(*) AS n FROM ${table}`)).toEqual([{ n: 0 }]);
			}
			expect(rows(db, "SELECT user_id FROM user_storage_usage")).toEqual([{ user_id: "empty" }]);
			expect(db.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
		} finally {
			db.close();
		}
	});
});
