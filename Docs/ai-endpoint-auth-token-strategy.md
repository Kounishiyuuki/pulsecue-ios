# AI Endpoint Auth & Typed Token Strategy（AI エンドポイント認証・トークン戦略）

> **本ドキュメントの目的**: 将来 iOS から本番の AI トレーニングプラン
> エンドポイント（`POST /api/ai/training-plan`）を呼ぶ際の**認証方式**と
> **型付きトークンの扱い**を、実装の **前に** 確定させる。
> **本 PR はドキュメントのみ。** 認証実装・トークン発行/検証・ネットワーク・
> 実 AI 連携・API キー・実 URL・スキーマ変更・アプリ挙動変更は一切行わない。
>
> 採用方針の背景は [`credential-strategy.md`](credential-strategy.md) 案 B、
> トークン発行は [`import-token-endpoint-spec.md`](import-token-endpoint-spec.md)
> と同型、エンドポイント契約は
> [`ai-training-plan-proxy-endpoint-spec.md`](ai-training-plan-proxy-endpoint-spec.md)
> §4/§7 を参照。プライバシー鉄則は
> [`ai-privacy-and-safety.md`](ai-privacy-and-safety.md)。
>
> 対象読者: AI エンドポイント認証を担当する後続 PR の開発者。
> 作成日: 2026-06-08。

---

## 1. 目的（Purpose）

- iOS が将来 **バックエンド AI エンドポイント**に対してどう認証するかを定義する。
- **プロバイダ API キーはサーバ側にのみ**置き、iOS には決して降ろさない
  （[`ai-training-plan-provider-architecture.md`](ai-training-plan-provider-architecture.md) §3/§5、案 B）。
- iOS が持つのは「アプリ → 自社バックエンド」用の**短期・端末スコープトークン**だけ。
  これはプロバイダキーとは**別物**。
- **本 PR では実装しない。** 本戦略が承認されてから、サーバ契約 → モック検証 →
  iOS 型付きエラー対応、の順で進める（§11）。

---

## 2. 現状（Current State）

| 項目 | 状態 |
|---|---|
| 既定のアプリ挙動 | **mock/local のまま**（`MockAITrainingPlanProvider`） |
| DEBUG QA エンドポイント | ローカル loopback のみ（`#if DEBUG` の `debugLocalMock` = `http://127.0.0.1:8787/`） |
| 本番 AI エンドポイント | **未有効化**（本番 URL はリポジトリに存在しない） |
| AI エンドポイント用トークン永続化 | **無し**（Keychain/UserDefaults/Info.plist いずれにも保存していない） |
| iOS の認証ヘッダ | `AITrainingPlanEndpointClient` が、注入された `tokenProvider` が**非空トークンを返したときだけ** `Authorization: Bearer` を付与（PR #80） |
| サーバ側トークン検証 | **未実装**（モックエンドポイントは dev/mock 専用で ungated） |

iOS 側はすでに「注入された設定でのみ endpoint を構築する」境界
（`AITrainingPlanEndpointConfiguration` / `AITrainingPlanProviderFactory`、PR #81/#82）と、
loading/error/retry/cancel のハードニング（`AIPlanGenerationPhase` / `AIPlanGenerationError`、PR #83）
を備えている。本戦略はこの上に**認証だけ**を将来足すための設計である。

---

## 3. トークンモデル（Token Model）

将来の本番トークンは以下を満たす。`import-token-endpoint-spec.md` §4 と同型。

- **短期（short-lived）**。TTL は MVP で上限 24 時間、本番リリース時に再検討。
- **端末スコープ（device-scoped）**。発行は `deviceId` に紐付け、サーバ側でレート制限する。
- **スコープ限定**: `scope: ai:training-plan`。他エンドポイントには使えない。
- **用途は「アプリ → バックエンド」のみ**。iOS はこのトークンでのみ自社バックエンドを呼ぶ。
- **プロバイダ API キーではない**。プロバイダキーはサーバ secret としてのみ存在し、
  トークンとは必ず別文字列。iOS には一切降りてこない。
- **期限切れ後は自動で無効**。サーバが `expiresAt` を強制チェックする。

発行エンドポイント自体の仕様（リクエスト/レスポンス形・App Attest）は
[`import-token-endpoint-spec.md`](import-token-endpoint-spec.md) を
プラン生成スコープ向けに流用して別 PR で具体化する（本 PR では確定しない）。

---

## 4. トークン境界（Token Boundaries）

**後続のすべての実装 PR はこれを守る。**

- **iOS にプロバイダ API キーを置かない。** 例外なし。
- **トークンをソースコードに書かない。**
- **トークンを Info.plist に置かない。**
- **トークンを xcconfig / Build Settings に置かない。**
- **トークンを `UserDefaults` に置かない**（将来明示的に承認された場合を除く）。
- **トークンをログ・分析・クラッシュレポート・スクリーンショット・ドキュメントに残さない。**
- **Keychain 保存は未実装**。採否は将来の決定事項
  （`import-token-endpoint-spec.md` は import 用に Keychain を想定。AI 用も同型になりうるが、
  本 PR では決めない）。
