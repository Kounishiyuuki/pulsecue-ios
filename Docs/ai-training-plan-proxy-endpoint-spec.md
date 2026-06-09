# AI トレーニングプラン プロキシ エンドポイント仕様（AI Training Plan Proxy Endpoint Spec）

> **本ドキュメントの目的**: 将来の**実 AI トレーニングプラン生成**を、バックエンド /
> プロキシ経由で安全に呼び出すためのエンドポイント仕様を、実装の **前に** 確定させる。
> 実装は別 PR。**本 PR はドキュメントのみ**。サーバ実装・iOS ネットワーク・実 AI 連携・
> API キー・実 URL は一切追加しない。
>
> 採用方針の背景は
> [`ai-training-plan-provider-architecture.md`](ai-training-plan-provider-architecture.md)
> （PR #77、アーキテクチャ決定）を参照。クレデンシャル方式は
> [`credential-strategy.md`](credential-strategy.md) 案 B、トークン発行は
> [`import-token-endpoint-spec.md`](import-token-endpoint-spec.md) と同型。
>
> 対象読者: バックエンドプロキシおよび iOS クライアントを担当する後続 PR の開発者。
> 作成日: 2026-06-01。

---

## 1. エンドポイントの目的（Purpose）

- 将来の**バックエンド / プロキシ**エンドポイント。トレーニングプランの**下書き**を生成する。
- iOS の `AITrainingPlanRequest` 相当の入力を、実 AI プロバイダ向けに変換する。
- 制約済みの `AITrainingPlanResponse` 相当の出力を返す。
- **何も保存しない。** 永続化（`Routine` / `Step`）は iOS 側のユーザー明示確定でのみ起こる。
- プロバイダ API キーは**サーバ側のみ**で保持し、iOS には決して降ろさない（PR #77 §5）。

このエンドポイントは [`ai-training-plan-provider-architecture.md`](ai-training-plan-provider-architecture.md)
§4 の**案 B（iOS → PulseCue バックエンド → プロバイダ）**を具体化したもの。iOS は引き続き
`AITrainingPlanProviding` に依存し、実プロバイダはこのエンドポイントを叩く同プロトコルの
別実装として後続 PR で追加する。

---

## 2. 現状（Current State）

| 項目 | 状態 | PR |
|---|---|---|
| AI 計画境界（値型・プロバイダ抽象・正規化） | 実装済み（`AITrainingPlanProvider.swift`） | #74 |
| モック chat UI / 保存ハンドオフ | 実装済み | #75 / #76 |
| アーキテクチャ決定（案 B・キーはサーバ側） | ドキュメント化済み | #77 |
| 本エンドポイント仕様 | 本 PR（ドキュメントのみ） | #78 |
| バックエンドプロキシ実装 | **未実装** | — |
| iOS ネットワーククライアント | **未実装**（`MockAITrainingPlanProvider` のみ） | — |
| プロバイダ API キー / 実 Worker URL | **アプリにもリポジトリにも存在しない** | — |

---

## 3. 提案エンドポイント（Proposed endpoint）

既存 Worker の命名（`/api/...`）に揃える。実デプロイ URL / `*.workers.dev` は**記載しない**。

```
POST /api/ai/training-plan
Content-Type: application/json
Authorization: Bearer <short-lived device-scoped token>
```

- パス: 既存の `/api/gym-machines/import` / `/api/auth/import-token` と同じ `/api/` 名前空間。
- 認証は §4。

---

## 4. 認証 / クレデンシャルモデル（Auth model）

[`credential-strategy.md`](credential-strategy.md) 案 B と
[`import-token-endpoint-spec.md`](import-token-endpoint-spec.md) を踏襲する。

- **iOS はプロバイダキーを送らない / 持たない。** `Info.plist` / `xcconfig` /
  `UserDefaults` / ソース / Keychain のいずれにも置かない。
- **プロバイダ API キーはバックエンド側 secret としてのみ存在する。** Worker secret。
- iOS からのリクエストは、将来 auth が整備されるなら**短期・端末スコープのトークン**
  （`Authorization: Bearer <token>`）で認証する。トークンは
  [`import-token-endpoint-spec.md`](import-token-endpoint-spec.md) の発行方式を
  プラン生成スコープ向けに流用する想定（例: `scope: ai:training-plan`）。
