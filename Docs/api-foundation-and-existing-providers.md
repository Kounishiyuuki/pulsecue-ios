# API 基盤と既存 endpoint provider の整理

`APIIntegrationFoundation`（PR #122）/ `APIContracts` + `APIHealthService`（PR #123）/
DEBUG ヘルス QA（PR #124）と、既存の AI / 写真推定 endpoint provider 群の関係を整理し、
将来の実 API 接続に備えるためのマップ。

> このドキュメントは整理・方針の記録のみ。**コード挙動は変更していない**（この PR は docs-only）。
> secret / token / 本番 URL は記載しない・アプリにも追加しない。

---

## 1. 全体像（レイヤー対応）

| レイヤー | 汎用基盤（新） | AI トレーニングプラン（既存） | 写真食事推定（既存） |
|---|---|---|---|
| 抽象/プロトコル | `APIClient` | `AITrainingPlanProviding` | `PhotoFoodEstimating` / `PhotoFoodEstimationEndpointClient`（contract のみ） |
| 既定（無効/モック） | `DisabledAPIClient` / `MockAPIClient` | `MockAITrainingPlanProvider` | `MockPhotoFoodEstimator` / `MockPhotoFoodEstimationEndpointClient` |
| ネットワーク実装 | `URLSessionAPIClient`（`.custom` 注入時のみ） | `AITrainingPlanEndpointClient`（baseURL 注入時のみ） | （未実装：contract のみ） |
| 設定/ファクトリ | `APIConfiguration` / `APIClientFactory` | `AITrainingPlanEndpointConfiguration` / `AITrainingPlanProviderFactory` | — |
| エラー型 | `APIClientError` / `APIServiceError` | `AITrainingPlanEndpointError` | （contract の error 形のみ） |

## 2. 共有している安全パターン（既に一致している点）

新基盤と既存 endpoint client は、**同一の安全境界**を独立に踏襲している：

- **本番 URL を持たない。** ネットワーク実装は baseURL を**注入**したときのみ構築でき、
  既定は mock / disabled。`*.workers.dev` などのデフォルトは存在しない。
- **トークンは非永続。** 任意の `(@Sendable () async -> String?)?` クロージャで都度供給し、
  注入かつ非空のときだけ `Authorization: Bearer` を付ける。Keychain / UserDefaults / Info.plist
  に保存しない。refresh / OAuth 交換もない。
- **ユーザーデータを勝手に送らない。** 既定経路は通信せず、生成物の保存は明示操作のみ。
- **既存フローへ未接続。** 既存 UI の既定は mock provider のまま（`MockAITrainingPlanChatView` は
  引数なしで mock を解決）。

→ つまり「重複」は概念パターンの一致であり、**危険な重複ではない**。新基盤は汎用の seam、
既存 client はドメイン型付きの実装、という役割分担になっている。

## 3. 意図的に分離したまま残すもの（この PR で統合しない理由）

`AITrainingPlanEndpointClient` を汎用 `APIClient` 経由に作り替えることは**挙動変更を伴う**ため、
本 PR では行わない（将来タスクとして記録）。理由：

- ドメイン型（`AITrainingPlanRequest` / `AITrainingPlanResponse`）の **Codable wire DTO** と
  **エラーエンベロープ（`AITrainingPlanEndpointError`）のマッピング**が密に結合しており、
  汎用 `APIClient.send(_:) -> Data` に通すと encode/decode/エラー写像の経路が変わる。
- **AI 明示保存境界**（`AITrainingPlanNormalizer` を通してからレビュー/保存）を一切動かさない方針。
  この整理で `ModelContext.insert` の追加や保存タイミング変更は行わない。
- `PhotoFoodEstimationEndpointClient` は **contract のみ**（実装は mock）で、まだ通信コードが無いため
  統合対象がない。

「挙動が変わる統合はしない。代わりに将来タスクとして記録する」という方針に従う。

## 4. 将来の実 API 接続 / 統合ステップ（順序固定・先取りしない）

1. まず汎用基盤側で実エンドポイント設定を**注入**して接続を確立（`APIConfiguration(.custom(baseURL:))`
   → `APIClientFactory` → adapter）。本番 URL はハードコードせず注入。
2. 必要になった時点で、AI/写真の各 endpoint client を汎用 `APIRequestBuilder` ベースへ寄せる
   リファクタを、**挙動同値性をテストで担保しながら**個別 PR で実施（本 PR では未実施）。
3. トークンが必要になった場合は短命トークンをクロージャ供給し、永続化が要るなら別途**明示設計の
   安全なストア**を用意する（現状は意図的に未実装）。
4. 生成物の保存は引き続き明示操作のみ（AI 保存境界を維持）。

## 5. 現時点で意図的に「やっていない」こと（再確認）

- 本番エンドポイント / Worker URL のデフォルト化：**なし**。
- 既存アプリフローからの実 API 呼び出し / ユーザーデータ送信：**なし**。
- トークン/エンドポイントの永続化（Keychain / UserDefaults）：**なし**。
- SwiftData schema / `@Model` 変更、CloudKit/サーバー同期：**なし**。
- 実 AI/プロバイダ SDK・キー：**なし**。

## 6. 関連テスト（既存・本 PR で挙動不変を担保）

- 汎用基盤: `APIIntegrationFoundationTests` / `APIContractsAndAdaptersTests` / `APIHealthQAModelTests`
- AI endpoint: `AITrainingPlanProviderFactoryTests`（既定 mock・endpoint は baseURL 必須・本番デフォルトなし）
  / `AITrainingPlanEndpointClientTests`
- 写真 endpoint: `PhotoFoodEstimationEndpointClientTests`

> 本 PR は docs-only のためコード挙動は変わらず、上記テストの結果は #124 時点の green と同一。

## 関連ドキュメント

- `Docs/api-integration-foundation.md` — 汎用 API 基盤
- `Docs/api-contracts-and-adapters.md` — contract / adapter / DEBUG ヘルス QA
- `Docs/ai-training-plan-provider-architecture.md` — AI プロバイダ境界
- `Docs/photo-ai-provider-strategy.md` — 写真推定プロバイダ境界