- 監査・診断に残してよいのは `deviceId`（または hash）+ `appVersion` + timestamp +
  結果コードのみ。**トークン値・相談文・生成詳細は載せない。**

---

## 5. リクエスト挙動（Request Behavior）

現行の `AITrainingPlanEndpointClient` 挙動を踏襲する（PR #80）。

- **`Authorization` ヘッダは、注入された `tokenProvider` が非空トークンを返したときだけ**付与する。
  `tokenProvider` が `nil` を返す / 空文字なら **ヘッダを付けない**。
- **トークンが無ければ Authorization ヘッダ無し**で送る（モック/未認証エンドポイント向け挙動を保持）。
- **`unauthorized` 後のリトライはループガードする。** トークン再取得 → 同一リクエスト再送は
  **1 度だけ**。2 度目も失敗ならエラー UI へ（`import-token-endpoint-spec.md` §7.3 と同型）。
- **暗黙のバックグラウンド生成をしない。** 推論はユーザーの明示操作 1 回につき 1 回
  （[`ai-training-plan-proxy-endpoint-spec.md`](ai-training-plan-proxy-endpoint-spec.md) §8/§9）。
- `tokenProvider` は `async` クロージャ（`(@Sendable () async -> String?)?`）のまま。
  必要時にトークンを mint/refresh でき、クライアントは何も永続化しない。

---

## 6. エラー挙動（Error Behavior）

サーバは既存のエラー envelope を返す（[proxy spec](ai-training-plan-proxy-endpoint-spec.md) §7）:

```json
{ "error": { "code": "<machine-readable code>", "message": "<人間可読の説明>" } }
```

認証導入に伴い、proxy spec §7 の表に **`token_expired` / `invalid_scope`** を加えた
（PR #89）。サーバ側の完全な認証コントラクト（必須ヘッダ・トークン要件・envelope の
`requestId`・ステータス/コード表・安全規則・テストマトリクス）は
[proxy spec](ai-training-plan-proxy-endpoint-spec.md) **§4.1–§4.9** を参照。
iOS は server code を型付きクライアントエラーへ、さらに
`AIPlanGenerationError`（PR #83）のユーザー向けカテゴリへ畳み込む。

| server code | HTTP | 意味 | iOS の扱い（推奨） | ユーザー向けカテゴリ |
|---|---|---|---|---|
| `unauthorized` | 401 | トークン欠落/無効 | トークン再取得を **1 度**試行 → 失敗ならエラー UI | unauthorized |
| `token_expired` | 401 | トークン期限切れ | 同上（ループガード付き 1 回再取得） | unauthorized |
| `invalid_scope` | 403 | スコープ不一致（`ai:training-plan` 以外） | 再取得せずエラー UI。バグの可能性として扱う | unauthorized |
| `rate_limited` | 429 | 頻度上限超過 | 「時間をおいて再試行」+ ルールベース誘導 | rateLimited |
| `quota_exceeded` | 429 | 生成クォータ超過 | 「現在利用できません」+ ルールベース/手動 | rateLimited |
| `timeout` | 504 | プロバイダ応答タイムアウト | 「時間をおいて再試行」。自動再送しない | timeout |
| `provider_unavailable` | 502/503 | プロバイダ障害/到達不可 | 同上 + ルールベースフォールバック | providerUnavailable |
| `invalid_response` | 502 | プロバイダ出力がスキーマ不適合 | 「うまく作成できませんでした」+ 再試行/ルールベース | invalidResponse |
| `unknown` | 500 | 想定外のサーバ失敗 | 汎用エラー + 再試行/ルールベース | unknown |

> 注: 現行 proxy spec の `invalid_provider_response` は iOS 側で `invalidResponse`
> カテゴリへ畳み込まれる（`AIPlanGenerationError.from(_:)`）。`token_expired` /
> `invalid_scope` は**いずれも `unauthorized` 系として安全に提示**し、生のスコープ名や
> トークン詳細は表示しない。

**どのエラーでも:**

- **`Routine` / `Step` を作らない**（§9）。
- **mock / `RuleBasedWeeklyPlanGenerator` / 手動編集**へ着地できる導線を残す。
- `message` にトークン値・内部スタックトレース・他ユーザー情報を含めない。

---

## 7. プライバシー / ロギング（Privacy & Logging）

[`ai-privacy-and-safety.md`](ai-privacy-and-safety.md) と
[proxy spec](ai-training-plan-proxy-endpoint-spec.md) §10 に従う。

- **トークンをログに残さない**（サーバログ・iOS `OSLog`/`print`・クラッシュ・分析の
  いずれにも）。`URLRequest` のヘッダを丸ごと出力するパターンに特に注意。
- **`userMessage`（相談文）をログに残さない。**
- **生のプロバイダレスポンスをログに残さない。**
- **生成ワークアウト詳細を個人的文脈（体重・健康履歴・位置等）と一緒にログしない。**
- **すべての診断で `Authorization` ヘッダを redact する。**

---

## 8. サーバの責務（Server Responsibilities）

