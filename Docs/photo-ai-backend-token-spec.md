# 写真 AI バックエンド / トークン エンドポイント 仕様

> **本ドキュメントの目的**: 食事写真からの実 AI 推定を実装する**前に**、写真ペイロードを
> 安全に扱うためのバックエンド / トークン境界の仕様を確定するための設計資料。
> **実装変更は含まない**（ドキュメントのみ）。バックエンド実装・実 AI 連携・iOS の
> ネットワーキング・写真アップロード・API キー処理・本番 URL の記載は本 PR では
> 一切行わない。
>
> 対象読者: 後続の実装 PR（PR 60 以降）を担当する開発者。
> 作成日: 2026-05-25。

関連する既存仕様:
[`photo-ai-provider-strategy.md`](photo-ai-provider-strategy.md)（写真 AI のプロバイダ
方式 / クレデンシャル戦略の上位設計）、
[`photo-food-estimation-flow.md`](photo-food-estimation-flow.md)（写真推定フロー全体）、
[`credential-strategy.md`](credential-strategy.md)（クライアントに長期キーを置かない方針）、
[`import-token-endpoint-spec.md`](import-token-endpoint-spec.md)（短期トークン エンド
ポイントの先行例）、
[`ai-privacy-and-safety.md`](ai-privacy-and-safety.md)（AI 安全境界の鉄則）。

---

## 1. 目的（Purpose）

[`photo-ai-provider-strategy.md`](photo-ai-provider-strategy.md) は、実クラウド AI を
入れる場合に **iOS → PulseCue バックエンド → AI プロバイダ** の方式（案 B）を採ると
結論づけた。本ドキュメントはその案 B を**実装可能なエンドポイント仕様まで**詰める。

なぜ実装の前に仕様を固めるか:

- 写真は機微なペイロードであり、送信先・滞留時間・ロギングを後から後付けで安全に
  するのは難しい。
- AI プロバイダの秘密情報をクライアントに置かないという方針は[`credential-strategy.md`](credential-strategy.md)
  で確定済みだが、**写真 AI 特有の境界**（画像ペイロード、サイズ制限、保持なし、
  正規化レスポンス）はまだ未定義。
- 後続 PR でフェイクプロバイダ → 実プロバイダの順に進めるには、リクエスト / レス
  ポンス形と責務分担を先に合意しておく必要がある。

本ドキュメントは [`photo-food-estimation-flow.md`](photo-food-estimation-flow.md) の
**プロバイダ境界**を、サーバ側のエンドポイント仕様として展開したものに相当する。

---

## 2. 現状（Current State）

| 項目 | 状態 |
|---|---|
| iOS `PhotoFoodEstimating` プロバイダ抽象 | 実装済み（PR #50 / #52） |
| iOS `PhotoFoodEstimationInput`（画像入力契約） | 実装済み（PR #52） |
| `PhotoFoodCaptureView` ローディング / エラー / 再試行 / 二重タップ抑止 | 実装済み（PR #53） |
| `PhotoEstimateReviewView` 確認後 `.confirmed .ai` 保存 + `NutritionLedger` 同期 | 実装済み |
| 写真推定プロバイダの実装 | **モックのみ**（`MockPhotoFoodEstimator`、入力を意図的に無視） |
| 写真アップロード / ネットワーキング（写真 AI 用） | **無し** |
| 実 AI プロバイダ / API キー / 本番 URL | **iOS にもリポジトリにも存在しない** |

iOS 側の入出力は契約として固まっており、バックエンドが整い次第「現行のモック
プロバイダ」を「バックエンドを呼ぶ実プロバイダ」に差し替えるだけで `PhotoFoodEstimating`
の境界に収まる構成になっている。

---

## 3. 中核ルール（Core Rules）

[`ai-privacy-and-safety.md`](ai-privacy-and-safety.md) と [`photo-ai-provider-strategy.md`](photo-ai-provider-strategy.md)
の鉄則を、本エンドポイントに適用したもの。**後続のすべての実装 PR はこれを守る。**

1. **AI プロバイダの API キーを iOS アプリに埋め込まない。** クライアントは短期
   トークンまで。プロバイダ秘密はサーバ側 secret にのみ存在する。
2. **写真アップロードはユーザーの明示操作後のみ。** バックグラウンド送信や暗黙
   アップロードは不可。
3. **DayLog を自動更新しない。** バックエンド応答が成功しても、`.confirmed` の
   `MealEntry` はレビュー画面でユーザーが確定したときにのみ作る。
