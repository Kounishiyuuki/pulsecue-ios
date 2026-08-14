import { createRequire } from "node:module";
import { defineConfig } from "vitest/config";

/**
 * `node:sqlite` ships unflagged from Node 23.4 / 24, but earlier releases
 * that have it still hide it behind `--experimental-sqlite`. Probing once
 * here keeps a developer on an older local Node working without forcing the
 * flag onto a runtime that would reject it.
 */
function sqliteExecArgv(): string[] {
	try {
		createRequire(import.meta.url)("node:sqlite");
		return [];
	} catch {
		return ["--experimental-sqlite"];
	}
}

const execArgv = sqliteExecArgv();

export default defineConfig({
	test: {
		poolOptions: {
			forks: { execArgv },
			threads: { execArgv },
		},
	},
});
