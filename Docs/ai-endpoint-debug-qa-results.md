# DEBUG AI Endpoint QA Results

> Purpose: record the local QA result for the DEBUG-only AI training plan
> endpoint harness after PR #85 and PR #86. This document is a QA record only.
> It does not approve production endpoint wiring, real AI integration,
> provider SDKs, credential storage, or default provider changes.

Related docs:

- [`ai-endpoint-integration-readiness.md`](ai-endpoint-integration-readiness.md)
- [`ai-training-plan-provider-architecture.md`](ai-training-plan-provider-architecture.md)
- [`ai-training-plan-proxy-endpoint-spec.md`](ai-training-plan-proxy-endpoint-spec.md)

---

## 1. Verified State

- Local `main` was clean and synced before QA.
- PR #85 was merged before the DEBUG endpoint QA pass.
- PR #86 was merged after the QA pass to remove DEBUG QA copy and loopback
  strings from the Release binary.
- Default app behavior remains offline mock generation.
- The normal Settings entry for `AIプラン相談` still opens
  `MockAITrainingPlanChatView()` with no endpoint configuration.
- The DEBUG endpoint QA path exists only for local verification.
- The DEBUG endpoint QA path uses the loopback-only
  `http://127.0.0.1:8787/` configuration under `#if DEBUG`.
- The endpoint QA configuration has no token provider by default.
- The Release build excludes the QA card, endpoint QA configuration branch,
  loopback URL, and DEBUG QA copy strings.
- No production endpoint is bundled.

---

## 2. Server QA Result

- Server tests passed.
- Server typecheck passed.
- Local `wrangler dev` served the health endpoint.
- `POST /api/ai/training-plan` returned JSON matching the expected
  `AITrainingPlanResponse`-like shape.
- The local response was deterministic.
- Unknown machine ids were dropped and surfaced through warnings.
- Malformed JSON returned `invalid_request`.
- An empty machine list returned warnings and did not fabricate machine ids.
- No provider key was required.
- No real AI provider call was made.

---

## 3. iOS QA Result

- iOS Debug build passed.
- iOS Release build passed.
- Full iOS test suite passed.
- The DEBUG-only AI endpoint QA card was visible only in Debug.
- The QA card opened `MockAITrainingPlanChatView(endpointConfiguration:)`
  with the local mock endpoint configuration.
- Loading, cancel, retry, failure, and success states remained phase-driven.
- Save boundary held: generation, display, cancel, and failure created no
  `Routine` or `Step`.
- Saving required an explicit user action.
- The default `AIプラン相談` path continued to use the offline mock provider.

---

## 4. Release Exclusion Result

After PR #86:

- The Release build did not include the AI endpoint QA card.
- The Release build did not include endpoint QA configuration UI.
- The Release binary did not contain `AI endpoint QA`.
- The Release binary did not contain `DEBUG QA`.
- The Release binary did not contain the local loopback URL.
- The Release binary did not contain the endpoint-specific local QA copy.

The Debug build still retained the QA card, loopback URL, and endpoint QA copy
for local-only verification.

---

## 5. Manual QA Checklist

Use this checklist for any repeat of the local DEBUG endpoint QA harness:

- [ ] Start the local mock server.
- [ ] Confirm the local health endpoint responds.
- [ ] Confirm `POST /api/ai/training-plan` returns deterministic mock JSON.
- [ ] Launch the iOS app from a Debug build.
- [ ] Open Settings.
- [ ] Open the AI endpoint QA card.
- [ ] Enter a training-plan request.
- [ ] Tap `プラン候補を作成`.
- [ ] Confirm the loading state appears.
- [ ] Confirm cancel is available during generation.
- [ ] Confirm cancellation creates no `Routine` or `Step`.
- [ ] Generate again and confirm a candidate appears.
- [ ] Confirm candidate display creates no `Routine` or `Step`.
- [ ] Tap save.
- [ ] Confirm `Routine` and `Step` records are created only after explicit
      save.
- [ ] Return to Settings and open the default `AIプラン相談`.
- [ ] Confirm the default path still uses offline mock copy and behavior.
- [ ] Build Release and confirm the QA card is absent.
- [ ] Scan the Release binary and confirm the QA title, DEBUG QA copy, and
      loopback URL are absent.

---

## 6. Remaining Constraints

- Real AI remains out of scope.
- Production endpoint wiring remains out of scope.
- Production provider-selection UI remains out of scope.
- No production URL is bundled.
- No API key or provider secret is present in iOS.
- No token is persisted in `Info.plist`, `UserDefaults`, Keychain, source,
  build settings, or app environment configuration.
- The local DEBUG endpoint path must remain explicit and non-default.
- The normalizer remains the final client-side gate before candidate display.
- `Routine` and `Step` creation must remain behind explicit user save.
- Real provider work remains blocked until an auth and typed token strategy is
  implemented and reviewed.

---

## 7. Next Sequence

Use this sequence for follow-up work:

1. Keep the DEBUG endpoint QA harness local-only and explicit.
2. Add or repeat endpoint error QA for timeout, unauthorized, rate limit,
   unavailable, invalid response, and invalid request categories.
3. Define a typed short-lived token strategy for the training-plan endpoint.
4. Implement token acquisition and refresh only after that strategy is
   approved.
5. Add a real provider adapter only after auth and token handling are ready.
6. Add any production endpoint UI only after privacy, auth, cost, and opt-in
   behavior are approved.