- **トークンを検証する**（署名/有効性、`expiresAt`）。
- **スコープを検証する**（`ai:training-plan` のみ許可、それ以外は `invalid_scope`）。
- **クォータ / レート制限を強制する**（per-token / per-device、proxy spec §9）。
- **プロバイダ API キーをサーバ側に保持する**。iOS へ渡さない。
- **プロバイダキーや内部プロバイダエラーを iOS に返さない。** 返すのは
  §6 の machine-readable code と安全な `message` のみ。

---

## 9. iOS の責務（iOS Responsibilities）

- **`AITrainingPlanEndpointClient` は注入された設定経由でのみ使う**
  （`AITrainingPlanEndpointConfiguration`、PR #81/#82）。
- **`tokenProvider` は注入のまま**。クライアントはトークンを永続化しない。
- **`AITrainingPlanNormalizer` が最後の門番**。生レスポンスは必ずここを通す。
- **保存は明示確定のみ**（「この候補を保存」）。`modelContext.insert` は既存の保存パスのみ。
- **認証失敗で `Routine` / `Step` を作らない。** 生成・表示・キャンセル・失敗・再試行の
  いずれでも保存は発生しない。
- 既定 UI は mock のまま。endpoint への配線は dev/QA 専用（`#if DEBUG`）を維持する。

---

## 10. テスト戦略（Test Strategy）

- **トークン無しのヘッダ挙動**のユニットテスト（Authorization 不在）。← 既存
  （`AITrainingPlanEndpointClientTests`）で担保済み。
- **注入トークンありのヘッダ挙動**のユニットテスト（`Authorization: Bearer <fake>`）。← 既存。
- **`unauthorized` マッピング**テスト。← 既存。
- **`invalid_scope` / `token_expired` マッピング**テストは**サーバ契約が定まってから**追加。
- **ライブプロバイダを叩くテストをしない。**
- **テストに実トークンを書かない**（フェイク値のみ。例: `"short-lived-token"`）。
- ネットワーク層は `URLProtocol` スタブで差し替え（既存方針）。

---

## 11. 後続 PR の順序（Future PR Sequence）

各 PR は前段の境界を壊さないこと。`server/` に触れるのはサーバ PR のみ。

| 順 | 内容 | ネットワーク / 実 AI |
|---|---|---|
| **PR #88（本 PR）** | 本認証・トークン戦略（ドキュメントのみ） | なし |
| **PR #89** | サーバ auth 契約のドキュメント / proxy spec 更新（`token_expired` / `invalid_scope` 追記、§4.1–§4.9） | なし |
| 次 | サーバ側 **モックトークン検証**（dev 専用・実プロバイダなし） | サーバのみ |
| 次 | iOS **型付き auth エラーマッピング**（`token_expired` / `invalid_scope` → `unauthorized` 系） | なし（クライアント） |
| 次 | **フェイクトークン**での dev QA | ローカルのみ |
| 次 | サーバ **実プロバイダアダプタ**（auth 通過後のみ） | サーバのみ・実 AI |
| 次 | **本番有効化**（プライバシー・auth・コスト・opt-in 承認後に別途） | あり（承認時のみ） |

---

## 12. 非ゴール（Non-Goals）

本 PR は次を**やらない / 認めない**:

- トークン実装。
- 認証ミドルウェア実装。
- 実 AI / OpenAI 連携。
- プロバイダ SDK の追加。
- 本番 URL / Worker URL / `*.workers.dev` の記載。
- API キーの取り扱い。
- トークンの永続化（Keychain/UserDefaults/Info.plist/xcconfig/ソース）。
- ユーザー向けプロバイダ選択トグル / フィーチャーフラグ UI。
- SwiftData スキーマ・`@Model`・保存挙動の変更。
- `server/` の変更。

---

## 関連ドキュメント

- [`ai-training-plan-provider-architecture.md`](ai-training-plan-provider-architecture.md)
  — プロバイダ方式（案 B）とクレデンシャル方針。
- [`ai-training-plan-proxy-endpoint-spec.md`](ai-training-plan-proxy-endpoint-spec.md)
  — エンドポイント契約（§4 認証・§7 エラー）。本戦略はその認証章を詳細化したもの。
- [`ai-endpoint-integration-readiness.md`](ai-endpoint-integration-readiness.md)
  — ローカル QA とレディネス。
- [`credential-strategy.md`](credential-strategy.md) — 長期キーを端末に置かない方針（案 B）。
- [`import-token-endpoint-spec.md`](import-token-endpoint-spec.md) — 短期デバイス
  スコープトークン発行の同型仕様。AI 用トークンはこれを流用する。
- [`photo-ai-backend-token-spec.md`](photo-ai-backend-token-spec.md) — 写真 AI 向けの
  同型バックエンド / トークン仕様。
- [`ai-privacy-and-safety.md`](ai-privacy-and-safety.md) — AI 安全境界の鉄則。

---

> **更新ルール**: 本戦略は §3 / §6 の draft 部分が後続 PR（サーバ auth 契約）で
> 固まったら必要に応じて改訂する。大きな変更時は末尾に変更履歴を追記して理由を残す。
