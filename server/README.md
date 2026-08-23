# PulseCue Server

Cloudflare Workers + Hono backend for PulseCue. This package currently
ships a single feature: a best-effort **gym machine import** endpoint
that scrapes the readable text from a gym's official page and reports
which known machines it recognized.

The iOS app does **not** consume this API yet — it is implemented and
verified in isolation here first.

## Endpoints

### `GET /health`

Liveness probe.

```bash
curl https://<your-worker-host>/health
# → { "ok": true }
```

### `POST /api/gym-machines/import`

Takes a gym name and the URL of that gym's official page, fetches the
page, and returns the machines the parser recognized.

**Requires authentication.** The endpoint accepts **either** of two
bearer formats, evaluated in this order:

1. **Long-lived API key** — for server/admin/dev callers.
   ```
   Authorization: Bearer <PULSECUE_IMPORT_API_KEY>
   ```
2. **Short-lived import token** — for the future iOS client.
   ```
   Authorization: Bearer <token from POST /api/auth/import-token>
   ```
   The token is HMAC-SHA256-signed with `PULSECUE_IMPORT_TOKEN_SECRET`
   and carries a payload binding `deviceId`, expiry, and the fixed
   scope `gym-machines:import`. The middleware verifies the signature
   in constant time, refuses expired tokens, and refuses tokens whose
   scope is anything else.

Missing, malformed, expired, wrong-signed, or wrong-scoped credentials
all return the same `HTTP 401` envelope:

```json
{ "error": { "code": "unauthorized", "message": "A valid API key is required" } }
```

`GET /health` stays public — no key required.

> If `PULSECUE_IMPORT_TOKEN_SECRET` is unset, only the long-lived API
> key path works; short-lived tokens are rejected.

Request body:

```json
{
  "gymName": "Example Gym Shibuya",
  "officialUrl": "https://example.com/gyms/shibuya"
}
```

Response shape:

```json
{
  "gymName": "Example Gym Shibuya",
  "officialUrl": "https://example.com/gyms/shibuya",
  "candidates": [
    {
      "id": "lat_pulldown",
      "name": "lat_pulldown",
      "matchedText": "ラットプルダウン",
      "confidence": 0.7
    }
  ],
  "warnings": []
}
```

Example call:

```bash
curl -X POST https://<your-worker-host>/api/gym-machines/import \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <PULSECUE_IMPORT_API_KEY>' \
  -d '{
    "gymName": "Example Gym Shibuya",
    "officialUrl": "https://example.com/gyms/shibuya"
  }'
```

Error responses use a uniform envelope:

```json
{ "error": { "code": "invalid_body", "message": "officialUrl: required" } }
```

Possible `code` values: `unauthorized`, `invalid_body`, `missing`,
`malformed`, `unsupported_scheme`, `private_host`, `fetch_failed`,
`invalid_attestation`, `rate_limited`, `not_found`, `internal_error`.

### `POST /api/auth/import-token`

Mints a **short-lived** bearer token the future iOS client will use
when calling `POST /api/gym-machines/import`. Designed so the
long-lived `PULSECUE_IMPORT_API_KEY` never ships in the App Store
binary. Spec: [`Docs/import-token-endpoint-spec.md`](../Docs/import-token-endpoint-spec.md).

Request body:

```json
{
  "deviceId": "<UUID for the calling device>",
  "appVersion": "<CFBundleShortVersionString + build>",
  "attestation": "<App Attest assertion (production) or any non-empty placeholder (dev)>"
}
```

Response:

```json
{
  "token": "<base64url payload>.<base64url HMAC-SHA256>",
  "expiresAt": "2026-05-17T00:00:00.000Z",
  "ttlSeconds": 86400
}
```

Example call:

```bash
curl -X POST https://<your-worker-host>/api/auth/import-token \
  -H 'Content-Type: application/json' \
  -d '{
    "deviceId": "9F3C2F8E-1E1B-4C2D-9B8C-1F0E2D3A4B5C",
    "appVersion": "1.0.0 (1)",
    "attestation": "dev-placeholder-assertion"
  }'
```

> **Production warning:** the `attestation` field is currently
> validated only as a non-empty string. **Before exposing the Worker
> publicly, replace this with real App Attest assertion verification.**
> The placeholder posture is intentional for the MVP and is documented
> in [`Docs/import-token-endpoint-spec.md`](../Docs/import-token-endpoint-spec.md) §5.
> Today's import endpoint still enforces the long-lived
> `PULSECUE_IMPORT_API_KEY` bearer — the mint endpoint does **not**
> change that yet.

Errors use the same envelope as the rest of the Worker:

| `code` | HTTP | When |
|---|---|---|
| `invalid_body` | 400 | malformed JSON / missing or empty `deviceId` / `appVersion` / `attestation` |
| `invalid_attestation` | 401 | reserved for the real App Attest gate; the placeholder validator covers empty input via `invalid_body` |
| `rate_limited` | 429 | reserved for the future rate-limit pass (PR-δ) |
| `internal_error` | 500 | `PULSECUE_IMPORT_TOKEN_SECRET` unset, or HMAC failure |

## Environment variables

| Name | Required | Purpose |
|------|----------|---------|
| `PULSECUE_IMPORT_API_KEY` | Yes | Secret bearer token that gates `POST /api/gym-machines/import`. If unset, the endpoint rejects **every** request (fail-closed). |
| `PULSECUE_IMPORT_TOKEN_SECRET` | Yes (for `/api/auth/import-token`) | HMAC-SHA256 signing secret used to mint short-lived bearer tokens. **Must be different from `PULSECUE_IMPORT_API_KEY`.** If unset, `POST /api/auth/import-token` returns `500 internal_error`. |

## Setup

```bash
cd server
npm install
```

`node_modules`, `.wrangler/`, `.env*`, and `.dev.vars*` are git-ignored.
**Do not commit `node_modules` or any secret file (`.dev.vars`).**

## Local development

