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
  -d '{
    "gymName": "Example Gym Shibuya",
    "officialUrl": "https://example.com/gyms/shibuya"
  }'
```

Error responses use a uniform envelope:

```json
{ "error": { "code": "invalid_body", "message": "officialUrl: required" } }
```

Possible `code` values: `invalid_body`, `missing`, `malformed`,
`unsupported_scheme`, `private_host`, `fetch_failed`, `not_found`,
`internal_error`.

## Setup

```bash
cd server
npm install
```

`node_modules`, `.wrangler/`, `.env*`, and `.dev.vars*` are git-ignored.
**Do not commit `node_modules`.**

## Local development

```bash
npm run dev       # wrangler dev — http://localhost:8787
npm run test      # vitest run
npm run typecheck # tsc --noEmit
```

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
  parser/
    url.ts                       URL validation (http/https only)
    extractText.ts               HTML → readable text
    machines.ts                  Canonical machine catalog + aliases
    matchMachines.ts             Alias matcher with dedupe + scoring
tests/                           Vitest suites for the parser layer
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
- **Authentication is not yet enforced.** Before exposing this API
  publicly, gate `/api/gym-machines/import` behind an API key (header
  check or Cloudflare Access).
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
