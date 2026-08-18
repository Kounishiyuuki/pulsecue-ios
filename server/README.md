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

Routes: `GET /health`, `POST /v1/auth/apple`, `POST /v1/auth/google`.

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
