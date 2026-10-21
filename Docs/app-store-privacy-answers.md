# App Privacy 回答ドラフト（App Store Connect）

PulseCue v1.0 の App Store Connect「App のプライバシー」質問への回答ドラフト。**リポジトリ実測**を基にするが、リポジトリ調査は全ランタイム/組織的挙動の証明ではない。法的コンプライアンスの主張はしない。

- 再監査日: 2026-10-22 / 対象: `main`（PR #202 merge 後）
- 前提: v1.0 は **PulseCue アカウント（server-backed）込み**で出す。`PulseCueAPIBaseURL` / `GIDServerClientID` を本番値にした build を提出する。
- `PrivacyInfo.xcprivacy` の `NSPrivacyCollectedDataTypes` に Email Address / User ID / Other Data Types（端末名）を宣言済み（本書 §3 と整合）。OpenFoodFacts 照会の扱いは §6 の **MANUAL GATE** で未確定。

判定: **RV**=リポジトリ検証済み / **手動**=App Store Connect で人手回答 / **要確認**=ユーザー確認要 / **不収集**=意図的に収集しない / **ローカル**=端末内のみ。

> 旧版（2026-07-29）の「収集なし（Data Not Collected）」「サーバアカウントなし」は**現在は誤り**。アカウント API が設定された build ではサーバにアカウントを作る。

---

## 1. サマリー（現状の実挙動）

- トラッキング: **なし**（`NSPrivacyTracking = false`・IDFA/ATT なし）。**RV**
- 解析 / 広告 / クラッシュ収集 SDK: **なし**。第三者 SDK は GoogleSignIn 7.1.0（+ AppAuth / GTMAppAuth / GTMSessionFetcher）のみ。**RV**（`Package.resolved`）
- PulseCue API へ送るもの（サインイン時のみ）: Apple identity token / authorization code / nonce、または Google ID token、端末名（`UIDevice.current.name`）。サーバはここからプロバイダ subject・メールアドレス（取得できる場合）・PulseCue user ID・セッション（`sessions.device_name` に端末名）を保存する。**RV**（`Pulse Cue/App/Pulse_CueApp.swift`, `Pulse Cue/Auth/ServerAccountStore.swift`, `server/src/api/routes/authApple.ts` / `authGoogle.ts`, `server/src/api/db/sessions.ts`, `server/migrations/0001_user_auth_foundation.sql`）
- ワークアウト / 身体 / 食事 / 睡眠ログ: **端末内 SwiftData のみ**。iOS client は `/v1/sync/*` を呼ばない（server 側に workout sync API はあるが v1.0 の app からは未使用）。**RV**（app が呼ぶ path は `v1/auth/apple`, `v1/auth/google`, `v1/me`, `v1/auth/logout` のみ）
- HealthKit: 体重・睡眠の**読み取りのみ**（入力補助）。端末外へ送らない。**RV**（`HealthKitClient.swift`）

## 2. 端末外へ出るデータ

| 通信 | 内容 | 個人紐付け | 目的 |
|---|---|---|---|
| PulseCue API（サインイン/`/v1/me`/ログアウト/削除） | プロバイダ token（サーバで検証）、端末名、セッショントークン | あり（PulseCue user ID） | アカウント・認証 |
| Sign in with Apple / Google | 各社の認証フロー | 各社 | 認証 |
| OpenFoodFacts 照会 | バーコード値（URL path）、固定 User-Agent `PulseCue/1.0 (iOS; nutrition barcode lookup)`、`URLSession.shared` の標準ヘッダ（Accept-Language 等）、通信上必然の IP アドレス。アカウント ID / メール / PulseCue user ID / 位置情報は送らない | PulseCue 側では紐付けない | 食品情報の参照（公開API・キー不要）。保持の扱いは §6 |
| 近くのジム検索 | MapKit（Apple）経由。PulseCue サーバへは送らない | なし | ジム候補検索 |

## 3. App Privacy 質問への回答ドラフト

**「データを収集しますか？」→ はい。**