4. **推定は「候補」にとどまる。** 応答は `PhotoFoodEstimate` 相当の候補にデコード
   され、`PhotoEstimateReviewView` を経由してのみ保存される。
5. **レビュー前確定なし。** 確定経路は引き続き `ConfirmedMealEntryFactory.make(…, source: .ai)`
   → `NutritionLedger.syncDayLogIntake` のみ。
6. **キャンセルは何も作らない。** 候補は確定までビュー状態にとどまる。
7. **AI が無くても手動 / バーコード / 栄養表示 OCR は動く。** バックエンドや AI が
   不通でも、これらの経路はオフラインで完結し続けること。

---

## 4. 想定アーキテクチャ（Candidate Architecture）

実 AI 導入時の全体像:

```
iOS アプリ（ユーザーが「推定する」を明示タップ）
  → PulseCue バックエンド（Worker / 短期トークン認証）
    → AI プロバイダ（プロバイダ秘密はサーバ側のみ）
    ← プロバイダ応答（プロバイダ固有形式）
  ← 正規化された候補レスポンス（PulseCue 形式）
← `PhotoFoodEstimate` にデコード（PhotoFoodEstimating の実装内）
  → PhotoEstimateReviewView（候補レビュー）
    → ユーザー明示確定
      → ConfirmedMealEntryFactory.make(…, source: .ai)
      → modelContext.insert
      → NutritionLedger.syncDayLogIntake
```

iOS は **PulseCue バックエンドだけ**を叩く。プロバイダの URL・キーは iOS から
見えない。バックエンドはプロバイダ固有形式を吸収し、PulseCue 共通の正規化形に
落とす（プロバイダ差し替えに iOS が追従しなくて済む）。

---

## 5. バックエンド / トークン層の責務（Endpoint Responsibilities）

エンドポイント（仮称 `POST /api/photo-food-estimate`。具体的なホストは本ドキュメント
には記載しない）が担うべきこと:

- **プロバイダ秘密をサーバ側に閉じ込める** — プロバイダ API キーは Worker secret
  として保持し、iOS へは決して返さない / リダイレクトしない。
- **リクエスト形を検証する** — フィールドの存在・型・サイズ上限・MIME を検査し、
  不正リクエストはプロバイダを叩く前に拒否する。
- **画像サイズの上限を強制する** — ペイロード上限（例: 4MB）と画像長辺の最大値を
  設定し、超過は 413/400 で拒否する。
- **必要なら画像を縮小 / 再エンコード** — プロバイダ側のコスト / トークン消費を
  下げるため、サーバ側で軽量化する選択肢を持つ（実施するかは PR 63 で決定）。
- **レート制限とクォータ** — トークン単位・端末単位・グローバルの 3 段で上限を
  設け、超過は 429 を返す（[`credential-strategy.md`](credential-strategy.md) PR-δ
  と同じ設計思想）。
- **認証 / 短期トークン発行** — [`import-token-endpoint-spec.md`](import-token-endpoint-spec.md)
  の方式に準じ、App Attest 等で発行した短期トークンで `Authorization` を保護する。
  ※ 本ドキュメントは形式のみ規定し、具体的なトークン仕様は別 PR（参照: §13 PR 62）。
- **プロバイダ呼び出しと正規化** — プロバイダ応答（プロバイダ固有形式）を
  PulseCue の `PhotoFoodEstimate` に対応する形へ正規化する。
- **プロバイダの秘密 / 内部 URL を応答に含めない** — 応答に含めてよい "model
  metadata" は、ユーザに露出して問題ないモデル名 / 短い識別子のみ。
- **生写真をデフォルトで永続化しない** — リクエスト処理後、画像バイトは破棄。
  デバッグ目的の一時保持が必要になった場合は、保持期間・アクセス制御を明文化
  してから実装する（§9・§15）。
- **画像データをログに残さない** — リクエスト / レスポンスのログ化対象から画像
  バイトを除外する。

---

## 6. iOS 側の責務（iOS Responsibilities）

iOS の `PhotoFoodEstimating` 実プロバイダ実装（PR 65 で追加予定）が満たすこと:

- **明示操作後にのみ送信** — `PhotoFoodCaptureView` の「推定する」ボタン押下時
  のみ。撮影 / 選択しただけでは送信しない（取得とアップロードを分離する既存方針）。
- **画像ペイロードをローカルで準備** — 合意したサイズ上限・MIME に合わせて
  リサイズ / 再エンコードしてから送信。準備は新規ヘルパー（PR 60 で先行実装）
  に局所化する。
