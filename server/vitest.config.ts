import { defineConfig } from "vitest/config";

export default defineConfig({
	test: {
		// The account repository tests run the real migration against an
		// in-memory SQLite via `node:sqlite`, which Node 23 still gates
		// behind a flag. Passing it to the test workers keeps the existing
		// `npm test` command working unchanged.
		poolOptions: {
			forks: { execArgv: ["--experimental-sqlite"] },
			threads: { execArgv: ["--experimental-sqlite"] },
		},
	},
});
