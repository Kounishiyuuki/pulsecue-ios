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

**Requires authentication.** Send the import API key as a bearer
token:

```
Authorization: Bearer <PULSECUE_IMPORT_API_KEY>
```

Missing, malformed, or incorrect keys return `HTTP 401`:

```json
{ "error": { "code": "unauthorized", "message": "A valid API key is required" } }
```

`GET /health` stays public — no key required.

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

# mint a short-lived token
curl -X POST http://localhost:8787/api/auth/import-token \
  -H 'Content-Type: application/json' \
  -d '{
    "deviceId":"9F3C2F8E-1E1B-4C2D-9B8C-1F0E2D3A4B5C",
    "appVersion":"1.0.0 (1)",
    "attestation":"dev-placeholder-assertion"
  }'
```

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
- **API key required for imports.** `POST /api/gym-machines/import` is
  gated by an `Authorization: Bearer` check against the
  `PULSECUE_IMPORT_API_KEY` secret. The check is constant-time and
  fails closed when the secret is unset. `GET /health` stays public.
  Set the production key with `wrangler secret put` — never commit it.
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