For local runs, `wrangler dev` reads secrets from a `.dev.vars` file
in `server/`. Copy the example and fill in any non-empty values —
they only have to match what you send while testing:

```bash
cp .dev.vars.example .dev.vars
# edit .dev.vars and set:
#   PULSECUE_IMPORT_API_KEY=<your-local-dummy-key>
#   PULSECUE_IMPORT_TOKEN_SECRET=<any non-empty random string>
```

Both keys must be different from each other in practice.

`.dev.vars` is git-ignored; `.dev.vars.example` is the committed
template and must never contain a real secret.

```bash
npm run dev       # wrangler dev — http://localhost:8787
npm run test      # vitest run
npm run typecheck # tsc --noEmit
```

Smoke test against a local dev server:

```bash
# public — no auth needed
curl http://localhost:8787/health

# protected — fails without a key
curl -X POST http://localhost:8787/api/gym-machines/import \
  -H 'Content-Type: application/json' \
  -d '{"gymName":"Test","officialUrl":"https://example.com/"}'
# → 401 unauthorized

# protected — succeeds with the key from .dev.vars
curl -X POST http://localhost:8787/api/gym-machines/import \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <your-local-dummy-key>' \
  -d '{"gymName":"Test","officialUrl":"https://example.com/"}'

# mint a short-lived token, then use it against the import endpoint
TOKEN=$(curl -sS -X POST http://localhost:8787/api/auth/import-token \
  -H 'Content-Type: application/json' \
  -d '{
    "deviceId":"9F3C2F8E-1E1B-4C2D-9B8C-1F0E2D3A4B5C",
    "appVersion":"1.0.0 (1)",
    "attestation":"dev-placeholder-assertion"
  }' | jq -r .token)

curl -X POST http://localhost:8787/api/gym-machines/import \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"gymName":"Test","officialUrl":"https://example.com/"}'
```

> The import endpoint accepts either credential interchangeably (it
> tries the long-lived API key first, then short-lived token). The
> long-lived path is unchanged from PR #18; short-lived tokens are the
> new path added in this PR for future iOS clients.
> **App Attest validation on the mint endpoint is still a placeholder
> (any non-empty `attestation` is accepted) until a future PR.**

## Production secret

Do not put either secret in `wrangler.jsonc` or `.dev.vars`. Set them
as encrypted Worker secrets, with **independent random values**:

```bash
wrangler secret put PULSECUE_IMPORT_API_KEY
wrangler secret put PULSECUE_IMPORT_TOKEN_SECRET
```

> The token signing secret is what lets the future iOS client mint
> short-lived bearers without ever holding the long-lived
> `PULSECUE_IMPORT_API_KEY`. Rotating it invalidates all outstanding
> tokens, which is the intended emergency-rotation behavior.

## Deploy

```bash
npm run deploy
```

> Deployment is intentionally **not** performed by this task. Run the
> deploy command yourself when you are ready to publish.

## Project layout

```
src/
  index.ts                       Hono app + route registration
  routes/
    health.ts                    GET /health
    importGymMachines.ts         POST /api/gym-machines/import
    authImportToken.ts           POST /api/auth/import-token
  auth/
    tokens.ts                    HMAC-signed short-lived bearer mint
  parser/
    url.ts                       URL validation (http/https only)
    extractText.ts               HTML → readable text
    machines.ts                  Canonical machine catalog + aliases
    matchMachines.ts             Alias matcher with dedupe + scoring
tests/                           Vitest suites for parser + token + route
```

## Machine catalog

Currently recognized canonical machine ids:

```
bench_press        smith_machine      dumbbells          cable_machine
lat_pulldown       seated_row         chest_press        shoulder_press
leg_press          leg_extension      leg_curl           pec_deck
back_extension     pull_up_bar        treadmill          bike
```

Aliases include both Japanese (ラットプルダウン, スミスマシン, レッグプレ
ス, etc.) and English (`Lat Pulldown`, `Smith Machine`, `Leg Press`).
Matching is case-insensitive, NFKC-normalized, and longest-alias-first
so that `Smith Machine` is not lost to a generic `Machine`.

## Limitations

- **No JavaScript rendering.** Pages that load machine names via JS
  may return an empty `candidates` array; this is reported in
  `warnings`.
- **Best-effort matching only.** The parser uses simple alias lookup,
  not NLP. Off-catalog or marketing names will be missed.
- **`matchedText` is the alias surface form** (not the surrounding
  sentence), so it is not a citation of the page.
- **`confidence` is heuristic.** It is a function of how many aliases
  for a machine were seen and how many times, clamped to [0.5, 0.95].
  Do not treat it as a probability.
- **Single URL fetch only.** The endpoint does not crawl sub-pages.
- **Response cap 2 MB.** Large pages are truncated.
- **Timeout 8 s.** Slow upstreams return `fetch_failed`.

## Security notes

- **Do not commit secrets.** Use `wrangler secret put` for any future
  keys; never check in `.dev.vars` or `.env*`.
- **Deployed Worker URL is intentionally not recorded in this repo.**
  Do not include it in commits, PR descriptions, or issues.
- **No deploy is performed by automation.** Run `npm run deploy`
  yourself when you are ready to publish.
- **Auth required for imports.** `POST /api/gym-machines/import` is
  gated by an `Authorization: Bearer` check. The middleware accepts
  **either** the long-lived `PULSECUE_IMPORT_API_KEY` (constant-time
  compare) or a short-lived HMAC-SHA256-signed token whose payload
  carries the fixed scope `gym-machines:import` and an expiry that is
  re-checked against current time on every request. Signature
  verification uses `crypto.subtle.verify` (constant-time at the
  runtime layer). Either path failing falls through to the same `401
  unauthorized` envelope; the response body never echoes the supplied
  bearer back (asserted in tests). `GET /health` stays public. Set
  both secrets in production with `wrangler secret put`.
