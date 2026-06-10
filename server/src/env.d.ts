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
		/**
		 * Optional, **local/test-only** switch for mock auth on
		 * `POST /api/ai/training-plan`. When set to `"mock"`, the route
		 * requires a `Authorization: Bearer <token>` matching one of the
		 * `AI_TRAINING_PLAN_MOCK_*` values below. Any other value (or
		 * unset) leaves the endpoint UNGATED — the current default DEBUG
		 * loopback QA behavior. This is **not** production auth: there is
		 * no real token issuer/validation and no provider key here.
		 */
		AI_TRAINING_PLAN_AUTH_MODE?: string;
		/**
		 * Fake, local/test-only token accepted as a valid
		 * `ai:training-plan`-scoped token in mock-auth mode. Never a real
		 * secret or provider key. Unset unless mock auth is enabled.
		 */
		AI_TRAINING_PLAN_MOCK_VALID_TOKEN?: string;
		/**
		 * Fake, local/test-only token treated as expired in mock-auth mode
		 * (→ 401 `token_expired`). Never a real secret.
		 */
		AI_TRAINING_PLAN_MOCK_EXPIRED_TOKEN?: string;
		/**
		 * Fake, local/test-only token treated as wrong-scope in mock-auth
		 * mode (→ 403 `invalid_scope`). Never a real secret.
		 */
		AI_TRAINING_PLAN_MOCK_WRONG_SCOPE_TOKEN?: string;
	}
}
