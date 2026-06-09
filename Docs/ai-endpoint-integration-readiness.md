# AI Endpoint Integration Readiness and Local QA Guide

> Purpose: document the readiness checks and local QA path before connecting
> `AITrainingPlanEndpointClient` to any developer endpoint in the app.
> This guide is documentation only. It does not authorize production endpoint
> wiring, real AI integration, provider SDKs, credential storage, or default
> provider changes.

Related docs:

- [`ai-training-plan-provider-architecture.md`](ai-training-plan-provider-architecture.md)
- [`ai-training-plan-proxy-endpoint-spec.md`](ai-training-plan-proxy-endpoint-spec.md)
- [`ai-endpoint-debug-qa-results.md`](ai-endpoint-debug-qa-results.md)
- [`ai-privacy-and-safety.md`](ai-privacy-and-safety.md)
- [`credential-strategy.md`](credential-strategy.md)
- [`import-token-endpoint-spec.md`](import-token-endpoint-spec.md)
- [`ai-endpoint-auth-token-strategy.md`](ai-endpoint-auth-token-strategy.md)

---

## 1. Current State

- The default app behavior remains local mock generation.
- `MockAITrainingPlanChatView()` resolves through
  `AITrainingPlanProviderFactory.makeProvider()` with no arguments, which
  returns `MockAITrainingPlanProvider`.
- `AITrainingPlanEndpointClient` exists and conforms to
  `AITrainingPlanProviding`, but it is not the default provider.
- Endpoint mode requires an explicit `AITrainingPlanEndpointConfiguration`
  with a caller-supplied `baseURL`.
- `MockAITrainingPlanChatView(endpointConfiguration:)` exists only behind
  `#if DEBUG`; release/default UI still uses the no-argument mock path.
- A DEBUG-only QA harness now wires this up: an "AI endpoint QA" card in
  `SettingsView` (compiled only under `#if DEBUG`) opens the chat view with
  `AITrainingPlanEndpointConfiguration.debugLocalMock`, a loopback-only
  (`http://127.0.0.1:8787/`) configuration with no token. The card and the
  loopback URL are absent from release builds. On this path the screen shows
  accurate "local mock endpoint" copy instead of the mock notice; the default
  Settings entry remains the no-argument mock path.
- No production URL, Worker URL, provider key, or token is bundled by the QA
  harness; the loopback configuration carries `tokenProvider == nil`.
- The server-side training-plan route currently available for local QA is a
  deterministic mock endpoint. It saves nothing, performs no real AI call, and
  requires no provider credential.
- `AIPlanGenerationPhase` and `AIPlanGenerationError` drive loading, cancel,
  retry, and safe error copy in the chat view.
- `AITrainingPlanNormalizer` remains the final client-side gate before any
  raw endpoint response becomes a `WeeklyTrainingPlanCandidate`.
- `Routine` and `Step` records are created only after the user explicitly taps
  the save action.

---

## 2. Local QA Prerequisites

Before using any dev endpoint path, confirm all of the following:

- Local `main` is synced and clean.
- PR #83 or later is present on `main`.
- The endpoint under test is the local deterministic mock route only.
- No production deployment URL is present in iOS source, docs, project files,
  plist files, configuration files, or test fixtures.
- No provider credential or long-lived secret is present anywhere in the iOS
  app.
- No real AI provider call is enabled.
- No provider SDK has been added to the app.
- No token is persisted in `Info.plist`, `UserDefaults`, Keychain, source,
  build settings, or environment configuration.
- The app still opens `MockAITrainingPlanChatView()` from Settings with no
  endpoint configuration.
- The endpoint client is reachable only through explicit injected config in a
  developer-only path or test.

---

## 3. Safe Local Test Path

Use this path only for developer verification. It must not become production
behavior.

1. Start from clean, synced `main`.
2. Start the local mock server route using the repository's normal server
   development workflow.
3. Create an `AITrainingPlanEndpointConfiguration` only in a DEBUG-only test,
   preview, or temporary local QA harness.
4. Supply the local server `baseURL` explicitly at the call site.
5. Leave `tokenProvider` as `nil` unless the local mock under test explicitly
   requires a fake short-lived token.
6. If a fake token is needed, inject it through `tokenProvider`; do not store
   it in plist, defaults, Keychain, source constants, or environment-backed
   app configuration.
7. Generate a plan and confirm the endpoint returns the deterministic mock
   response shape.
8. Confirm the response still passes through `AITrainingPlanNormalizer`.
9. Confirm warnings and unknown machine ids are handled by the normalizer.
10. Confirm loading, cancel, failure, and retry affordances behave as expected.
11. Confirm no `Routine` or `Step` exists after open, input, generation,
    cancellation, failure, or candidate display.
12. Confirm `Routine` and `Step` records appear only after the explicit save
    button is tapped.
13. Remove any temporary local QA harness before opening a production-facing
    PR, unless that harness is intentionally DEBUG-only and reviewed as such.

---

## 4. Red Flags

Do not proceed with endpoint integration if any of these appear:

- A hardcoded production endpoint URL in iOS source, docs, tests, plist,
  configuration, or project files.