- **Token mint is App-Attest-placeholder for now.**
  `POST /api/auth/import-token` accepts any non-empty `attestation`
  string today and is intended to be tightened to real App Attest
  verification before public exposure. Tokens are HMAC-SHA256-signed
  with `PULSECUE_IMPORT_TOKEN_SECRET` and never logged. The mint
  endpoint **does not** weaken the import endpoint's `Authorization:
  Bearer <PULSECUE_IMPORT_API_KEY>` requirement; that change will land
  in a later PR once the App Attest path is in.
- **No web search.** The Worker never picks its own targets — it
  fetches exactly the `officialUrl` provided by the caller.
- **JS-rendered pages may be empty.** Static HTML is the only source.
- **Basic SSRF guard.** Requests to `localhost`, loopback (`127.0.0.0/8`,
  `::1`), link-local (`169.254.0.0/16`), and RFC 1918 ranges (`10.0.0.0/8`,
  `172.16.0.0/12`, `192.168.0.0/16`) are refused. This is a string-level
  check on the supplied hostname, not a full network ACL — production
  deployments should still rely on Cloudflare egress policy where
  available.
- **Only `http:` and `https:` schemes** are accepted. `file:`, `ftp:`,
  `javascript:`, etc. are rejected at validation time.

## `pulsecue-api` (accounts) — foundation only

A **second Worker** lives in this package, configured by
`wrangler.api.jsonc` with its entry at `src/api/index.ts`. It is separate
from `pulsecue-gym-machine-api` on purpose: that Worker is
machine-to-machine (a static import key and short-lived HMAC tokens, no
users), while this one owns accounts and per-user data. Mixing two
authorization models in one router would be a mistake.

Routes:

| Route | Auth |
|---|---|
| `GET /health` | none |
| `POST /v1/auth/apple` | none (sign-in) |
| `POST /v1/auth/google` | none (sign-in) |
| `GET /v1/me` | bearer session |
| `POST /v1/auth/logout` | bearer session |
| `POST /v1/auth/logout-all` | bearer session |
| `DELETE /v1/me` | bearer session |
| `POST /v1/sync/workouts` | bearer session |
| `GET /v1/sync/workouts` | bearer session |

### Authenticated requests

`Authorization: Bearer <opaque session token>`. The token is hashed and looked
up; `findActiveSessionByToken` joins `users`, so the account's state is
re-checked on **every** request and a session cannot outlive its account even
if a revocation were somehow missed.

Six different facts get one answer, `401 invalid_session`: missing header,
malformed header, unknown token, expired, revoked, and account-being-deleted.
Telling them apart would let a caller probe which tokens ever existed, and
would make account deletion observable from outside. A test asserts the six
responses are byte-identical apart from the correlation id.

The bearer parser is deliberately strict — one scheme, one token, no internal
whitespace. A lenient parser is how a token ends up read from somewhere it was
never meant to be. The raw token never reaches a log.

The middleware is attached **per route**, not globally. A global guard that a
future sign-in route silently inherits locks users out; one a future
authenticated route silently misses is caught by that route's own tests. The
second failure is the recoverable one.

### `GET /v1/me`

An explicit allowlist, not a row — `SELECT *` reaching a client is how a
schema change quietly becomes a disclosure. Returns the user id, state,
display name, creation time, which providers are linked and when, and the
caller's own session expiry.

Deliberately absent: the **provider subject** (it is the account key, and
echoing it back turns a stolen session into a correlatable identity across
services), the **email** (the app has no use for it, and Apple's private relay
address is not something to surface without a reason), the session token hash,
and any credential material. Pinned by a test that asserts the exact key set
and greps the response for each of them.

### Logout

`POST /v1/auth/logout` revokes exactly the session that authenticated the
request — signing out of a phone must not sign out the iPad.
`POST /v1/auth/logout-all` is the deliberate opposite, for a lost device. Both
scope by the authenticated user; there is no user id in either request to
tamper with.

Revocation is one UPDATE and takes effect on the next request, which is the
whole point of storing sessions rather than making them self-contained.

**What is idempotent, and what is not.** The revocation *mutation* is:
revoking an already-revoked session changes nothing and keeps the original
`revoked_at`. The HTTP endpoint is a different question and is deliberately
not exempt from authentication — replaying the same bearer after a successful
logout meets the session middleware first, which no longer recognises that
token and normalises it to `401 invalid_session` like any other revoked
credential.

| Call | Result |
|---|---|
| first `POST /v1/auth/logout` | `200` |
| same raw token again | `401 invalid_session` |
| repeated repository-level revoke | no-op, original `revoked_at` kept |

A client should read that `401` as success rather than retrying: the user is
logged out either way. Carving out an exception so a revoked bearer could
still reach the handler would turn logout into a route that accepts dead
credentials — a strictly worse trade for a status code the client does not
need.

**Session rotation is not implemented.** `shouldRotate` exists and is unused.
Rotating inside the session lifecycle means a window where old and new tokens
are both valid, a race when two devices rotate at once, and a client that can
lose the new token mid-swap. None of that is worth solving before there is a
client that needs it, so `/v1/me` returns `session.expiresAt` instead and the
app can prompt a fresh sign-in before the 60 days lapse. Recorded as a
follow-up rather than half-built.

`sessions.last_used_at` is likewise still set only at creation: touching it on
every authenticated request is a write per read, and nothing consumes the
column yet.

### First sync slice — workouts

`POST /v1/sync/workouts` uploads workout sessions and step results;
`GET /v1/sync/workouts?since=<seq>` reads back everything newer than a cursor.

**This is not full multi-device sync.** There is no conflict resolution beyond
last-write-wins per record, and no client pulls from it yet. Calling it
"同期完了" in the UI would be a promise a user only discovers is false when
they lose a phone — the honest description is an *account migration and first
backup slice*.

Scope is deliberately two tables. Routines, gyms, day logs and meals are not
here: a sync design is easier to get right on the smallest genuinely useful
thing, and everything added later hangs off the same `user_id` + `change_seq`
shape.

#### Limits, and where they come from

One upload writes at most **500 records, sessions and step results counted
together**. Not 500 of each: D1 meters every statement in a batch against its
1000-queries-per-invocation limit, so two independent 500s allowed a request
whose batch alone issued 1002 statements — accepted by the API and then
refused by the platform. The worst case at the combined cap is counted rather
than estimated (2 auth + 6 session preflight + 7 tombstone preflight + 502
batch = 517), and a test measures it against both D1 ceilings.

Id lookups are chunked at 90 per query, because D1 allows at most 100 bind
parameters per query and each lookup also binds the user id.

The limit lives in the repository, not only in the route. An internal caller
that wrote an oversized sequence would produce data the pull path cannot
deliver — permanent loss for that user — so the rule sits where every caller
must pass it.

#### Conflict policy, v1: a tombstone is terminal

Once a record is deleted on the server, that id is finished. An upload
composed before the delete still carries the record as live, and a plain
upsert would clear `deleted_at`; because the resurrection gets its own
sequence, every device would then pull the record back. The delete would undo
itself with nothing reporting a problem.

So a live upload targeting a tombstoned id is refused with **409
`record_deleted`**. Re-sending the same delete is fine and idempotent. A
record that genuinely needs to come back gets a new id, which is unambiguous
in a way that reviving one never is.

Client clocks are deliberately not used to decide this. Real conflict
resolution belongs to a later sync layer; guessing at it now with `updatedAt`
would be worse than a rule that is simple and honest.

#### An account that stops being active

Both endpoints refuse a user whose account is `deleting`, and they do not
rely on the session middleware to have caught it: another request can start a
deletion after this one was authenticated. Writes are refused by database
triggers, inside the same transaction as the write, so there is no window
between the check and the commit. Reads join `users` in the query that
produces the data.

#### A sequence larger than the write limit

Cannot be produced through the repository. If one is ever found anyway, the
pull **fails** rather than returning the first page and advancing the cursor
past the rest — that would destroy the remainder permanently while reporting
success. A sync that fails loudly can be retried; data that has been skipped
cannot be recovered.

#### Duplicate ids in one request

Refused with 400. Resolving them by statement order would make the outcome
depend on something neither the client nor a reviewer can predict.

#### Ids come from the client

The app already generates UUIDs offline. Rewriting them on upload would make
the device and the server disagree about what a record is called, which makes
a retry indistinguishable from a new record — so the client's id is the id.

That makes ownership the thing to get right, and it is why the primary key is
**`(user_id, id)`** rather than `id`:

- Two users can hold the same UUID without either overwriting the other. With
  a bare `id` key, a client that replayed someone else's UUID would land on
  their row. A test uploads the same UUID as two users and asserts each sees
  only their own.
- Every query is forced to carry a user. There is no way to write one that
  "forgets" whose data it is reading, because the key does not permit it.

`step_results` references its session through `(user_id, session_id)`, so a
step result cannot point at another user's session — unrepresentable rather
than merely discouraged.

#### The sequence and the rows move together

The failure this design exists to prevent: writing a synced row in one commit
and bumping `user_change_seq` in another. A reader then sees either a
published sequence with no rows behind it, or rows a pull never returns
because the cursor did not advance past them. Both are silent data loss.

So an upload is exactly one `db.batch()`:

1. `UPDATE user_change_seq SET seq = seq + 1`
2. every row inserted with `change_seq = (SELECT seq FROM user_change_seq …)`

Statement 1 runs first inside the transaction, so the subquery reads the new
value. If anything fails, D1 rolls the whole batch back and neither the
sequence nor a single row moved. A test forces a mid-batch constraint failure
and asserts the cursor is unchanged.

An **empty** upload does not advance the sequence at all: handing other
devices a cursor move with nothing behind it would be a pointless round trip
that looks like a change.

#### Pulling in pages

`GET /v1/sync/workouts?since=<seq>` returns at most 500 rows per table and a
`changeSeq` the client may store, plus `hasMore`.

The cursor is the subtle part. An earlier version returned the user's
*current* sequence regardless of how much it had actually sent, so a pull that
hit the row limit told the client "you are up to date at seq N" while
withholding rows below N — the client would store N and never ask for them
again. Permanent, silent data loss.

A truncated page now reports the last sequence it delivered **completely**,
and sets `hasMore`. Rows are read one past the limit to detect truncation, and
any partially-covered sequence is dropped rather than half-sent. Because one
upload writes at most 500 rows per table at a single sequence — the same
number as the page limit — a single sequence always fits, so the cursor always
advances and paging cannot stall.

The two tables paginate independently, so the returned cursor is the lower of
the two. Re-reading a few rows next time is harmless (the client applies them
idempotently); skipping any is not.

A sequence bigger than one page is handled explicitly rather than relied upon
not to happen: it is delivered **whole**, over the limit. Dropping it would
leave the page empty *and* the cursor unmoved — the client would ask the same
question forever — and splitting it would strand the remainder. In practice
one upload writes at most 500 rows per table at a single sequence, the same as
the page limit, so this only opens if the limit is set lower; making it
correct anyway means the two numbers are not a silent coupling someone can
break later. A test walks a whole stack of oversized batches and asserts the
cursor advances on every round.

#### Retries are safe

The guest migration will be retried over flaky networks, so a retry has to
converge rather than accumulate. Uploads upsert on `(user_id, id)`: three
identical uploads leave one row. The sequence *does* advance each time, which
is correct — the rows really were rewritten, and a cursor that skipped them
would be the bug.

Deletes are tombstones (`deleted_at`), not row removals, so another device
learns the record is gone. Hard deletion happens with the account, through the
same cascade as everything else.

### Account deletion

`DELETE /v1/me` destroys the caller's PulseCue account. Two steps, and the
order is the design:

1. The account becomes `deleting` and **every session is revoked**, in one
   commit. From that instant it cannot be signed into or used, whatever
   happens next.
2. Provider revocation is attempted once, synchronously, so the common case
   finishes while the user is still looking at the screen.

`200 {"status":"deleted"}` when it finished. `202 {"status":"pending"}` when
step 2 could not complete — the deletion is real and irreversible, it is just
not done.

**A failed provider revocation never puts the account back.** It stays
`deleting`, its sessions stay revoked, and the work is retried. Returning a
user to `active` because Apple had a bad minute would silently resurrect an
account they asked to destroy. Retrying the HTTP call is safe and in practice
impossible: step 1 revoked the session that authorised the request, so a
second attempt cannot authenticate. A client seeing `401` after a delete
should read it as done.

Apple's refresh token is revoked **before** any row is removed. Removing them
first would destroy the only copy of the token and leave the Apple grant alive
with nothing left to revoke it with.

The hard delete is one `DELETE FROM users`. Every user-owned table cascades,
so the *database* decides what belongs to a user rather than a list in a file
that someone has to remember to update; a schema test asserts each table
declares the cascade, and a deletion test asserts every table is empty
afterwards and that another user is untouched. `auth_nonces` is keyed by a
nonce hash with no owner, so there is deliberately nothing there to sweep.

#### Google accounts

PulseCue holds no Google refresh token — the ID token flow never issues one —
so there is nothing to revoke, and no revocation call is invented for a
credential that does not exist. **Deleting a PulseCue account is not deleting
a Google account**; the two are separate, and only the identity row goes away
here.

#### Retry state

`account_deletions` (migration `0004`) holds `attempts`, `last_attempt_at`, a
`last_error_code` from a closed set in code, and `next_attempt_at` with a
15-minute backoff. Never a provider message and never PII: the row describes a
job, not a person.

It carries no completion column. A finished deletion removes the user and the
cascade removes this row with it, so "still here" means "still owed" and the
two cannot disagree.

`processDueAccountDeletions` is the boundary a scheduled invocation would
call. **Nothing invokes it yet** — creating a Cron trigger is a production
resource change and is not part of this work — but it exists and is tested, so
wiring it up later is configuration rather than design.

#### When a credential cannot be decrypted

A lost key, a wrong key version, a corrupt row or an AAD mismatch means the
stored ciphertext cannot be opened.

An earlier version of this PR **deleted the account anyway**, reasoning that
an unreadable ciphertext is not a usable credential. That reasoning is about
*our* copy, and it answers the wrong question: the grant at Apple is
unaffected by whether we can read our copy of it. Hard-deleting would destroy
the only record that the grant exists while reporting the deletion as
complete — and Apple's requirement is that the token is **revoked**, which we
would have neither done nor be able to do.

So the deletion stays owed:

- the account remains `deleting`
- its sessions remain revoked, and sign-in remains impossible
- the credential material is **kept**, because it is the only thing that could
  ever be recovered if the key is restored
- `last_error_code` is `credential_unreadable`, and a fixed non-PII code is
  logged for an operator

A test proves the pending state is recoverable rather than a dead end: once
the correct key is available again, the same deletion completes and Apple is
contacted exactly once.

#### "Nothing to revoke" is a narrow claim

A credential lookup returns one of four states, and keeping them apart is
load-bearing:

| State | Meaning | Deletion |
|---|---|---|
| `absent` | no row — a Google identity, or an Apple one from before the exchange | may finish |
| `alreadyRevoked` | row blanked after a confirmed 2xx | may finish |
| `readable` | usable token | revoke, then finish |
| `unreadable` | row present, **unrevoked**, material unusable | **stays pending** |

The lookup used to return `string | null` and collapsed three of those into
`null`. An unrevoked row with an empty ciphertext therefore looked exactly
like "this account never had a credential", so deletion hard-deleted the user
while a live Apple grant stayed alive — and, with the row gone, untraceable.

`unreadable` covers an empty ciphertext, an empty or malformed IV, a corrupt
ciphertext, an unknown key version, a wrong key, and an AAD mismatch. All of
them mean the same thing: the grant may still be live and we cannot produce
the token to revoke it with. Empty material on an *already revoked* row is the
expected end state and still completes.

#### Failing before or after the durable transition

`DELETE /v1/me` is two phases, and which one failed decides what the client is
told:

**Phase 1 — the durable transition.** One batch: the account becomes
`deleting` and every session is revoked. Until it commits, nothing has been
accepted; a failure rolls the batch back and the account is still `active`. A
service failure here is reported as one, and the caller's session still works
so they can retry.

**Phase 2 — processing.** Credential lookup, revocation, the hard-delete
decision. By now the deletion *is* durably accepted, so an unexpected failure
is answered `202`, not `500`. Returning an error would tell the user their
deletion failed while their account is already `deleting` and every session is
dead — the response contradicting the state is the bug.

The boundary is an explicit `transitionCommitted` flag rather than something
implied by control flow, so a Phase 1 failure can never be laundered into a
`202`. Unexpected Phase 2 failures log the fixed code
`account_deletion_processing_failed` with a correlation id and nothing else —
no user id, subject, email, credential material, or underlying error, since
repository errors quote the values they failed on.

The `202` body says `"Your account deletion is in progress"`, worded so no
substring of it can be misread as a completion claim.

#### What may finish a deletion

Hard delete happens under exactly two conditions:

- every Apple credential was revoked with a **confirmed HTTP 2xx**, or
- there was no provider credential to revoke at all

Google reaches the second case by construction — the ID token flow never
issues a refresh token, so no revocation is invented for it.

Everything else keeps the deletion pending, with the reason recorded
distinctly: `provider_unavailable` (network or 5xx), `provider_rejected` (a
4xx, which is not evidence of revocation either), or `credential_unreadable`.

### Sign in with Apple

`POST /v1/auth/apple` takes
`{ identityToken, authorizationCode, rawNonce, deviceName? }` and returns
`{ sessionToken, expiresAt, user }`.

The iOS app is not trusted with identity. Everything that decides *who* the
user is comes out of Apple's signature — `credential.user` from the client
is deliberately ignored, and only the `sub` claim is stored. Verified on
every request: RS256 signature against Apple's published key, issuer,
audience (`APPLE_AUDIENCE`), `exp` and `iat` with a 60s skew allowance, and
that `sha256(rawNonce)` equals the token's `nonce` claim.

The nonce is then **spent**: `auth_nonces` records it, so replaying a
captured request body fails even though the token is still inside its
validity window.

Every credential failure answers `401 invalid_credentials` with identical
wording. Which check failed is a short code in the log with a correlation
id — never in the response, because distinguishing "no such account" from
"bad token" is an enumeration oracle. Apple's key service being unreachable
is a `503`, not a rejection.

**No Apple secret is required *to verify a token*.** Verification needs only
Apple's public keys, and `APPLE_AUDIENCE` is the app's bundle identifier —
environment-specific but not secret. Everything past verification does need
one; see below.

#### The authorization code, and why it is required

`authorizationCode` is **not optional**. Apple requires an app offering Sign
in with Apple to let users delete their account *and* revoke the token, and
revocation needs a refresh token. The only way to get one is to trade the
authorization code — which Apple hands over once per sign-in, is single-use,
and cannot be re-requested later. A sign-in accepted without it would create
an account that can never be deleted the way Apple requires, with no way to
repair it afterwards.

So the code is exchanged during sign-in, in this order:

1. Verify the identity token (signature, issuer, audience, window, nonce).
2. Spend the nonce.
3. **Resolve the account.** Deliberately before the exchange: every database
   operation moved above it is one that can no longer fail while an un-stored
   Apple refresh token exists, and a `deleting` account is turned away before
   Apple ever mints a credential for it.
4. Exchange the code at `https://appleid.apple.com/auth/token`, using a
   freshly signed ES256 client secret.