- 認証は**未実装 / 抽象**として記述する。本 PR で実トークン・実検証は追加しない。
- **本ドキュメントに secret / 実トークン値 / 実 URL を一切記載しない。**
- 認証・型付きトークンの詳細方針（スコープ・境界・エラー・責務分担）は
  [`ai-endpoint-auth-token-strategy.md`](ai-endpoint-auth-token-strategy.md) を参照。

> 以下 §4.1–§4.9 は **将来の認証コントラクト**を確定するための仕様であり、
> **本 PR では実装しない**（auth ミドルウェア・トークン検証・トークン発行・実
> プロバイダ呼び出しのいずれも追加しない）。プレースホルダのみを記載し、実トークン
> 値・実 secret・実 URL は一切含めない。現状の dev/mock エンドポイントは引き続き
> ungated（§4.8）。

### 4.1 必須認証ヘッダ（Required auth header, future）

本番有効化後、`POST /api/ai/training-plan` は次のヘッダを**必須**とする:

```
Authorization: Bearer <short-lived app-to-backend token>
```

- `<short-lived app-to-backend token>` は**プレースホルダ**。実トークン値は本書に書かない。
- これは「アプリ → 自社バックエンド」用トークンであり、**プロバイダ API キーではない**。
- 実エンドポイント URL は本書に記載しない（既存方針どおり、`/api/...` 名前空間のみ示す）。

### 4.2 トークン要件（Token requirements, future）

- **app → backend 専用**。iOS はこのトークンでのみ自社バックエンドを呼ぶ。
- **プロバイダ API キーはサーバ側 secret にのみ存在**し、iOS へは降ろさない。
- **必須スコープ: `ai:training-plan`**。他スコープのトークンは拒否（§4.4 `invalid_scope`）。
- **短期（short-lived）**。`expiresAt` 失効後は無効。TTL は別途
  [`ai-endpoint-auth-token-strategy.md`](ai-endpoint-auth-token-strategy.md) §3 / `import-token-endpoint-spec.md` で確定。
- **プロバイダ呼び出しの前にサーバがトークンを検証する**。検証前に推論を走らせない。
- **トークンをプロバイダへ転送しない**。トークンは自社境界で消費し、プロバイダには渡さない。
- **プロバイダキーを iOS へ返さない**。レスポンス・エラーのいずれにも含めない。

### 4.3 エラー envelope 形（Error envelope shape）

`POST /api/ai/training-plan` のエラーは次の形に統一する（§7 と一致）:

```json
{
  "error": {
    "code": "<machine-readable code>",
    "message": "<人間可読の説明（安全・非機微）>",
    "requestId": "<安全な相関 ID（非機微）>"
  }
}
```

任意フィールド（必要時のみ・常に安全/非機微であること）:

- `retryAfterSeconds`: `rate_limited` / `quota_exceeded` で再試行までの目安秒数。
- `details`: **安全かつ非機微な場合のみ**。トークン・プロバイダ生エラー・相談文・
  内部スタックトレース・他ユーザー情報は**入れない**。

`requestId` はサーバが採番する相関用 ID。ログ突合に使い、トークンや個人情報を含めない。

### 4.4 HTTP ステータスとエラーコード（Status & codes, future）

| 状況 | HTTP | code |
|---|---|---|
| `Authorization` ヘッダ欠落 | 401 | `unauthorized` |
| `Authorization` ヘッダの形式不正（`Bearer ` 接頭なし等） | 401 | `unauthorized` |
| 空の bearer トークン | 401 | `unauthorized` |
| トークン無効（署名/検証失敗） | 401 | `unauthorized` |
| トークン期限切れ | 401 | `token_expired` |
| 有効だが `ai:training-plan` スコープ無し | 403 | `invalid_scope` |
| レート制限超過 | 429 | `rate_limited`（`retryAfterSeconds` 任意） |
| クォータ超過 | 429 | `quota_exceeded`（`retryAfterSeconds` 任意） |
| リクエストボディ不正（JSON/型/制約） | 400 | `invalid_request` |
| プロバイダ応答タイムアウト | 504 | `timeout` |
| プロバイダ障害 / 到達不可 | 503 | `provider_unavailable` |
| プロバイダ出力がスキーマ不適合 / 安全でない | 502 | `invalid_provider_response` |
| 想定外のサーバ失敗 | 500 | `unknown` |