- A public Worker deployment URL in iOS source, docs, tests, plist,
  configuration, or project files.
- Any provider credential or long-lived service secret in the iOS app.
- Any token stored in `Info.plist`, `UserDefaults`, Keychain, source,
  build settings, or environment-backed app configuration.
- `AITrainingPlanProviderFactory.makeProvider()` defaults to endpoint mode.
- `SettingsView` opens the chat view with endpoint configuration.
- The endpoint path compiles into release UI without a separate approved
  production design.
- Real AI calls or provider SDK dependencies are added before auth/token
  strategy is complete.
- Raw provider errors, raw response bodies, or `userMessage` are displayed or
  logged.
- Generation, display, cancellation, or retry creates `Routine` or `Step`
  records before explicit save confirmation.
- SwiftData schema or `@Model` types change as part of endpoint QA wiring.

---

## 5. Manual QA Checklist

### Default Mock Path

- [ ] Settings opens `MockAITrainingPlanChatView()` with no endpoint config.
- [ ] Header/copy still indicates local mock behavior.
- [ ] Tapping generate with default UI produces a candidate without network
      dependency.
- [ ] Duplicate generation is disabled while the phase is generating.
- [ ] Loading copy and spinner appear during generation.
- [ ] Cancel action appears only during generation.
- [ ] Cancel returns to a non-error cancelled state.
- [ ] Failure copy, if forced by a stubbed provider, uses safe Japanese text.
- [ ] Retry appears only after failure and requires explicit tap.
- [ ] Retry/regenerate uses the current input values.
- [ ] Success still displays the candidate summary, warnings, sessions, and
      save section.

### Explicit Dev Endpoint Path

- [ ] Endpoint-backed view can be created only through explicit
      `AITrainingPlanEndpointConfiguration`.
- [ ] The endpoint initializer is DEBUG-only.
- [ ] The supplied `baseURL` is local and injected at the call site.
- [ ] No endpoint URL is bundled in production code or project settings.
- [ ] `tokenProvider` is `nil`, or a fake/local token is injected only for the
      test run.
- [ ] Endpoint response is deterministic and mock-only.
- [ ] Endpoint errors map into `AIPlanGenerationError` categories.
- [ ] UI never shows raw endpoint error details or raw response bodies.
- [ ] UI never logs `userMessage`.

### Candidate and Save Boundary

- [ ] Opening the screen creates no `Routine` or `Step`.
- [ ] Typing input creates no `Routine` or `Step`.
- [ ] Generating a candidate creates no `Routine` or `Step`.
- [ ] Displaying a candidate creates no `Routine` or `Step`.
- [ ] Cancelling generation creates no `Routine` or `Step`.
- [ ] Failed generation creates no `Routine` or `Step`.
- [ ] Tapping retry creates no `Routine` or `Step` until success plus explicit
      save.
- [ ] Tapping the explicit save button creates the expected `Routine` and
      `Step` records through the existing save path.

---

## 6. Next Implementation Sequence

Use this order for future PRs:

1. ~~Add a DEBUG-only endpoint wiring test, preview, or local QA harness that
   injects `AITrainingPlanEndpointConfiguration` explicitly.~~ **Done:** the
   `#if DEBUG` "AI endpoint QA" Settings card opens the chat view with
   `AITrainingPlanEndpointConfiguration.debugLocalMock` (loopback, no token).
2. QA endpoint success, timeout, unauthorized, rate-limit, unavailable, and
   invalid-response mappings through `AIPlanGenerationError`.
3. ~~Define a typed short-lived token strategy for the training-plan scope.~~
   **Documented:** see
   [`ai-endpoint-auth-token-strategy.md`](ai-endpoint-auth-token-strategy.md)
   (docs-only; auth/token implementation is still future work).
   ~~Define the server-side auth contract for `POST /api/ai/training-plan`.~~
   **Documented:** see
   [`ai-training-plan-proxy-endpoint-spec.md`](ai-training-plan-proxy-endpoint-spec.md)
   §4.1–§4.9 (required header, token/scope requirements, error envelope with
   `requestId`, status/code table, safety + logging rules, and a test matrix).
4. Implement token acquisition and refresh only after the auth/token design is
   approved.
5. Add real provider adapter code only on the server side after auth/token is
   ready.
6. Add any production provider-selection UI only after privacy, auth, cost,
   and opt-in behavior are approved.
7. Keep mock/local generation as the default fallback throughout.

---

## 7. PR Acceptance Criteria for Endpoint Wiring

Any future endpoint-wiring PR should be blocked unless all of these remain
true:

- Default app behavior is still mock/local.
- Endpoint mode is explicit and not bundled as the default.
- Production URL and provider credentials are absent.
- Token handling is injected, typed, short-lived, and not persisted by the
  endpoint client.
- The normalizer is still the final gate.
- No `Routine` or `Step` is created before explicit user save.
- Error presentation uses safe categories and safe copy.
- No raw provider details or user prompt text are logged.
- SwiftData schema and `@Model` types are unchanged unless a separate schema
  PR explicitly owns that change.