5. Validate Apple's response, including its `id_token` — see below.
6. **In one batch:** store the encrypted refresh token *and* create the
   session.

#### The `id_token` in the exchange response is required

Not "verified if present". Treating it as optional means an attacker who can
suppress it — or a response shape nobody expected — skips the only check that
proves the authorization code belonged to the same person as the identity
token that arrived with it.

It is fully verified (signature against Apple's JWKS, issuer, audience,
window, non-empty `sub`) and its subject must be **strictly equal** to the one
the identity token already proved. A mismatch writes nothing, stores no
credential and issues no session.

The nonce check is deliberately *not* applied here. Apple does not put one on
the exchange response — that request is authenticated by the client secret —
so `verifyAppleIdentityClaims` (common claims) is separated from
`verifyAppleIdentityToken` (claims **plus** nonce binding). The omission is
explicit at the call site rather than hidden inside a verifier that quietly
stopped checking.

`access_token` is ignored and never stored: nothing calls an Apple API on the
user's behalf, so keeping one would be holding a credential for no reason.

#### Step 6 is atomic, and the trigger is why

A credential stored with no session is an account holding an Apple grant that
nobody is signed into and nothing reported a failure for.

The guard used to live in the INSERT — `INSERT … SELECT … WHERE EXISTS (…
active …)` — which is correct about *what* it writes and dangerously wrong
about how it fails. **Inserting zero rows is a successful statement.** D1 only
rolls a batch back when a statement errors, so against a `deleting` user the
batch committed the credential and silently issued no session.