> **コード名の整合**: 「プロバイダ出力が不正/安全でない（502）」の**正準ワイヤコードは
> `invalid_provider_response`**。これは現行 iOS クライアント
> （`AITrainingPlanEndpointClient`）がデコードする文字列であり、概念上の
> 「invalid response」条件に対応する（iOS は `AIPlanGenerationError.invalidResponse`
> へ畳み込む。§4.7）。サーバ実装は `invalid_response` ではなく
> `invalid_provider_response` を返すこと（変える場合は iOS デコーダも同時更新）。
> 401 系（`unauthorized` / `token_expired`）と 403（`invalid_scope`）の判別は
> `code` で行い、`message` にスコープ名やトークン詳細を含めない。

### 4.5 レスポンス安全規則（Response safety rules）

- レスポンスに**プロバイダ API キーを含めない**。
- レスポンスに**プロバイダの生エラーを含めない**（型付き `code` + 安全な `message` のみ）。
- レスポンスに**プロバイダの生ペイロードを含めない**（§6 のスキーマに正規化してから返す）。
- レスポンス/エラーに**トークンをエコーしない**。
- **`userMessage`（相談文）をエラーやログにエコーしない**。
- `requestId` は安全・非機微であること。

### 4.6 ロギング規則（Logging rules）

[`ai-privacy-and-safety.md`](ai-privacy-and-safety.md) / §10 と一致:

- **`Authorization` ヘッダを redact する**（ヘッダ丸ごと出力に注意）。
- **トークンをログに残さない。**
- **プロバイダ API キーをログに残さない。**
- **`userMessage` 全文をログに残さない。**
- **プロバイダの生レスポンスをログに残さない。**
- 残してよいのは安全なリクエストメタデータ（`deviceId` または hash・`appVersion`・
  timestamp）+ 結果 `code` + `requestId` のみ。

### 4.7 iOS マッピング期待（iOS mapping expectations）

サーバ `code` → iOS の型付きエラー → `AIPlanGenerationError`（PR #83）カテゴリ:

| サーバ code | iOS の扱い | `AIPlanGenerationError` |
|---|---|---|
| `unauthorized` / `token_expired` | トークン再取得を **1 度だけ**試行（ループガード）→ 失敗ならエラー UI | unauthorized |
| `invalid_scope` | 再取得せずエラー UI（バグ可能性として扱う） | unauthorized |
| `rate_limited` / `quota_exceeded` | 「時間をおいて再試行」/「利用上限」案内 + ルールベース誘導 | rateLimited |
| `timeout` / `provider_unavailable` | 再試行案内 + ルールベースフォールバック | timeout / providerUnavailable |
| `invalid_provider_response` | 安全なフォールバック（「うまく作成できませんでした」+ 再試行） | invalidResponse |
| `unknown` | 汎用エラー + 再試行 | unknown |

- **どの認証/エンドポイント失敗でも `Routine` / `Step` を作らない。**
- **`AITrainingPlanNormalizer` が候補表示前の最後の門番**であり続ける。
- **保存は明示確定のみ**（「この候補を保存」）。

### 4.8 dev/local 移行（Dev/local transition）

- 現状の **DEBUG loopback QA は local/mock 専用のまま**でよい（`#if DEBUG` の
  `debugLocalMock`、認証なし）。
- 将来の**モックトークン検証はフェイク/ローカルトークンのみ**で行う（実トークン不可）。
- **本番 auth 有効化は別 PR + 別承認**。本 docs PR は本番エンドポイントを有効化しない。

### 4.9 将来実装のテストマトリクス（Test matrix for future implementation）

サーバ auth 実装 PR は、最低限次を網羅する（ライブプロバイダ・実トークンは使わない）:

