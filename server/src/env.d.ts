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
	}
}