Migration `0003` adds a `BEFORE INSERT` trigger on `sessions` that aborts when
the user is not `active`, and the session INSERT is now unconditional. The
refusal is a real statement failure, so the whole batch — credential included
— rolls back. The trigger is scoped to session *creation* on purpose: a
`deleting` account must still be able to hold its encrypted credential,
because that is what deletion revokes with.

#### A refresh token is never left orphaned

Between the exchange and the commit there is a live Apple refresh token that
only that request knows about. If persistence fails there, the token would
stay valid at Apple with nothing on our side pointing at it — unrevokable at
deletion, and invisible.

So a persistence failure triggers a **best-effort compensating revoke** and
the request fails with `503`. No session is issued whether or not the
compensation succeeded, and a failed compensation is never recorded as a
revocation.

What it deliberately does *not* do is write the token somewhere for a later
retry. The failure being handled is the database, so "store it and try again"
would mean storing it in the thing that just failed — and persisting a
plaintext credential to recover from a storage failure is worse than the
problem.

Because the code is single-use, a failed sign-in is **not** retryable with the
same request body. Recovery is a fresh Apple authorization flow, which is
safe: the same `sub` resolves to the same PulseCue user, and the new refresh
token replaces the old one.

#### The client secret

Apple's token endpoints take a short-lived ES256 JWT signed with the `.p8`
key, not a static shared secret. PulseCue mints one per request with a **5
minute** lifetime rather than caching one for the six months Apple permits: a
secret that lives for minutes cannot be replayed for half a year if it ever
reaches a log.