- **必要最小限のメタデータのみ送信** — §7 の許容フィールド以外は付けない。位置・
  体重・健康履歴などの周辺情報はリクエストに同梱しない（§9）。
- **プロバイダ秘密を一切扱わない** — iOS が保持してよいのは短期トークンまで。
- **既存のローディング / エラー / リトライ UI を使う** — `PhotoEstimationPhase` /
  `PhotoEstimationRunner`（PR #53）を経由するため、429 / タイムアウト / 401 等も
  `.failed(message:)` に正しくマッピングする。
- **レビュー画面で確定するまで保存しない** — 応答が成功しても、即座に `MealEntry`
  を作らない。`PhotoEstimateReviewView` がユーザー操作で確定したときに初めて
  `ConfirmedMealEntryFactory.make` + insert + `NutritionLedger` 同期。
- **候補はビュー状態のみで保持** — 確定までは SwiftData に書き込まない。
- **AI 無しでも他の経路が動く** — バックエンド / 実 AI が無効・課金未設定・通信不能
  のときは、手動 / バーコード / OCR を案内する（既存の UI コピーを踏襲）。

---

## 7. リクエスト形（Request Shape Draft）

エンドポイント: `POST /api/photo-food-estimate`
（**本番ホストは本ドキュメントに記載しない**。実 URL は実装 PR で設定し、iOS バイナリ
には焼き込まない方法で扱う。）

ヘッダ:

- `Authorization: Bearer <短期トークン>` — トークン具体仕様は別 PR（§13 PR 62）。
- `Content-Type: multipart/form-data` または `application/json`（画像エンコード方式は
  実装 PR で確定）。

ボディ（概念フィールド）:

| フィールド | 型 | 必須 | 内容 |
|---|---|:---:|---|
| `image` | binary / base64 | ✅ | 準備済みの画像ペイロード（リサイズ・再エンコード済み）。MIME は `image/jpeg` または `image/png` |
| `mimeType` | string | ✅ | `image/jpeg` / `image/png` |
| `pixelWidth` | integer | ✅ | 送信画像の幅（px） |
| `pixelHeight` | integer | ✅ | 送信画像の高さ（px） |
| `slot` | string | 任意 | `breakfast` / `lunch` / `dinner` / `snack` のいずれか。推定の手がかり |
| `userNote` | string | 任意 | ユーザーが任意で添えた短いメモ（個人特定情報を含まないこと） |
| `locale` | string | 任意 | `ja-JP` 等。料理判別の手がかり |
| `appVersion` | string | 任意 | デバッグ用（個人を識別しない） |
| `requestId` | string (UUID) | 任意 | クライアント生成。リトライ・ログ相関用 |

**含めない**: ユーザー ID、端末識別子、位置、体重、健康履歴、過去の食事ログ、認証
の秘密情報。

---

## 8. レスポンス形（Response Shape Draft）

成功（HTTP 200, `application/json`）:

| フィールド | 型 | 必須 | 内容 |
|---|---|:---:|---|
| `candidate.name` | string | ✅ | 推定された食事名 |
| `candidate.kcal` | integer | ✅ | カロリー（kcal） |
| `candidate.proteinGrams` | integer? | 任意 | タンパク質（g） |
| `candidate.carbGrams` | integer? | 任意 | 炭水化物（g） |
| `candidate.fatGrams` | integer? | 任意 | 脂質（g） |
| `candidate.confidence` | number (0–1)? | 任意 | プロバイダが返す場合 |
| `candidate.warnings` | string[]? | 任意 | 「分量推定の不確実性が高い」等のユーザ向け警告 |
| `model` | string? | 任意 | 安全に露出できるモデル名 / 短識別子 |
| `requestId` | string? | 任意 | リクエストの `requestId` を反映 |

失敗（HTTP 4xx / 5xx, `application/json`）:

| フィールド | 型 | 内容 |
|---|---|---|
| `error.code` | string | `unauthenticated` / `rate_limited` / `quota_exceeded` / `unsupported_image` / `no_food_detected` / `provider_unavailable` / `bad_request` / `internal_error` |
| `error.message` | string | ユーザー向けに翻訳可能なメッセージ（生のプロバイダエラーは出さない） |
| `requestId` | string? | 相関用 |

**含めない**: プロバイダ API キー、内部エンドポイント、AI プロバイダのフルレスポンス、
プロバイダ側スタックトレース。