| データタイプ | 収集 | ユーザーに紐付け | トラッキング | 目的 |
|---|---|---|---|---|
| 連絡先情報 > メールアドレス | はい（Apple/Google が提供した場合。Apple の非公開リレーも含む） | はい | いいえ | App の機能 |
| 識別子 > ユーザ ID | はい（PulseCue user ID、プロバイダ subject） | はい | いいえ | App の機能 |
| その他のデータ > その他のデータタイプ | はい（端末名。サインイン時に送信し `sessions.device_name` に保存。アカウント削除で cascade 削除） | はい | いいえ | App の機能 |
| 識別子 > デバイス ID | いいえ（端末名は一意 ID ではない。下記注） | — | — | — |
| 名前 | いいえ（iOS は表示名をサーバへ送らない） | — | — | — |
| フィットネス / 健康 | いいえ（端末内のみ・同期なし） | — | — | — |
| 位置情報 | いいえ（MapKit 検索のみ・PulseCue へ送らない）※ | — | — | — |
| ユーザーコンテンツ | いいえ（端末内のみ） | — | — | — |
| 購入 / 金融 / 連絡先 / 閲覧履歴 / 検索履歴 | いいえ | — | — | — |
| 使用状況データ / 診断 | PulseCue 自身は収集しない（独自の解析・クラッシュ収集なし）。OpenFoodFacts 照会の扱いは §6 で**未確定** | — | — | — |

**端末名の分類根拠**: deployment target は iOS 17.0、`com.apple.developer.device-information.user-assigned-device-name` entitlement なし → `UIDevice.current.name` は "iPhone" 等の汎用名を返す（ユーザー名を含まない）。Apple 定義の Device ID（"advertising identifier, or other device-level ID"）にも Name にも当たらないが、サーバに保存されアカウントに紐付くため「その他のデータタイプ」（"Any other data types not mentioned"）として申告する。

※ 位置情報: MapKit（Apple のシステムフレームワーク）による検索のみで PulseCue サーバへ送らず、追加した第三者コードもないため「収集なし」と判断（**前提**）。

## 4. アカウント削除（Guideline 5.1.1(v)）

- アプリ内で削除可能: 設定 → アカウント → 「アカウントを削除」→ `DELETE /v1/me`。**RV**（`ServerAccountSettingsSection.swift`）
- サーバ側: ユーザー行・identity・セッションを cascade 削除。Apple のトークン revoke は Cron で再試行（`202` = 削除受付済み・revoke 待ち）。**RV**（`server/src/api/auth/accountDeletionService.ts`）
- 削除後は端末内のアカウント関連ローカルデータを cleanup（`AccountLocalDataCleanup.swift`）。

## 5. 未検証・注意

- 本番 API に対するサインイン/削除の実機確認は**手動**（`testflight-checklist.md` の MANUAL GATE）。
- 本書はリポジトリ静的調査に基づき、組織的データ運用の証明ではない。プライバシーポリシー URL（本番）は提出前に用意すること（**手動**）。

## 6. MANUAL GATE: OpenFoodFacts 照会（未確定・提出前に決定必須）

**「OpenFoodFacts 側が保存/利用しないため収集なし」という旧判断は根拠がなく撤回した。** 現時点で最終回答は確定していない。

確認済みの事実:
- 送信内容は §2 の表のとおり（`Pulse Cue/Services/OpenFoodFactsProductLookupService.swift`。`GET https://world.openfoodfacts.org/api/v0/product/<barcode>.json?fields=…`）。**RV**
- OpenFoodFacts privacy policy（2026-06 更新版、`https://world.openfoodfacts.org/privacy`）: ログインしない visitor について「IP, Log」を「Security, technical analyses, Popularity measurement」目的で **3 年**保持と記載。照会されたバーコードがログに残るかは明記なし。
- Apple App Privacy Details: "Collect" = 開発者および/または third-party partners が、リクエストのリアルタイム処理に必要な期間を超えてアクセスできる形で端末外へ送ること。"Third-party partners" = "analytics tools, advertising networks, third-party SDKs, or other external vendors whose code you've added to your app"。IP を保存する場合は用途に応じて location / device ID / diagnostics 等で申告。

未解決事項:
1. OpenFoodFacts（SDK なし・アプリから直接 HTTPS 呼び出しする公開 API）が Apple のいう third-party partner に当たるか。定義文言（"whose code you've added"）からは断定できない。
2. 当たる場合のデータタイプ。候補: バーコード値 → 使用状況データ（製品の操作 / その他の使用状況データ）または検索履歴。IP（OFF 側の用途はセキュリティ・技術分析・人気度測定）→ 位置情報としての用途はなく、該当カテゴリ要判断。いずれも PulseCue のアカウントとは紐付かない（ユーザーに紐付け: いいえ）、トラッキング: いいえ。
3. 申告する場合は `PrivacyInfo.xcprivacy` にも同じエントリを追加して整合させる（現状は未追加）。

提出前に提出者が行うこと（**手動**）:
- [ ] 上記 1・2 を Apple の現行定義で判断（必要なら Apple Developer Support に照会）し、App Store Connect 回答と `PrivacyInfo.xcprivacy` を同じ内容に揃える。
- [ ] 判断と根拠を本節に記録してから提出する。迷う場合は申告する側（収集あり・紐付けなし・トラッキングなし・App の機能）に倒す。
