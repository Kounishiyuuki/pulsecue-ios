# v1.0 server production readiness and operator runbook

Audit date: 2026-10-22 JST. Base: fetched `origin/main`
`ee65c512f2b116b05068d142e827296de5394bfe` (PR #202).

**Verdict: SERVER NOT RELEASE READY.** Local account API checks pass, but
production provisioning, credentials, exposure and client configuration have
not been verified. This document does not authorize production changes.
No production deploy, remote migration, secret mutation or data mutation was
performed during this audit. Cloudflare `whoami` failed with expired login;
therefore no live bindings, secret names, migrations or deployment were verified.

## Release gates

| Priority | Gate / owner action |
|---|---|
| P0 | No confirmed P0 in reviewed account API code. Live state remains unverified. |
| P1 | `wrangler.api.jsonc` has a placeholder D1 ID. Resolve the correct account/database and commit the verified binding before release. Never guess an ID. |
| P1 | Account API has no vars in repo. Verify all settings below and both real provider flows before availability. |
| P1, conditional | Separate gym/mock Worker is unsafe for public exposure: arbitrary nonempty attestation mints accepted import tokens when its signing secret is configured. Verify it is private/disabled and excluded from this release, or harden it in a separate change before exposing it. |
| Cross-lane | iOS accounts API origin and Google server client ID are placeholders. Coordinate the actual production origin and audiences with the iOS release owner. |
| Manual | Workers Paid, D1 migration history/schema, limiter namespaces, cron, secret presence, logs and monitoring require Cloudflare/operator evidence. |

Residual P2: valid Google ID tokens can create repeated sessions until token
expiry; there is no per-user session count ceiling. IP throttling bounds local
request rate, not total stored sessions. Monitor sign-in/session growth and
cleanup backlog; a per-user issuance/retention policy is follow-up hardening.
Provider deadlines do not propagate the inbound request AbortSignal. A client
disconnect may leave bounded work running; do not assume disconnect rolls back
an already committed auth, sync or deletion operation.

## Current inventory

Two independent Workers share this package. **Always select the config.**
`npm run deploy` without flags targets the gym/mock Worker, not accounts.

| Worker | Config / entry | Routes |
|---|---|---|
| Accounts/sync | `wrangler.api.jsonc`, `src/api/index.ts` | `GET /health`; `POST /v1/auth/apple`, `/v1/auth/google`, `/v1/auth/logout`, `/v1/auth/logout-all`; `GET /v1/me`, `DELETE /v1/me`; `GET/POST /v1/sync/workouts` |
| Gym/mock, excluded | `wrangler.jsonc`, `src/index.ts` | `GET /health`; `POST /api/auth/import-token`, `/api/gym-machines/import`, `/api/ai/training-plan` |

Accounts uses `2026-05-14` compatibility date, `nodejs_compat`, Workers.dev,
observability and source maps. No custom domain, route, staging environment or
explicit account ID is declared. The selected Cloudflare account is therefore
an operator check. Health returns `{status:"ok",service:"pulsecue-api"}` and
is **liveness only**: it does not validate DB, secrets, auth or limiters.
No CORS middleware is installed; native iOS does not require CORS. Do not add
wildcard browser access as a deployment workaround.

Account/auth behavior (`src/api/auth`, `src/api/db`, `src/api/middleware`):

- Opaque 256-bit sessions; only SHA-256 hashes are persisted. Absolute 60-day
  expiry; every lookup joins the active user. Missing/unknown/expired/revoked
  credentials and deleting accounts return the same sanitized 401.
- Apple verifies RS256 signature, pinned issuer/audience and nonce hash.
  Unique nonce claim prevents replay. Authorization code exchange checks the
  returned identity; encrypted refresh credential and session are committed
  atomically. Failed persistence attempts compensating provider revocation.
  Indeterminate provider outcomes still need operator monitoring.
- Google verifies RS256, issuer, expiry and Web/server client audience.
  Valid Google ID tokens intentionally remain replayable until expiry.
  Accounts match only provider+subject, never email; no Google refresh token
  or Google client secret is retained.
- Apple refresh tokens use AES-256-GCM, random IV, row/provider-bound additional
  authenticated data and stored key version. Keep previous key available while
  any credential references it; never rotate/remove keys casually.
- Deletion first durably marks deleting and revokes sessions, then revokes
  Apple credentials before cascading hard deletion. Failures stay deleting,
  queued for retry rather than restoring access. A repeated HTTP request with
  the revoked bearer returns 401; the durable scheduled job performs retries.
- Sync owner comes from the session, never request-supplied user identity.
  Composite `(user_id,id)` keys and composite step/session FKs prevent IDOR.
  Sequence bump and upload are one atomic batch. Upload cap is 500 combined
  mutations; pull paging preserves complete change sequences. Tombstones are
  terminal and writes require active users at statement time.
- Stored sync quotas: 10,000 workout sessions and 100,000 step results per
  user, including tombstones. Trigger counters and named CHECK constraints
  enforce concurrent writes atomically. Updates/retries do not spend rows.
- Cron `*/15 * * * *` (UTC) independently retries up to 50 deletions, removes
  up to 500 nonces beyond expiry plus 60-second skew, and up to 500 sessions
  beyond expiry plus seven days. Revoked sessions are not purged early.
  Any failed step marks the run failed after all steps have been attempted.

## Security gate evidence

| Threat | Control / relevant test suites |
|---|---|
| Body-size abuse | 16 KiB sign-in, 1 MiB sync; body limit runs before limiter/auth/DB/JSON (`bodyLimit`) |
| Unauthenticated / brute-force abuse | API IP 300/min, shared provider auth IP 60/min, ahead of D1 (`rateLimit`) |
| Authenticated abuse | Sync 30/min/user; deletion + logout-all 10/min/user; coarse API IP guard on reads too |
| Limiter failure | Missing binding/IP, throw or malformed answer refuses 503; exhausted bucket 429; no fallback header |
| Storage abuse | Physical-row quota, atomic counters including deletes/tombstones (`storageQuota`) |
| Cross-user access / IDOR | Session-derived ownership, scoped queries/composite FKs (`workoutSyncHardening`, `atomicity`) |
| Token/session leakage | Hash-only sessions, encrypted provider credentials; allowlisted `/me` (`sessions`, `sessionLifecycle`, `tokenCipher`) |
| Nonce replay / stale state | Unique Apple nonce, skew-aware sweeps and race tests (`appleNonceCleanupRace`, `authStateCleanup`) |
| Deletion retry | Durable deleting state, immediate revocation, scheduled retry (`accountDeletion`, `scheduledAccountDeletion`) |
| Provider timeout/malformed body | JWKS 4s; Apple exchange/revoke 8s covering headers + body, actual fetch abort; sanitized errors (`externalFetchTimeouts`, `appleTokenExchange`, `jwks`) |
| Raw exceptions / log PII | Fixed error codes + correlation IDs; scheduled run IDs/counts; never raw provider errors. This change logs registered route patterns instead of user URL paths (`unhandledError`) |
| Request cancellation | Deadline cancels upstream on timeout; unused provider bodies canceled. Client abort propagation is not implemented |

Pinned external endpoints are Apple JWKS, token exchange and revoke at
`appleid.apple.com`, and Google JWKS at `www.googleapis.com/oauth2/v3/certs`.
JWKS uses isolate caching (6h), shared in-flight fetch, unknown-key cooldown
(60s) and failure backoff (5s). No arbitrary provider URL is taken from clients.
Application logs omit bearer tokens, raw nonces, provider subject, email, IP,
SQL and original exception. Cloudflare platform request metadata/log retention,
access control, Logpush and URL collection remain manual privacy gates; app
sanitization does not imply platform metadata is absent.

The excluded gym Worker uses a static import key or HMAC token; its mint gate
is a placeholder and mock AI is ungated by default. It lacks these account API
body/rate controls, logs raw exceptions, and reflects upstream fetch error
messages. Its importer follows redirects after initial hostname validation;
that validation is not a complete SSRF policy. Do not treat account API checks
as clearing this other Worker. Its settings are `PULSECUE_IMPORT_API_KEY`,
`PULSECUE_IMPORT_TOKEN_SECRET`, and optional mock-only
`AI_TRAINING_PLAN_AUTH_MODE`; none belong in the iOS binary.

## Production configuration: repository vs live checks

| Requirement | Repository evidence | Must verify externally |
|---|---|---|
| D1 `DB` / `pulsecue-api` | Migration dir `migrations`; ID placeholder | Correct account/UUID, region/capacity, migration history, actual schema |
| API_IP_RATE_LIMITER | namespace 3195001; 300/60s | Binding installed; namespace not reused account-wide |
| AUTH_IP_RATE_LIMITER | namespace 3195002; 60/60s | Same; edge supplies CF-Connecting-IP, no removal transform |
| SYNC_USER_RATE_LIMITER | namespace 3195003; 30/60s | Same |
| ACCOUNT_USER_RATE_LIMITER | namespace 3195004; 10/60s | Same |
| Cron | `*/15 * * * *`, exported scheduled handler | Installed trigger, successful live runs, alert/backlog ownership |
| Runtime | Date and node compatibility declared | Paid plan; real CPU/DB latency headroom, quota/error alerts |
| Routing | Workers.dev enabled, no custom domain | Correct HTTPS production origin, exposure/access controls |
| Vars | No API vars committed | All configured before deploy; preserved using `--keep-vars` below |
| Secrets | Consumed by code, values absent in repo | Name presence plus functional smoke; presence alone is insufficient |

Required non-secret settings: `APPLE_AUDIENCE` (native bundle audience),
`APPLE_CLIENT_ID` (code exchange client), `APPLE_TEAM_ID`, `APPLE_KEY_ID`,
`GOOGLE_AUDIENCE` (Web/server OAuth client ID matching iOS `GIDServerClientID`).
Verify Apple client/audience relationship against the actual native provider
configuration; do not substitute a web Services ID by guesswork.
`APPLE_TOKEN_ENCRYPTION_KEY_VERSION` defaults to 1; make the chosen version
explicit operationally. Optional rotation settings:
`APPLE_TOKEN_ENCRYPTION_KEY_PREVIOUS_VERSION` and secret
`APPLE_TOKEN_ENCRYPTION_KEY_PREVIOUS`.

Required secrets: `APPLE_PRIVATE_KEY` (Sign in with Apple ES256 .p8 PEM) and
`APPLE_TOKEN_ENCRYPTION_KEY` (base64 encoding of 32 random bytes).
Never print, copy into evidence, commit or include their values in PRs.
`wrangler secret list` only lists names/types. No secret write commands are
part of this runbook execution; if missing, stop for a separately authorized
credential setup. Secret writes can themselves create deployments.

Rate limiting is location-local and eventually consistent, not a global exact
quota. Sync storage quota is the separate persistent enforcement mechanism.
Paid plan is required: sync exceeds Free's DB query budget at maximum batch,
and sequential deletion retries may wait about 400s (50 × 8s) plus local work.
Validate actual production CPU and cron completion, rather than inferring
performance from unit tests or the liveness probe.

## Migration audit

| File | Objects and upgrade considerations |
|---|---|
| 0001 | Users, identities, profiles, sessions, change sequence; provider/subject uniqueness, hash uniqueness, state CHECK, user FKs/cascades |
| 0002 | Nonce hash primary key, provider CHECK, expiry index; no user ownership needed |
| 0003 | Encrypted provider credentials, composite identity/provider FK; active-user session INSERT trigger aborts whole auth batch |
| 0004 | Deletion retry state with cascade, due index, closed-set error-code CHECK |
| 0005 | Composite owner keys/FKs, pull indexes, active-user insert/update guards and terminal tombstone triggers |
| 0006 | Usage table, CHECK quota/nonnegative counters, create/backfill usage, insert/delete counters, immutable sync ownership |

There are 14 triggers at latest schema. SQL creates are intentionally not
idempotent: Wrangler's `d1_migrations` ledger prevents reapplication. Do not
re-run raw SQL or rename/rewrite applied migration files. Each failing
migration rolls back individually; earlier successful migrations stay applied.
There are no down migrations. Prefer additive forward fixes.

0006 backfills existing physical rows including tombstones. Any existing user
above 10,000 sessions or 100,000 results aborts migration; never clamp/truncate
production data to force success. Check aggregate over-quota account counts
before maintenance (SQL below). Pause writes during migration; do not rely on
commentary about concurrent writes as an operational guarantee. Latest code
requires latest schema. A SQLite upgrade test is not evidence that remote
migration history matches this repository.

## Reproducible local preflight

Use Node `>=24 <25` (`package.json`); npm is not version-pinned.
Audit used Node 24.21.0 / npm 11.19.0, locked Wrangler 4.149.0.
Run from `server/` on the reviewed release commit:

```sh
node --version
npm --version
npm ci
npm audit
npm audit --omit=dev
npm run check
npx wrangler deploy --config wrangler.api.jsonc --dry-run --outdir /tmp/pulsecue-api-rc-bundle
```

Dry-run compiles without deploying; it does not verify remote DB/secrets or
provider registration. Use a fresh temporary directory for isolated local D1:

```sh
rc_d1_dir=$(mktemp -d /tmp/pulsecue-rc-d1.XXXXXX)
npx wrangler d1 migrations apply pulsecue-api --config wrangler.api.jsonc --local --persist-to "$rc_d1_dir"
npx wrangler dev --config wrangler.api.jsonc --local --persist-to "$rc_d1_dir" --test-scheduled --port 8791
```

In a second terminal:

```sh
curl --fail-with-body http://localhost:8791/health
curl -i -H 'cf-connecting-ip: 203.0.113.90' http://localhost:8791/v1/me
curl --fail-with-body 'http://localhost:8791/cdn-cgi/local/scheduled?cron=*/15+*+*+*+*'
```

Expect 200 health, 401 unauthenticated me, successful scheduled response and
three maintenance event logs. Do not use `--remote` for local testing.
For restricted local environments, this audit redirected Wrangler diagnostic
logs and local service registry to temporary directories via
`WRANGLER_LOG_PATH` and `WRANGLER_REGISTRY_PATH`; no global files were changed.

## Operator deployment order — NOT executed in this audit

Stop if any earlier gate fails. The following remote write commands are for a
subsequent explicitly authorized production release, not this audit.

1. Approve the exact commit and account Worker only. Resolve the D1 binding;
   if database provisioning is needed, perform it separately and review its
   config change. Verify the gym/mock Worker is not publicly exposed.
   Verify iOS archive origin, Apple configuration, Google audience and secrets.
   Complete local preflight above. Record rollback version, ownership and
   maintenance window in private release evidence.
2. Authenticate Cloudflare and perform read-only checks (from `server/`):

   ```sh
   npx wrangler whoami
   npx wrangler deployments list --config wrangler.api.jsonc
   npx wrangler secret list --config wrangler.api.jsonc
   npx wrangler d1 info pulsecue-api --config wrangler.api.jsonc
   npx wrangler d1 migrations list pulsecue-api --config wrangler.api.jsonc --remote
   npx wrangler d1 execute pulsecue-api --config wrangler.api.jsonc --remote --command "SELECT name, type FROM sqlite_master WHERE type IN ('table','trigger','index') ORDER BY type,name;"
   ```

   Inspect migration definitions privately against repo SQL, not merely names.
   For an existing DB with 0005 applied, check over-quota account counts:

   ```sh
   npx wrangler d1 execute pulsecue-api --config wrangler.api.jsonc --remote --command "SELECT COUNT(*) AS over_quota_accounts FROM (SELECT user_id FROM workout_sessions GROUP BY user_id HAVING COUNT(*) > 10000 UNION SELECT user_id FROM step_results GROUP BY user_id HAVING COUNT(*) > 100000);"
   ```

   If earlier schema lacks these tables, follow its reviewed migration prefix;
   do not run a query referencing absent tables. Dashboard verification covers
   vars, namespace uniqueness, Paid plan, routes, platform logs and alerts.
3. Pause application writes through the operator's existing traffic control;
   if none exists, establish an approved maintenance procedure before upgrade.
   Recheck quota counts after the pause. Record a recoverable Time Travel
   bookmark before migration, and confirm plan retention/recovery access:

   ```sh
   npx wrangler d1 time-travel info pulsecue-api --config wrangler.api.jsonc --json
   ```

   A full SQL export contains credentials/PII and is not a routine PR artifact.
   Store any separately required backup only in approved private storage.
4. **Remote mutation, operator only:** apply pending migrations before code:

   ```sh
   npx wrangler d1 migrations apply pulsecue-api --config wrangler.api.jsonc --remote
   ```

   Verify ledger, 14 triggers and `PRAGMA foreign_key_check` (must return no
   rows). On existing data compare usage counters to actual counts using an
   aggregate mismatch count, without exporting user rows. Stop on any failure.
5. **Production deploy, operator only:** preserve already verified dashboard
   vars because repo has no vars block. Plain deploy can remove those vars.

   ```sh
   npx wrangler deploy --config wrangler.api.jsonc --keep-vars
   ```

   Do not use unqualified `npm run deploy`. Capture version/deployment IDs.
6. Check HTTPS `/health` returns the account service, not the gym health body.
   Unauthenticated `/v1/me` must return 401 (503 indicates a binding/IP issue).
   Use a dedicated operator test account in the actual release app for Apple
   and Google sign-in, `/me`, logout and re-sign-in. Never paste bearer tokens
   into shell history or PR evidence. Confirm expected provider audience and
   absence of token/PII logs.
7. With two dedicated test users, upload/pull/retry a small workout and check
   isolation, tombstone propagation and account deletion. Verify deletion makes
   prior sessions unusable; an interrupted provider revocation stays pending.
   These are deliberate production test data writes requiring release approval.
   Resume traffic only after these checks pass.
8. Observe live cron logs for all three maintenance categories and successful
   runs, including the next 15-minute cycle. Verify pending deletions progress;
   monitor cleanup backlog, D1 storage/query errors, provider errors, 429/503
   rates and unhandled-error correlation IDs. Local scheduled testing does
   not prove that the production trigger is installed or propagated.

## Rollback and incident action

Before deploy record an explicit known-good version compatible with current
schema. Worker rollback does **not** undo D1 migrations or restore deleted
accounts/provider grants. A first-ever deployment has no prior version;
prepare traffic disablement/maintenance access in advance.

After incident authorization, with traffic controlled, code-only rollback is:

```sh
npx wrangler rollback VERIFIED_PREVIOUS_VERSION_ID --config wrangler.api.jsonc
```

Replace that placeholder with the recorded version; do not choose by guess.
Keep schema 0006 for code rollback only if compatibility was verified. Do not
remove quota triggers or restore a database just to reverse application code.
Forward repair is preferred. D1 Time Travel restore is a separate destructive
incident decision: it can lose newer writes and resurrect deleted accounts,
while Apple revocation cannot be undone. Reconcile deletion/provider state,
retention obligations and downtime before any restore. No restore command is
executed or prescribed as an automatic rollback here.

## Cross-lane handoff (no iOS edits in this change)

- `Pulse Cue/Info.plist` has `PulseCueAPIBaseURL=https://YOUR_PULSECUE_API_HOST`.
  `Auth/PulseCueAPIConfiguration.swift` rejects the placeholder, disabling
  accounts. Debug/Release both use this plist; establish the actual Release
  origin and inspect the final archive. Server origin is configuration, not a
  credential; the server README asks that deployed URLs stay out of public PRs.
- `GIDServerClientID` is a placeholder Web/server OAuth ID; it must match
  `GOOGLE_AUDIENCE`. Public OAuth IDs are not server secrets.
- URL validation requires HTTPS and rejects embedded credentials, but HTTPS
  localhost/staging is not excluded. No hardcoded production fallback found.
  AI loopback configuration is inside `#if DEBUG`.
- No server secret was observed in inspected app configuration. No private
  credential files or secret values were read for this audit.

## Validation record and official references

Completed: Node24 npm ci; both audits (zero vulnerabilities); initial full
check (707 tests); clean local Wrangler D1 migrations 0001–0006; accounts
bundle dry-run; local health/401 and all-three-step scheduled smoke. New
upgrade regression tests cover each historical migration prefix. Final full
check: 39 test files, 715 tests passed, both TypeScript checks passed.
Warnings: future Vite native config-loader
compatibility and Wrangler generated-type freshness; no binding changed here.
Cloudflare live checks and real-provider smoke are unverified, not passed.

Current official docs consulted on audit date:

- [Wrangler Workers commands: dry-run, local dev, keep-vars, rollback](https://developers.cloudflare.com/workers/wrangler/commands/workers/)
- [D1 commands: migration list/apply, info, execute, Time Travel info](https://developers.cloudflare.com/d1/wrangler-commands/)
- [D1 migration ledger and per-migration failure behavior](https://developers.cloudflare.com/d1/reference/migrations/)
- [Time Travel recovery and retention](https://developers.cloudflare.com/d1/reference/time-travel/)
- [Rate Limiting binding semantics](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/)
- [Workers limits](https://developers.cloudflare.com/workers/platform/limits/)
- [D1 limits](https://developers.cloudflare.com/d1/platform/limits/)
