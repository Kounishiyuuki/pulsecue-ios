/**
 * Ambient augmentation of the Worker `Env`. `wrangler types` only
 * regenerates bindings declared in wrangler.jsonc; secrets set via
 * `wrangler secret put` (or a local `.dev.vars`) are not, so the
 * import API key is declared here by hand.
 */
declare namespace Cloudflare {
	interface Env {
		/**
		 * Secret API key required as `Authorization: Bearer <key>` for
		 * POST /api/gym-machines/import. Set locally via `.dev.vars` and
		 * in production via `wrangler secret put PULSECUE_IMPORT_API_KEY`.
		 */
		PULSECUE_IMPORT_API_KEY: string;
		/**
		 * HMAC-SHA256 signing secret used by
		 * `POST /api/auth/import-token` to mint short-lived bearer
		 * tokens. **Must be different from `PULSECUE_IMPORT_API_KEY`**;
		 * the import-token route refuses to mint if this is unset. Set
		 * locally via `.dev.vars` and in production via
		 * `wrangler secret put PULSECUE_IMPORT_TOKEN_SECRET`.
		 */
		PULSECUE_IMPORT_TOKEN_SECRET: string;
	}
}
