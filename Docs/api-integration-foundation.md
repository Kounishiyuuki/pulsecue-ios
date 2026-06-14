# API 連携基盤（iOS 側 / 実 API 接続前の土台）

実 API フェーズに入る前の、iOS 側 API 連携の**土台**をまとめる。実装は
`Pulse Cue/Services/APIIntegrationFoundation.swift` に追加される追加専用の型群で、
**既存フローには一切接続していない**。アプリはローカルファーストのまま、既定では
API 通信を行わない。

> このドキュメントは方針の記録のみ。**secret / token / API key / 本番 URL は
> 一切記載しない・アプリにも追加しない。**

---

## 1. 現状（このフェーズで「やらない」こと）

- 本番 API は**有効化していない**。既定は `.disabled` で通信は発生しない。
- 本番エンドポイント URL / `*.workers.dev` のデフォルトは**持たない**。
- トークン永続化は**実装していない**（Keychain / UserDefaults / Info.plist いずれも未使用）。
- サーバー同期・ユーザーデータ送信は**行わない**。
- `AuthSession` は引き続き provider / displayName / email のみ（トークン項目なし）。
- Apple の identityToken / authorizationCode / user ID、Google の idToken /
  accessToken / refreshToken / serverAuthCode / user ID は**読まない・保存しない・渡さない**。

## 2. 構成（追加された型）

| 型 | 役割 | 安全境界 |
|---|---|---|
| `APIEnvironment` | `.disabled` / `.mock` / `.custom(baseURL:)` | 既定 `.disabled`。`baseURL` は `.custom` のときのみ。本番 URL なし |
| `APIConfiguration` | 環境 + 任意の async トークンプロバイダ + timeout | `localFirstDefault` は `.disabled`。資格情報を持たない |
| `APIRequest` | 送信内容（method / path / headers / body） | トランスポート非依存の値型 |
| `APIRequestBuilder` | `APIRequest` → `URLRequest` 変換 | トークンが**明示注入かつ非空のときだけ** `Authorization: Bearer` を付与 |
| `APIClient`（protocol） | 送信の抽象 | 既定実装は通信しない |
| `DisabledAPIClient` | 既定。全リクエストを拒否 | 通信を一切行わない |
| `MockAPIClient` | テスト / dev 用。注入クロージャで応答 | responder 未注入なら `.disabled` |
| `URLSessionAPIClient` | URLSession 実装 | `.custom(baseURL:)` の注入時のみ構築。本番デフォルトなし |
| `APIClientFactory` | 設定から `APIClient` を構築 | 既定は `DisabledAPIClient`。`.custom` のときのみ URLSession 実装 |

既存の `AITrainingPlanEndpointClient` / `AITrainingPlanProviderFactory` と同じ
安全パターン（baseURL 注入・任意トークンクロージャ・本番デフォルトなし・非永続）を
踏襲しており、概念の重複を避けて全体で一貫した networking 方針にしている。

## 3. 将来 実 API 接続を有効化するとき

- `APIConfiguration(environment: .custom(baseURL: <注入URL>), tokenProvider: <closure>)`
  を**明示的に注入**して `APIClientFactory.makeClient(for:)` を呼ぶ。
- 本番 URL はアプリにハードコードせず、設定/注入で与える（Release が暗黙に
  バックエンドへ到達することはない）。
- トークンは短命なものを `tokenProvider` クロージャ経由で都度供給し、**この層では
  保存しない**。永続化が必要になった場合は、別途明示的に設計された安全なストアを
  用意する（本フェーズでは未実装）。

## 4. テスト

`Pulse CueTests/APIIntegrationFoundationTests.swift` で以下を検証：

- 既定環境が `.disabled`・`baseURL` なし・本番デフォルトなし。
- `.disabled` / `.mock`（responder なし）は通信せず `.disabled` を投げる。
- リクエストビルダーはトークン未注入 / nil / 空文字のとき `Authorization` を付けない。
- トークンが明示注入されたときだけ `Authorization: Bearer` を付ける。
- ビルダーはトークンをキャッシュ/永続化せず、毎回プロバイダを再呼び出しする。

---

## 関連

この汎用基盤と、既存の AI / 写真推定 endpoint provider 群との関係（共有パターン・意図的に分離した点・
将来の統合/実 API 接続ステップ）は `Docs/api-foundation-and-existing-providers.md` を参照。