| # | ケース | 期待 |
|---|---|---|
| 1 | `Authorization` ヘッダ無し | 401 `unauthorized` |
| 2 | `Authorization` ヘッダ形式不正 | 401 `unauthorized` |
| 3 | 空の bearer トークン | 401 `unauthorized` |
| 4 | 無効トークン | 401 `unauthorized` |
| 5 | 期限切れトークン | 401 `token_expired` |
| 6 | 有効トークン・スコープ不一致 | 403 `invalid_scope` |
| 7 | 有効トークン・`ai:training-plan` スコープ | 200（候補レスポンス） |
| 8 | レート制限超過 | 429 `rate_limited` |
| 9 | クォータ超過 | 429 `quota_exceeded` |
| 10 | プロバイダタイムアウト | 504 `timeout` |
| 11 | プロバイダ到達不可 | 503 `provider_unavailable` |
| 12 | プロバイダ不正応答 | 502 `invalid_provider_response` |
| 13 | 不正 JSON ボディ | 400 `invalid_request` |
| 14 | 正常リクエスト・`availableMachineIds` あり | 200・既知 id のみ使用 |
| 15 | 正常リクエスト・未知マシン id | 200・未知 id 除外 + 警告 |

> 認証ケース（#1–#6）はモックトークン検証層で、プロバイダ系（#10–#12）はプロバイダ
> アダプタのスタブで検証する。いずれも実 AI・実トークン・本番 URL に依存しない。

---

## 5. リクエストスキーマ（Request schema）

iOS の `AITrainingPlanRequest` をそのまま JSON 化したもの（draft）:

```json
{
  "userMessage": "<自由記述の相談文>",
  "goal": "fatLoss | hypertrophy | strength | consistency | null",
  "daysPerWeek": 3,
  "targetBodyParts": ["chest", "back", "legs", "shoulders", "arms", "core", "fullBody"],
  "experienceLevel": "beginner | intermediate | advanced | null",
  "preferredSplit": "fullBody | upperLower | pushPullLegs | bodyPart | null",
  "availableMachineIds": ["bench_press", "lat_pulldown"]
}
```

**制約（バックエンドで一次検証）:**

- `userMessage`: **最大長を設ける**（例: 1,000 文字）。超過は切り詰め + 警告。
- `daysPerWeek`: **1...6 にクランプ**。範囲外は補正 + 警告。
- `goal` / `experienceLevel` / `preferredSplit`: **正準 enum 値のみ**。不明値は `null` 扱い。
- `targetBodyParts`: **正準 `BodyPart` enum 値のみ**（`chest` / `back` / `legs` /
  `shoulders` / `arms` / `core` / `fullBody`）。未知の値は無視。
- `availableMachineIds`: **既知のローカルカタログ id のみ**意味を持つ。未知の id は
  プロバイダプロンプト構築前にバックエンドで除外してよい。
- オプションのクライアントメタデータは**安全なもののみ**（例: ロケール `ja`）。
  位置・体重・健康履歴などの個人的文脈は**送らない**（§9）。

---

## 6. レスポンススキーマ（Response schema）

iOS の `AITrainingPlanResponse` 相当（draft、生・未検証として扱う）:

```json
{
  "title": "<プランのタイトル | null>",
  "rationale": "<組み立て理由の短文 | null>",
  "warnings": ["<人間可読の注意書き>"],
  "sessions": [
    {
      "title": "<セッション名 | null>",
      "exerciseMachineIds": ["bench_press", "chest_press"],
      "notes": "<補足 | null>"
    }
  ]
}
```

**制約:**

- **セッション数の上限**（例: 6）。`daysPerWeek` のクランプと整合させる。
- **1 セッションあたりの種目数の上限**（例: 8）。
- **未知のマシン id を返してもよい**が、iOS の `AITrainingPlanNormalizer` が
  ドロップして警告する（現行挙動）。バックエンドでも一次的に除外してよい。
- **自由テキスト（`title` / `rationale` / `notes`）は表示専用。** アプリ動作の指示として
  解釈しない。マシン選択は id 照合のみで決まる（プロンプトインジェクション耐性、PR #77 §9）。
- 出力はあくまで候補。`AITrainingPlanProviding` の戻り値は `AITrainingPlanResponse` の
  ままで、実プロバイダでもモックでも同じ `AITrainingPlanNormalizer` を通して
  `WeeklyTrainingPlanCandidate` に変換する。

---

## 7. エラーモデル（Error model）

既存 Worker のエラー envelope と揃える:

```json
{ "error": { "code": "<machine-readable code>", "message": "<人間可読の説明>", "requestId": "<安全な相関 ID>" } }
```