Four settings are required *together* — `APPLE_CLIENT_ID`, `APPLE_TEAM_ID`,
`APPLE_KEY_ID`, `APPLE_PRIVATE_KEY`. With none set, Apple sign-in answers
`503` before spending the nonce or touching the account; with only some set,
the request fails loudly rather than pretending to be unconfigured.
`APPLE_PRIVATE_KEY` is a **Worker secret** and never appears in this
repository — the tests generate their own throwaway P-256 keypair and drive
the production signing path with it.

#### Encrypted credential storage

The refresh token is stored AES-256-GCM encrypted in `provider_credentials`,
under the Worker secret `APPLE_TOKEN_ENCRYPTION_KEY` (base64 of 32 bytes).

- A fresh 96-bit IV per write, stored beside the ciphertext. Re-signing in
  re-encrypts with a new IV — reuse under one key is how GCM stops protecting
  anything.
- The GCM additional data binds the ciphertext to its `auth_identity_id`,
  provider, purpose and key version. A row copied onto another identity fails
  to decrypt instead of revoking the wrong person's Apple account — something
  encryption alone would not catch, since the attacker never needs to read the
  token to misuse it.
- `encryption_key_version` is stored per row and a decrypt-only predecessor
  key can be configured, so a key rotation is a config change plus a
  re-encrypt pass rather than a migration.

