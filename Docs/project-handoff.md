# PulseCue 再開用 Handoff

開発を一度キリよく停止し、後から安全に再開するための引き継ぎドキュメント。
現在の完成状態・外部待ち・次フェーズの再開手順をまとめる。

> このドキュメントは状態の記録のみ。**コードは変更していない。**
> secret / token / API key / 本番 URL は記載しない・アプリにも追加しない。
> 対象 main: `37a73f4`（PR #125 マージ時点）。

---

## 1. 現在のステータス要約

- **ローカルファースト MVP:** ほぼ完成。Today / 栄養 / ワークアウト / ルーティン / ランナー /
  履歴 / マシンカタログ / マイジム / 設定が動作。データは端末内（SwiftData / UserDefaults）。
- **TestFlight / コード readiness:** アプリコード側は完了。Bundle ID `com.kounishiyuuki.pulsecue`、
  表示名 `PulseCue`、iPhone-only、Portrait-only、`PrivacyInfo.xcprivacy` 同梱、Sign in with Apple
  entitlement あり。Debug/Release ビルド成功・全テスト green・警告 0・Release leakage clean。
- **Archive ブロッカー:** **外部要因のみ**。Personal/無料 Apple チームは Sign in with Apple を
  サポートせず Archive 署名に失敗する。**有料 Apple Developer Program 加入が必須**（後述 §3）。
- **API 基盤:** `APIIntegrationFoundation`（#122）/ contract+adapter（#123）/ DEBUG ヘルス QA（#124）
  が追加済み。既定は disabled で通信しない。
- **実装済み:** オンボーディング/ゲスト、認証シェル、ログイン UI、Sign in with Apple（実装・実機は
  有料チーム待ち）、Google Sign-In（プレースホルダで無効）、プロフィール/ジム設定、API 基盤、
  DEBUG API ヘルス QA。
- **意図的に未実装:** 実 API 接続、トークン永続化、Keychain、サーバー認証、実 AI/プロバイダ、
  同期/バックアップ、CloudKit。

## 2. 完了済み PR マップ

| PR | 内容 |
|---|---|
| #98–#109 | MVP UI 完成 / ポリッシュフェーズ（Today/栄養/ワークアウト/履歴/設定など） |
| #110 | TestFlight readiness baseline（PrivacyInfo / iPhone-only / Portrait / Bundle ID / 表示名） |
| #111 | オンボーディング + ゲスト開始 |
| #112 | 認証アーキテクチャのシェル（in-memory・非ゲート） |
| #113 | ログイン / 登録 UI |
| #114 | Sign in with Apple 実装（name/email のみ抽出・トークン非取得） |
| #115 | Google Sign-In 実装（プレースホルダで無効・実値で有効化） |
| #116 | プロフィール / ジム設定の土台（既存ストア利用） |
| #117 | TestFlight 外部設定ドキュメント |
| #118 | Swift 並行性警告の整理 |
| #119 | TestFlight QA ドキュメント整備（認証準備フェーズ手動QA） |
| #120 | 認証/アカウント表示文言の整理 |
| #121 | Personal チーム / Developer Program ドキュメント |
| #122 | API 連携基盤（APIIntegrationFoundation・既定 disabled） |
| #123 | API contract と adapter 層（health DTO / APIHealthService） |
| #124 | DEBUG 限定 API ヘルス確認ツール |
| #125 | API 基盤と既存 AI/写真 endpoint provider の関係整理（docs） |

## 3. 外部ブロッカー / 手動アクション

- **有料 Apple Developer Program への加入が必須。** Personal/無料チームは Sign in with Apple を
  サポートせず、`com.apple.developer.applesignin` entitlement を含む Archive 署名に失敗する
  （実測のエラー: "Personal development teams do not support the Sign In with Apple capability."）。
- **App ID:** `com.kounishiyuuki.pulsecue`
- 加入後の手順:
  1. Xcode の Signing で**正式（有料）チーム**を選択。
  2. App ID で `Sign in with Apple` Capability を有効化。
  3. プロビジョニングプロファイルを再生成 / 更新（Automatic Signing）。
  4. Archive 検証を再実行。
- App Store Connect アプリレコード作成、App Privacy 回答、輸出コンプライアンス回答。
- Google OAuth 実値は、TestFlight 前に Google Sign-In を有効化したい場合のみ作成・置換（任意）。

> 詳細手順: `Docs/testflight-external-setup.md`（§1 Apple / §1.1 Personal チーム制約 / §2・§3 Google）、
> `Docs/testflight-readiness-baseline.md` §3.3。

## 4. 現在の安全境界（維持すべき不変条件）

- 本番エンドポイントのデフォルト：**なし**。
- Worker URL のデフォルト挙動：**なし**。
- トークン永続化：**なし**。
- Keychain トークン保存：**なし**。
- UserDefaults の資格情報 / トークン / エンドポイント保存：**なし**。
- `AuthSession` はトークン項目を持たない（provider / displayName / email のみ）。
- Apple の identityToken / authorizationCode / user ID、Google の idToken / accessToken /
  refreshToken / serverAuthCode / user ID は**読まない・保存しない・渡さない・ログしない**。
- API フェーズで SwiftData schema / `@Model` 変更：**なし**。
- サーバー同期：**なし**。CloudKit 同期：**なし**。
- 実 AI / プロバイダ SDK・キー：**なし**。
- AI 明示保存境界（`AITrainingPlanNormalizer` 経由のレビュー/保存）：**不変**。
- 既存アプリフローは実 API に接続していない。

## 5. 推奨再開順序

### A. 目的が TestFlight の場合
1. Apple Developer Program（有料）に加入。
2. Xcode で正式（有料）チームを選択。
3. App ID `com.kounishiyuuki.pulsecue` で Sign in with Apple Capability を有効化。
4. Archive 検証を再実行。
5. App Store Connect レコードを作成。
6. App Privacy / 輸出コンプライアンスを回答。
7. TestFlight ビルドをアップロード。

### B. 目的が実 API フェーズの場合
1. API 基盤ドキュメントを確認（`Docs/api-integration-foundation.md` /
   `Docs/api-contracts-and-adapters.md` / `Docs/api-foundation-and-existing-providers.md`）。
2. 最初に接続する実エンドポイントを 1 つ決める。
3. エンドポイントは明示注入のまま・本番デフォルトを作らない。
4. まず DEBUG / custom config の背後で実エンドポイントを追加する。
5. トークン / ヘッダー戦略は**明示計画後にのみ**追加する。
6. トークン永続化 / Keychain は**別の高リスク PR**として分離する。
7. 既存フローは**一度に 1 つずつ**接続する。

## 6. 推奨ストップライン（ここで安全に停止できる）

- API 基盤が準備済み。
- DEBUG ヘルス QA が存在。
- プロバイダ関係が文書化済み。
- 実 API / トークン / 同期は**未着手**。
- main はクリーン（`37a73f4`・origin/main と同期）。
- **この時点で開発を安全に一時停止できる。**

## 7. 再開プロンプト（再利用可）

```
Read Docs/project-handoff.md and summarize the current PulseCue state,
the next safest step, and any high-risk boundaries before making changes.
```