| code | HTTP | 説明 | iOS 側の扱い |
|---|---|---|---|
| `unauthorized` | 401 | トークン欠落 / 形式不正 / 無効 | トークン再取得を 1 度試行 → 失敗ならエラー UI |
| `token_expired` | 401 | トークン期限切れ | トークン再取得を 1 度試行（ループガード）→ 失敗ならエラー UI |
| `invalid_scope` | 403 | 有効だが `ai:training-plan` スコープ無し | 再取得せずエラー UI（バグ可能性） |
| `invalid_request` | 400 | JSON パース失敗 / 必須欠落 / 型不正 / 制約違反 | 入力を見直す案内。送信前にクライアントでも検証 |
| `rate_limited` | 429 | per-user / per-device の頻度上限超過 | 「時間をおいて再試行」+ ルールベースへ誘導 |
| `quota_exceeded` | 429 | プラン生成クォータ超過 | 「現在利用できません」+ ルールベース / 手動へ誘導 |
| `timeout` | 504 | プロバイダ応答タイムアウト | 「時間をおいて再試行」。リトライはユーザー操作のみ |
| `provider_unavailable` | 503 | プロバイダ障害 / 到達不可 | 同上 + ルールベースフォールバック |
| `invalid_provider_response` | 502 | プロバイダ出力がスキーマ不適合 | 「うまく作成できませんでした」+ 再試行 / ルールベース |
| `unknown` | 500 | 想定外のサーバ失敗 | 汎用エラー + 再試行 / ルールベース |

**ユーザー向け扱いの鉄則:**

- どのエラーでも **`Routine` / `Step` を作らない**。
- 再試行コピーを出し、最終的に `RuleBasedWeeklyPlanGenerator` / 手動編集へ着地できる。
- `message` にトークン値・内部スタックトレース・他ユーザー情報を含めない。
- 認証関連コード（`unauthorized` / `token_expired` / `invalid_scope`）と envelope の
  `requestId` を含む完全な認証コントラクトは §4.1–§4.9 を参照。

---

## 8. タイムアウト / キャンセル / リトライ（Timeout / Cancellation / Retry）

- **リクエストタイムアウト**を設ける（例: 20–30 秒）。超過は `timeout`。
- **キャンセル対応。** 生成中（iOS の `isGenerating`）にユーザーが離脱 / キャンセルできる。
- **自動の繰り返しリトライをしない。** 失敗時の自動再送は禁止。
- **リトライはユーザーの明示操作に限る。** `unauthorized` のトークン再取得のみ
  例外的に 1 度だけ自動で行ってよい（[`import-token-endpoint-spec.md`](import-token-endpoint-spec.md) §7.3 と同型、ループ防止）。

---

## 9. レート制限 / コスト管理（Rate-limit / Cost controls）

実クラウド AI は従量課金になりうる。乱用・暴走は直接コスト。

- **ユーザーの明示操作 1 回 = 推論 1 回。** 同一操作で推論を繰り返さない。
- **バックエンド側でクォータを設ける**: per-user / per-device のスロットリング。
- **バックグラウンド生成をしない。**
- クォータ超過時は `rate_limited` / `quota_exceeded` を返し、ルールベースへ誘導。

---

## 10. プライバシー / ロギング（Privacy / Logging）

PR #77 §7 と [`ai-privacy-and-safety.md`](ai-privacy-and-safety.md) に従う。

- **`userMessage` をログに残さない**（サーバログ・iOS `OSLog`/`print`・クラッシュ・分析の
  いずれにも）。
- **生のプロバイダレスポンスをログに残さない。**
- **機微フィールドを redact する。** 監査ログは `deviceId`（または hash）+ `appVersion`
  + timestamp + 結果コードのみ。相談文・生成詳細・トークン値は載せない。
- **永続的なチャット履歴を持たない**（別途設計されるまで）。候補は iOS の `@State` のみ。
- **プロンプト内容を分析 / クラッシュログに入れない。**

---

## 11. 検証と正規化（Validation & Normalization）

- **バックエンドが形（shape）を一次検証する**（§5 / §6 の制約）。
- **iOS の `AITrainingPlanNormalizer` が最後の門番。** 多層防御として、バックエンド検証に
  加えクライアントでも再検証する。不明マシン除外・空セッションスキップ・タイトル
  フォールバック・空/不正出力でもクラッシュしない（現行挙動）。