iOS は `candidate` を `PhotoFoodEstimate` にデコードしてレビュー画面へ渡す。失敗は
`PhotoEstimationOutcome.failure(message:)` にマップする（既存の `PhotoEstimationRunner`
で吸収）。

---

## 9. プライバシーとログ（Privacy and Logging）

- **生写真はデフォルトで永続化しない。** リクエスト処理後に破棄。
- **画像バイトをログに残さない。** リクエスト / レスポンスログから明示的に除外する。
- **食事ペイロードを個人的に機微な文脈と一緒にログしない。** 体重・位置・健康履歴
  などをエンドポイントに送らない（§7 で禁止済み）。
- **メタデータのスクラブ** — EXIF（GPS、機種、撮影日時など）は可能な限り iOS 側で
  剥がしてから送信する（PR 60 のペイロード準備ヘルパーで実施）。
- **保持ポリシーは production 前に明文化** — もし障害解析等で短期保持する場合でも、
  保持期間（例: 24 時間）・アクセス制御・自動削除を仕様化する。
- **ユーザ向けコピーは推定の不確実性を明示する** — 既存のレビュー画面文言
  「これは実 AI ではなく…」を、実 AI 統合後は「AI 推定は誤っている可能性があります。
  保存前に確認してください」相当に置き換える。

---

## 10. レート制限とコスト管理（Rate Limit and Cost Control）

- **クライアント側の二重タップ抑止**は実装済み（PR #53 の `EstimationPhase`）。
- **バックエンド側でレート制限を強制する** — トークン単位 / 端末単位 / グローバルの
  3 段。超過は 429 + `Retry-After`。
- **クォータ超過時の応答** — `error.code: quota_exceeded`。iOS は失敗メッセージで
  「今は混雑しています」相当を表示し、自動リトライしない。
- **リトライポリシー** — ユーザーの明示「再試行」のみ。指数バックオフによる自動
  再送はしない（コスト直結のため）。
- **タイムアウト** — クライアント側で 30s 程度の上限、サーバ側でも独立に上限。
- **フォールバック** — 失敗時は手動 / バーコード / OCR を案内（既存の UI 構造を
  利用）。

---

## 11. エラー状態（Error States）

iOS 側はすべて `PhotoEstimationOutcome.failure(message:)` に集約し、ユーザーには
再試行 + 手動入力フォールバックを提示する。

| 状況 | HTTP / error.code | iOS 表示 |
|---|---|---|
| ネットワーク失敗 | n/a | 「通信状況を確認してください」 + 再試行 |
| バックエンド到達不可 | 503 / `provider_unavailable` | 「サービスが一時的に利用できません」+ 再試行 |
| プロバイダタイムアウト | 504 / `provider_unavailable` | 同上 |
| クォータ超過 | 429 / `quota_exceeded` | 「今は混雑しています」+ 後で再試行 |
| 認証失敗 | 401 / `unauthenticated` | トークン再取得を試み、失敗なら案内 |
| 非対応 / 不正な画像 | 400 / `unsupported_image` | 「この画像は処理できません」+ 別画像 / 手動 |
| 料理を認識できない | 200 / 422 / `no_food_detected` | 「料理を認識できませんでした」+ 手動 |
| カロリー / タンパク質欠落 | 200（一部欠落） | レビュー画面で手動入力。確定ボタンは既存ロジックでガード |
| 不正 / 危険な応答 | 200 だがバリデーション失敗 | 「読み取れませんでした」+ 手動 |
| レスポンス形式が壊れている | 200 + 不正 JSON | 同上 |

すべて **MealEntry を作らず、DayLog を更新しない**。

---

## 12. テスト戦略（Testing Strategy）

- **iOS ユニットテスト** — フィクスチャ / モックを使用。スタブ `URLProtocol` で
  正規化レスポンスを返し、デコード → `PhotoFoodEstimate` 経路と失敗マッピングを
  網羅する（既存の `OpenFoodFactsProductLookupService` テスト方針と同型）。
- **バックエンドテスト** — モックされたプロバイダ応答で正規化を検証する（PR 63 以降）。
- **既定の CI ではライブ AI を叩かない。** 接続テストは opt-in でのみ実行する。
- **保存フローテスト**（`PhotoEstimateReviewSaveTests`）は既存のまま — 確認前に
  DayLog が変わらないこと、確定で `.confirmed .ai` 保存 + 同期されることを保証
  する。実プロバイダ統合後も `ConfirmedMealEntryFactory` 経由は変わらない。
