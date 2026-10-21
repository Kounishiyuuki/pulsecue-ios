# App Privacy 回答ドラフト（App Store Connect）

PulseCue v1.0 の App Store Connect「App のプライバシー」質問への回答ドラフト。**リポジトリ実測**を基にするが、リポジトリ調査は全ランタイム/組織的挙動の証明ではない。法的コンプライアンスの主張はしない。

- 再監査日: 2026-10-22 / 対象: `main`（PR #202 merge 後）
- 前提: v1.0 は **PulseCue アカウント（server-backed）込み**で出す。`PulseCueAPIBaseURL` / `GIDServerClientID` を本番値にした build を提出する。
- `PrivacyInfo.xcprivacy` の `NSPrivacyCollectedDataTypes` に Email Address / User ID を宣言済み（本書と整合）。

判定: **RV**=リポジトリ検証済み / **手動**=App Store Connect で人手回答 / **要確認**=ユーザー確認要 / **不収集**=意図的に収集しない / **ローカル**=端末内のみ。

> 旧版（2026-07-29）の「収集なし（Data Not Collected）」「サーバアカウントなし」は**現在は誤り**。アカウント API が設定された build ではサーバにアカウントを作る。

---

## 1. サマリー（現状の実挙動）

- トラッキング: **なし**（`NSPrivacyTracking = false`・IDFA/ATT なし）。**RV**
- 解析 / 広告 / クラッシュ収集 SDK: **なし**。第三者 SDK は GoogleSignIn 7.1.0（+ AppAuth / GTMAppAuth / GTMSessionFetcher）のみ。**RV**（`Package.resolved`）
- PulseCue API へ送るもの（サインイン時のみ）: Apple identity token / authorization code / nonce、または Google ID token、端末名（`UIDevice.current.name`）。サーバはここからプロバイダ subject・メールアドレス（取得できる場合）・PulseCue user ID・セッションを保存する。**RV**（`Pulse Cue/Auth/PulseCueAccountAPI.swift`, `server/migrations/0001_user_auth_foundation.sql`）
- ワークアウト / 身体 / 食事 / 睡眠ログ: **端末内 SwiftData のみ**。iOS client は `/v1/sync/*` を呼ばない（server 側に workout sync API はあるが v1.0 の app からは未使用）。**RV**（app が呼ぶ path は `v1/auth/apple`, `v1/auth/google`, `v1/me`, `v1/auth/logout` のみ）
- HealthKit: 体重・睡眠の**読み取りのみ**（入力補助）。端末外へ送らない。**RV**（`HealthKitClient.swift`）

## 2. 端末外へ出るデータ

| 通信 | 内容 | 個人紐付け | 目的 |
|---|---|---|---|
| PulseCue API（サインイン/`/v1/me`/ログアウト/削除） | プロバイダ token（サーバで検証）、端末名、セッショントークン | あり（PulseCue user ID） | アカウント・認証 |
| Sign in with Apple / Google | 各社の認証フロー | 各社 | 認証 |
| OpenFoodFacts 照会 | スキャンした食品バーコード値のみ（+ User-Agent） | なし | 食品情報の参照（公開API・キー不要） |
| 近くのジム検索 | MapKit（Apple）経由。PulseCue サーバへは送らない | なし | ジム候補検索 |

## 3. App Privacy 質問への回答ドラフト

**「データを収集しますか？」→ はい。**

| データタイプ | 収集 | ユーザーに紐付け | トラッキング | 目的 |
|---|---|---|---|---|
| 連絡先情報 > メールアドレス | はい（Apple/Google が提供した場合。Apple の非公開リレーも含む） | はい | いいえ | App の機能 |
| 識別子 > ユーザ ID | はい（PulseCue user ID、プロバイダ subject） | はい | いいえ | App の機能 |
| 名前 | いいえ（iOS は表示名をサーバへ送らない） | — | — | — |
| フィットネス / 健康 | いいえ（端末内のみ・同期なし） | — | — | — |
| 位置情報 | いいえ（MapKit 検索のみ・PulseCue へ送らない）※ | — | — | — |
| ユーザーコンテンツ | いいえ（端末内のみ） | — | — | — |
| 購入 / 金融 / 連絡先 / 閲覧履歴 / 検索履歴 | いいえ | — | — | — |
| 使用状況データ / 診断 | いいえ（独自の解析・クラッシュ収集なし） | — | — | — |

※ 位置情報と OpenFoodFacts のバーコードは開発者・第三者パートナーが保存/利用しないため「収集なし」と判断（**前提**。Apple の定義解釈は提出者が最終確認）。

## 4. アカウント削除（Guideline 5.1.1(v)）

- アプリ内で削除可能: 設定 → アカウント → 「アカウントを削除」→ `DELETE /v1/me`。**RV**（`ServerAccountSettingsSection.swift`）
- サーバ側: ユーザー行・identity・セッションを cascade 削除。Apple のトークン revoke は Cron で再試行（`202` = 削除受付済み・revoke 待ち）。**RV**（`server/src/api/auth/accountDeletionService.ts`）
- 削除後は端末内のアカウント関連ローカルデータを cleanup（`AccountLocalDataCleanup.swift`）。

## 5. 未検証・注意

- 本番 API に対するサインイン/削除の実機確認は**手動**（`testflight-checklist.md` の MANUAL GATE）。
- 本書はリポジトリ静的調査に基づき、組織的データ運用の証明ではない。プライバシーポリシー URL（本番）は提出前に用意すること（**手動**）。
