# API contract と adapter 層（実 API 接続前の具体型）

`APIIntegrationFoundation`（PR #122）の上に、具体的な **API contract（DTO / エンベロープ）**
と **mock-safe な adapter / service 層**を追加したものをまとめる。実装は追加専用で、
**既存フローには一切接続していない**。アプリはローカルファーストのまま、既定では API 通信を
行わない。

> このドキュメントは方針の記録のみ。**secret / token / API key / 本番 URL は
> 一切記載しない・アプリにも追加しない。**

---

## 1. 現状（このフェーズで「やらない」こと）

- 本番 API は**有効化していない**。adapter の既定クライアントは `DisabledAPIClient` で通信しない。
- 本番エンドポイント URL / `*.workers.dev` のデフォルトは**持たない**。
- 既存アプリフローから API を呼ばない。**ユーザーデータをサーバーへ送らない**。
- トークン永続化は**実装していない**（Keychain / UserDefaults / Info.plist いずれも未使用）。
- `AuthSession` は引き続き provider / displayName / email のみ（トークン項目なし）。
- Apple / Google のトークン・コード・user ID は読まない・保存しない・渡さない。

## 2. 追加した contract（`Pulse Cue/Services/APIContracts.swift`）

| 型 | 役割 | 備考 |
|---|---|---|
| `APIErrorCode` | サーバーエラーコードの安定マッピング | `String` backed、未知は `.unknown` |
| `APIErrorResponse` | `{ "error": { code, message } }` の Decodable | 表示用のみ・プロバイダ内部を持たない |
| `APIResponseEnvelope<T>` | `{ "data": T }` の汎用エンベロープ | 任意ヘルパー（bare body でも可） |
| `HealthCheckResponse` | 読み取り専用の health/version プローブ DTO | **ユーザーデータを含まない** |
| `APIHealthStatus` | DTO をアプリ向けにマップした値 | 永続化しない |

**DTO は SwiftData の `@Model`（Routine / Session / DayLog / UserProfile / Gym …）とは
明確に分離**しており、wire 形式とアプリ内モデルを切り離している。`@Model` は変更していない。

## 3. 追加した adapter / service（`Pulse Cue/Services/APIHealthService.swift`）

- `APIHealthService`: 注入された `APIClient` 経由で health エンドポイントを叩く読み取り専用 adapter。
  - 既定クライアントは `DisabledAPIClient` → **既定では通信せず `.disabled` を投げる**。
  - `checkHealth()` は **body なしの GET**。ユーザーデータを送らない。
  - `path` は相対パスのみ（scheme/host なし）。本番 URL をハードコードしない。
  - **既存 UI からは構築・呼び出ししていない。**
- `APIServiceError`: `APIClientError` からアプリ向けへの安定マッピング（`mapClientError`）。

## 4. 将来 実 API 接続を有効化するとき（wiring 手順）

1. `APIConfiguration(environment: .custom(baseURL: <注入URL>), tokenProvider: <closure>)` を
   明示的に構成（本番 URL はハードコードせず注入）。
2. `APIClientFactory.makeClient(for:)` で `URLSessionAPIClient` を構築。
3. その client を `APIHealthService(client:)` 等の adapter に注入する。
4. 必要になった画面/診断から adapter を呼ぶ（このフェーズでは未接続）。
5. トークンは短命なものを `tokenProvider` クロージャ経由で都度供給し、**この層では保存しない**。
   永続化が必要になった場合は別途明示的に設計された安全なストアを用意する（本フェーズでは未実装）。

## 5. テスト（`Pulse CueTests/APIContractsAndAdaptersTests.swift`）

- DTO の encode/decode（health round-trip、version 欠落、error envelope、response envelope）。
- エラーコード/クライアントエラーのマッピングが安定。
- 既定 adapter は通信せず `.disabled` を投げる。
- リクエストパスが `api/health`・GET・body なしで正しく組まれる（本番 URL 不要）。
- mock client がフィクスチャを返し、healthy / degraded / 不正 JSON / 404 が正しくマップされる。
- adapter は token / base URL を保持せず、永続化経路を導入しない。