- `provider` is re-asserted on the upsert's conflict path and the row carries a
  composite foreign key to `auth_identities (id, provider)`. A credential
  claiming a provider its identity does not have is therefore unrepresentable
  — which matters because the provider name is part of the AAD, so a mismatched
  row would be one nobody could ever decrypt.

#### Revocation succeeds on HTTP 2xx, and nothing else

`auth/appleRevocation.ts` is the service the deletion route will call. Its
outcomes are a closed set — `revoked`, `nothingToRevoke`, `retryable`,
`unrevocable` — and only `revoked` means the token is gone.

**No error body is ever read as evidence of success.** An earlier version
took `invalid_grant` out of a 400 and called it "already revoked". That
inference is wrong: from this endpoint `invalid_grant` can equally mean the
token was issued to a different client, or that the request was malformed.
Apple answers 2xx when it *accepts* a revoke — including for a token it has
already forgotten — so there is no case where a non-2xx must be read as
success, and every case where doing so records a revocation that never
happened.

Concretely: 2xx → `revoked` and the material is erased. 5xx or a network
failure → `retryable`, whatever the body says. 4xx → `retryable` with reason
`providerRejected`, because a rejection is not evidence of revocation either.
**The stored credential is only ever erased after a 2xx**, so a retry always
still has something to retry with.

`unrevocable` (a ciphertext that cannot be opened) likewise does not mean the
token was revoked — it means we can no longer produce the credential needed to
try.