- **保存はユーザー明示確定が必須。** 「候補 → レビュー → 確定 → 保存」境界は不変。

---

## 12. テスト戦略（Test strategy）

- **リクエスト / レスポンスのデコード契約テスト**（JSON ⇄ 値型）。
- **モックバックエンドのフィクスチャ**を使う。ライブプロバイダを単体テストで叩かない。
- **不正ペイロードのテスト**（欠落 / 型不正 / 制約違反 → `invalid_request` / 正規化警告）。
- **タイムアウト / レート制限 / エラーマッピングのテスト**（HTTP / code → 型付きエラー）。
- ネットワーク層は `URLProtocol` スタブ等で差し替え（既存
  `OpenFoodFactsProductLookupService` テストと同方針）。実プロバイダは既定 CI で叩かない。
- 既存の正規化テスト（`AITrainingPlanNormalizerTests`）・保存境界テスト
  （`MockAIPlanSaveHandoffTests` / `WeeklyPlanRoutineSaveTests`）を維持・拡張する。

---

## 13. 将来 PR の分割案（Future PR Breakdown）

各 PR は前段の境界を壊さないこと。`server/` に触れるのはバックエンド PR のみ。

| PR | 内容 | ネットワーク / 実 AI |
|---|---|---|
| **PR #78** | 本エンドポイント仕様（ドキュメントのみ）＝本 PR | なし |
| **PR #79** | バックエンドプロキシ **モック**エンドポイント実装（`server/src/routes/aiTrainingPlan.ts`。決定論的応答・実 AI なし・認証なし=dev/mock 専用） | サーバ側のみ・実 AI なし |
| **PR (次)** | バックエンド実プロバイダアダプタ（サーバ側 secret 保持・プロバイダ呼び出し） | サーバ側のみ・実 AI あり |
| **PR (次)** | iOS エンドポイントクライアント（`AITrainingPlanProviding` の実装を追加）。設定トグルでガード、既定 OFF | あり（opt-in 時のみ） |
| **PR (次)** | UI のローディング / エラー / 再試行ハードニング | なし（クライアント） |
| **PR (次)** | QA・コスト・レート制限のハードニング | — |

---

## 14. 明示的な非ゴール（Non-Goals）

本 PR は次を**やらない / 認めない**:

- エンドポイント実装（サーバ / iOS いずれも）。
- 実 AI 実装 / OpenAI 連携 / ネットワーク通信 / `URLSession` / `URLRequest`。
- プロバイダ API キー・実 Worker URL・`*.workers.dev`・実トークン値の記載。
- iOS クライアントコードの追加。
- SwiftData スキーマ変更 / `@Model` 変更。
- 保存挙動の変更 / アプリ挙動の変更。
- `server/` の変更（本ドキュメントは判断材料を与えるだけ）。

---

## 関連ドキュメント

- [`ai-training-plan-provider-architecture.md`](ai-training-plan-provider-architecture.md)
  — 実 AI プロバイダのアーキテクチャ決定（案 B）。本仕様はその「エンドポイント契約」章を
  独立・詳細化したもの。
- [`gym-machine-catalog-and-plan-foundation.md`](gym-machine-catalog-and-plan-foundation.md)
  — 週次プラン候補フロー全体の設計。
- [`credential-strategy.md`](credential-strategy.md) — クライアントに長期キーを置かない
  方針と短期トークン方式（案 B）。
- [`import-token-endpoint-spec.md`](import-token-endpoint-spec.md) — 短期デバイス
  スコープトークンのエンドポイント仕様。本エンドポイントの認証はこれを流用する。
- [`ai-endpoint-auth-token-strategy.md`](ai-endpoint-auth-token-strategy.md) — 本
  エンドポイントの認証・型付きトークン戦略（スコープ `ai:training-plan`・境界・エラー）。
- [`ai-privacy-and-safety.md`](ai-privacy-and-safety.md) — AI 安全境界の鉄則。
- [`photo-ai-backend-token-spec.md`](photo-ai-backend-token-spec.md) — 写真 AI 向けの
  同型バックエンド / トークン仕様。

---

> **更新ルール**: 本仕様は §3–§7 の draft 部分が後続 PR で固まったら必要に応じて改訂する。
> 大きな仕様変更を加えるときは、末尾に変更履歴を追記して理由を残す。