- **セキュリティ grep チェック** — 各 PR の差分に `api_key` / `Bearer …` / `sk-…` /
  `wrangler` / `.workers.dev` / 本番ホストが現れないことを確認する。

---

## 13. 将来の PR 順序（Future PR Sequence）

[`photo-ai-provider-strategy.md`](photo-ai-provider-strategy.md) §11 を、実装の単位に
合わせて具体化したもの。各 PR は前段の境界を壊さない。

| PR | 内容 | 実 AI / ネットワーク |
|---|---|---|
| **PR 59** | 本ドキュメント（バックエンド / トークン エンドポイント仕様の確定）＝本 PR | なし |
| **PR 60** | iOS の画像ペイロード準備ヘルパー（リサイズ / 再エンコード / EXIF 剥がし）。**端末内のみ**、送信なし | なし |
| **PR 61** | モックのエンドポイントクライアントプロトコル。スタブ実装のみ、実ネットワークなし | モックのみ |
| **PR 62** | バックエンド / Worker のスケルトン、または短期トークン エンドポイント仕様の精緻化（ドキュメント / 別チーム / 別レビュー） | サーバ側設計 |
| **PR 63** | バックエンド proxy / トークン実装（**フェイクプロバイダ**で疎通） | サーバ側のみ |
| **PR 64** | バックエンド側で実 AI プロバイダ統合 | サーバ側のみ |
| **PR 65** | iOS の実プロバイダクライアントを `PhotoFoodEstimating` の実装として追加。設定トグルでガード、既定 OFF | あり（opt-in 時のみ） |
| **PR 66** | プライバシー / コスト / レート制限 / QA ハードニング | — |

`server/` に触れるのは PR 62–64 のみで、本ドキュメントはその判断材料を与えるだけ
（実装・URL・キーは含めない）。

---

## 14. 明示的な非ゴール（Non-Goals）

本 PR および本仕様は次を**やらない / 認めない**:

- 実 AI プロバイダの実装。
- バックエンド / Worker の実装。
- 本番エンドポイント URL の記載。
- iOS クライアントへの API キー埋め込み。
- 写真の送信 / アップロード（iOS への追加実装）。
- SwiftData スキーマの変更。
- カロリーの自動コミット（確認なしの DayLog 加算）。
- 医療・栄養学的な診断やアドバイス。
- iOS への新規ネットワーキングコード。

---

## 15. 実装着手前の受け入れ基準（Acceptance Criteria）

PR 60 以降に進んでよいのは、次がすべて満たされたとき:

- [ ] 本エンドポイント戦略（§4–§8）が承認されている。
- [ ] クレデンシャル保管計画（[`credential-strategy.md`](credential-strategy.md)
      案 B / [`import-token-endpoint-spec.md`](import-token-endpoint-spec.md) と
      整合）が承認されている。
- [ ] クライアント側にプロバイダ秘密が存在しない設計になっている。
- [ ] §7 / §8 のリクエスト / レスポンス形が合意されている。
- [ ] 写真 / ログの保持・破棄ポリシー（§9）が合意されている。
- [ ] ユーザ向けコピー（推定の不確実性を明示）の方針が承認されている。
- [ ] テストが既定でモックを使う（ライブ AI を叩かない）方針が合意されている。
- [ ] 手動 / バーコード / OCR のフォールバックが引き続き利用できることが確認されている。

1 つでも未達なら、PR 60 以降は着手しない。

---

## 関連ドキュメント

- [`photo-ai-provider-strategy.md`](photo-ai-provider-strategy.md) — 写真 AI の
  プロバイダ方式（案 A〜D）比較と推奨。本ドキュメントは案 B の実装可能仕様。
- [`photo-food-estimation-flow.md`](photo-food-estimation-flow.md) — 写真推定の
  アプリ内フロー全体設計。本ドキュメントはそのプロバイダ境界を仕様化する。
- [`credential-strategy.md`](credential-strategy.md) — クライアントに長期キーを
  置かない方針の根拠。§3 / §5 の鉄則と整合。
- [`import-token-endpoint-spec.md`](import-token-endpoint-spec.md) — 短期トークン
  エンドポイントの先行例。写真 AI 用のトークン取得もこの形に準じる。
- [`ai-privacy-and-safety.md`](ai-privacy-and-safety.md) — AI / 食事推定の安全境界
  の鉄則。§3 / §9 はこれを写真 AI バックエンドに適用したもの。