See [Apple production gates](#apple-production-gates) for what is still open.

### Sign in with Google

`POST /v1/auth/google` takes `{ idToken, deviceName? }` and returns the same
`{ sessionToken, expiresAt, user }` shape.

The same rule applies: `GIDGoogleUser` hands the app a `userID`, an email and
a profile name, and **none of them are part of the request schema**. The
account is keyed on the `sub` of a signature-verified token. Verified on every
request: RS256 signature against Google's published key, issuer (allowlisted
to Google's two documented spellings), audience (`GOOGLE_AUDIENCE`), `exp` and
`iat` with a 60s skew allowance, and a non-empty `sub`.

The audience check is the load-bearing one here. An ID token is issued *to a
client*, and without pinning `aud` to our own client id, a token minted for
any other Google app — including one an attacker registered five minutes ago
— would sign its holder in. Unset config is a refusal, never "any audience".

`aud` must be **exactly one string** equal to `GOOGLE_AUDIENCE`. An array is
rejected. The JWT spec permits an array and Google's tokens for this flow do
not use one; accepting it would mean accepting a token *also* minted for
someone else, while the `azp` claim that exists to disambiguate that case is
not checked here. PulseCue has exactly one server client id, so the narrow
contract costs nothing.

**No Google secret is involved.** Verifying an ID token needs only Google's
public keys — this backend never calls a Google token endpoint and holds no
client secret. `GOOGLE_AUDIENCE` is a client id, which is public.

#### Which client id goes where

Google Cloud issues **two** OAuth client ids for this setup, and swapping them
is the mistake to avoid. The ID token's `aud` is the **Web application
("server") client id**, *not* the iOS one:

| Google Cloud client | Used as | Appears in `aud`? |
|---|---|---|
| **iOS** OAuth client id | `GIDClientID` in the app, and the reversed-client-id URL scheme | **No** |
| **Web application** OAuth client id | `GIDServerClientID` in the app, and `GOOGLE_AUDIENCE` here | **Yes** |

The flow: the app sets `GIDServerClientID` to the Web client id, so Google
mints the ID token with `aud` = that Web client id. The backend compares `aud`
against `GOOGLE_AUDIENCE`, which must hold the *same* value. The iOS client id
never reaches the server at all.

Setting `GOOGLE_AUDIENCE` to the iOS client id would reject every real token —
a fail-closed mistake rather than a dangerous one, but a confusing outage.

Two things are **not** done yet and are needed before Google sign-in works end
to end:

1. The Web application OAuth client has not been created in Google Cloud, and
   no real client id appears anywhere in this repo — `.dev.vars.example` has a
   placeholder only.
2. The iOS app does not set `GIDServerClientID` yet. That is a follow-up iOS
   PR; this one is server-only. Until it lands, tokens from the app carry the
   iOS client id in `aud` and this endpoint will (correctly) refuse them.

The existing reversed-client-id URL scheme stays as it is — it belongs to the
iOS client id and is unaffected by any of this.

**No nonce, deliberately.** Apple's nonce exists because
`ASAuthorizationAppleIDRequest` lets the app bind a value it generated into
the token, and spending it once turns a captured request body into a
single-use one. Nothing equivalent reaches this endpoint today: the request
carries only `{ idToken, deviceName? }`, and supplying a bound nonce would
require an iOS change that is out of scope for this server-only work. The
residual risk is small: replaying a captured body requires reading the body, and
anyone who can read a TLS request body can equally read the session token in
the response. If that call changes, the cheapest version needs no client
change — record `sha256(idToken)` in `auth_nonces` (it already has a `google`
provider value) to make each ID token usable once. That is an open decision,
not an oversight.

### Provider key sets

Each provider's JWKS endpoint is a module constant inside that provider's
file, reachable only through `createAppleJwksProvider()` /
`createGoogleJwksProvider()`. No URL is ever passed in from a request, and
`RemoteJwksProvider` refuses a non-HTTPS URL at construction — a tripwire so
that a later refactor cannot quietly turn key fetching into SSRF.

A fetched key set is untrusted input and is validated before use:

- `keys` must be an array of objects, each with a non-empty string `kid`
- a **duplicate `kid` rejects the whole set** — "which key signed this" must
  not be a guess
- a key is only usable with `kty: RSA` and non-empty `n`/`e`; `use` and `alg`
  are optional in RFC 7517, so an omitted one is accepted while a *stated*
  `enc` or `RS512` is not
- a set with no usable key fails closed

Anything structurally wrong is a `JwksFetchError` → **503**, never a 401: a
provider outage is not a bad credential.

Key sets are cached in-memory per isolate (6h TTL) and refetched on an unknown
`kid`, so rotation is not an outage. Two limits keep that from being free
outbound bandwidth for anyone who can put a random `kid` in a token header:

- **cooldown** — at most one unknown-`kid` refetch per 60s per isolate; a
  flood of bogus `kid`s costs one fetch, not one per request
- **single-flight** — concurrent misses share one in-flight fetch rather than
  opening a connection each

`invalidate()` clears both, so an operator can still force a rotation
immediately. No KV binding is needed to be correct.

### Apple production gates

The token lifecycle is now **built**; what remains is external setup and
scheduling. Nothing here is optional for public availability.

1. ~~Authorization code exchange, encrypted refresh token storage, client
   secret, revocation service.~~ **Done.** The code path exists and is tested
   end to end against a fake Apple endpoint with a throwaway keypair. What it
   still needs is **real credentials**, which is an external setup step:

   ```sh
   # Apple Developer portal: create a Sign in with Apple key, download the .p8.
   npx wrangler secret put APPLE_PRIVATE_KEY --config wrangler.api.jsonc
   npx wrangler secret put APPLE_TOKEN_ENCRYPTION_KEY --config wrangler.api.jsonc
   # APPLE_CLIENT_ID / APPLE_TEAM_ID / APPLE_KEY_ID are vars, not secrets.
   ```

   Generate the encryption key with 32 random bytes, base64:
   `openssl rand -base64 32`. Until all of it is set, Apple sign-in answers
   `503` rather than creating an undeletable account.

   An earlier note here described the `.p8` as something to "pick up later, at
   deletion". That was wrong, and is corrected: deletion-with-revocation is a
   condition of offering Apple sign-in at all.

2. **`DELETE /v1/me`, wired to the revocation service.** The service exists;
   nothing calls it yet.

3. **Nonce cleanup, actually running.** `purgeReplayableNonces` now exists and
   applies the correct boundary, but nothing invokes it in production, so
   `auth_nonces` still grows without bound.

   The boundary is the subtle part and is now enforced in code and covered by
   tests: the sweep deletes at `expires_at + APPLE_CLOCK_SKEW_SECONDS`, not at
   `expires_at`. Sweeping at `expires_at` would open a 60-second window in
   which a token is still accepted but its nonce row is gone — a replay hole
   manufactured by the cleanup itself. `purgeExpiredNonces` takes a raw cutoff
   and does no such reasoning, which is why a scheduler must call
   `purgeReplayableNonces` instead.

### Not deployed

`database_id` in `wrangler.api.jsonc` is a placeholder. Provisioning and
deployment are deliberately **not** part of this PR:

Every command must name `wrangler.api.jsonc`. Without `--config`, wrangler
picks up `wrangler.jsonc` and would target the **gym-machine** Worker
instead:

```sh
# 1. Provision the database (not done yet — needs approval).
npx wrangler d1 create pulsecue-api --config wrangler.api.jsonc

# 2. Paste the printed database_id into wrangler.api.jsonc.

# 3. Apply migrations to the LOCAL database only.
npx wrangler d1 migrations apply pulsecue-api --local --config wrangler.api.jsonc
# applies 0001_user_auth_foundation.sql and 0002_auth_nonces.sql

# 4. Run locally.
npx wrangler dev --config wrangler.api.jsonc
```

Remote migration (`--remote`) and `wrangler deploy` are **not** part of this
work and are not run from here. They change live account data, so they stay
an explicit, separately approved step.

### Schema notes

- Timestamps are unix epoch seconds (INTEGER, UTC). D1 has no date type,
  and integers compare without format or locale risk.
- **No provider tokens are stored.** A test asserts the DDL contains no
  `access_token` / `refresh_token` / `id_token` / `authorization_code`
  column.
- Sessions store **only the SHA-256** of the opaque token, so a database
  disclosure yields no usable session. Sessions are stored (rather than
  self-contained) precisely so unlink and account deletion can revoke
  access immediately.
- Identities are keyed by `(provider, subject)` from a *server-verified*
  token and are **never merged by email** — Apple's private relay makes an
  address an unsafe join key, and trusting one would allow account
  takeover.
- `user_change_seq` is a per-user monotonic counter, the pull cursor for
  the first sync slice. A counter rather than a timestamp because clocks
  skew and two writes in one second still need an order.

- `users.state` and `users.deleted_at` are held consistent by a CHECK. An
  active user with a deletion timestamp, or a deleting user without one,
  would make "is this account usable" depend on which column was read.
- A `deleting` account fails closed everywhere: no session is issued, and
  `findActiveSessionByToken` joins `users` so an existing token stops
  authenticating on the very next request even if a revocation were missed.

### Tests

The repository tests run the **real migration** against an in-memory
SQLite (`node:sqlite`), so the actual SQL, UNIQUE constraints, CHECKs and
foreign keys are exercised — not a hand-written fake. The double's
`batch()` uses a real transaction with rollback, matching D1, so a
non-atomic implementation cannot pass.

`node:sqlite` ships unflagged from Node 23.4 / 24; `vitest.config.ts`
probes for it and adds `--experimental-sqlite` only when the running Node
needs it. **Node 24 is the supported runtime** — pinned in `.nvmrc`, declared as
`engines: { node: ">=24 <25" }`, and used by
`.github/workflows/server-ci.yml`, which runs the same commands on push.
Older versions may still work locally (the probe adds the flag), but only
24 is verified in CI.

```sh
npm run typecheck        # production sources
npm run typecheck:test   # sources + tests
npm test
npm run check            # all three
```
