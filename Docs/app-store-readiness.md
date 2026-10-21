# App Store / TestFlight リリース準備状況

PulseCue v1.0（ローカルファースト＋任意の PulseCue アカウント）の提出準備監査。**リポジトリを唯一の正**として実測した結果をまとめる。過去レポート（`testflight-readiness-baseline.md` PR #110）を土台に、現時点の実測で更新した差分レポート。

- 監査日: 2026-07-29 / **再監査: 2026-10-22**（PR #202 merge 後の `origin/main` `ee65c51`）
- 再監査で、旧版の「実API/実認証なし」「Collected Data = []」「HealthKit 未統合」は**現在の実装と矛盾**していたため修正した。
- 本レポートは**虚偽のコンプライアンス主張をしない**。各項目は下記バケツで分類する。

判定バケツ: **検証済み**（リポジトリで実測）/ **未検証**（本環境で確認不可）/ **手動要**（App Store Connect等の人手作業）/ **外部ブロッカー**（Apple Developer Program / 外部設定）/ **意図的に保留**（このフェーズでは実装しない）/ **App Storeブロッカー** / **非ブロッキング follow-up**。

---

## 1. 総評

**P0 が残っている**: `Pulse Cue/Info.plist` の `PulseCueAPIBaseURL`（`https://YOUR_PULSECUE_API_HOST`）と `GIDServerClientID`（`YOUR_WEB_SERVER_CLIENT_ID...`）が placeholder のままで、`pulsecue-api` も未 deploy（`server/wrangler.api.jsonc` の D1 `database_id` が placeholder）。この状態の Release build では Apple / Google のサインインボタンは表示されるが、タップすると「この端末ではアカウント機能をまだ利用できません」で終わる（App Review 2.1 リスク）。本番 API の deploy と 2 つの値の設定が提出の前提。

現在の構成: 記録・ルーティン・履歴などは端末内 SwiftData（ローカルファースト・ゲストで全機能利用可）。任意で Apple / Google サインインにより **server-backed の PulseCue アカウント**（session・logout・アプリ内アカウント削除）を作成できる。server には workout sync API・storage quota・rate limit・削除 revoke 再試行の Cron があるが、**v1.0 の iOS client は workout sync を呼ばない**（app が呼ぶのは `v1/auth/apple` `v1/auth/google` `v1/me` `v1/auth/logout` `DELETE v1/me` のみ）。Google コントロールは iOS client ID が設定済みのため Release でも表示される。

## 2. アプリ識別情報（検証済み）

| 項目 | 値 | 根拠 |
|---|---|---|
| Display Name | `PulseCue` | `INFOPLIST_KEY_CFBundleDisplayName` |
| Bundle ID | `com.kounishiyuuki.pulsecue` | `PRODUCT_BUNDLE_IDENTIFIER` |
| Marketing Version | `1.0` | `MARKETING_VERSION` |
| Build | `1` | `CURRENT_PROJECT_VERSION` |
| Deployment Target | iOS 17.0 | `IPHONEOS_DEPLOYMENT_TARGET` |
| Device Family | iPhone のみ（`1`） | `TARGETED_DEVICE_FAMILY` |
| Orientation | Portrait のみ | `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone` |
| Signing | Automatic / Team `58A7G4U27M` | `CODE_SIGN_STYLE` |
| App Icon | 1024 universal + Dark + Tinted | `Pulse Cue/Resources/Assets.xcassets/AppIcon.appiconset` |
| Launch | 生成ローンチスクリーン | `INFOPLIST_KEY_UILaunchScreen_Generation = YES` |

## 3. プライバシーマニフェスト（検証済み）

`Pulse Cue/PrivacyInfo.xcprivacy`:
- `NSPrivacyTracking = false`、`NSPrivacyTrackingDomains = []`
- `NSPrivacyCollectedDataTypes`: **Email Address / User ID**（linked・tracking なし・App Functionality）。2026-10-22 に追加（アカウント作成でサーバに保存されるため）。詳細は `app-store-privacy-answers.md`
- Required Reason API: **UserDefaults `CA92.1`**（`SettingsStore` / `RunnerPersistence` が UserDefaults を使用 → 宣言と実装が一致）

未使用機能の権限は**宣言しない**方針。追加の Required Reason API（file timestamp / system boot time / disk space / active keyboard）はアプリコードで使用が確認できないため未宣言（**検証済み: 該当なし**）。第三者SDK（Google/AppAuth/GTM）は各自の PrivacyInfo を同梱する。

## 4. パーミッション（Info.plist・検証済み）

| キー | 用途 | 実使用 |
|---|---|---|
| `NSCameraUsageDescription` | 食品バーコード読取 | ✅ `BarcodeScannerView` |
| `NSLocationWhenInUseUsageDescription` | 近くのジム検索 | ✅ ジム登録フロー |
| `NSHealthShareUsageDescription` | 体重・睡眠の入力補助（読み取りのみ） | ✅ `HealthKitClient`（`requestAuthorization(toShare: [], read:)`） |

- マイク / 写真 / 連絡先 / モーション / HealthKit 書き込みの権限文字列は**無し**（いずれも未使用のため正しい）。

## 5. Entitlements / Capabilities（検証済み）

`Pulse Cue/Pulse_Cue.entitlements`:
- **有効**: Sign in with Apple（`com.apple.developer.applesignin = [Default]`）→ `LoginView` / `AppleSignInButton` と一致。
- **有効**: HealthKit（`com.apple.developer.healthkit = true`）→ `HealthKitClient` と一致。
- **意図的に不在**: Push / iCloud・CloudKit / App Groups / Keychain sharing / Associated Domains / Background Modes（空だった `UIBackgroundModes` は削除済み）。
- **手動要（MANUAL GATE）**: App ID の Sign in with Apple / HealthKit capability と Distribution provisioning が entitlements と一致していること（Apple Developer Portal で確認）。

## 6. DEBUG / Release 分離（検証済み）

- QA/ビジュアル確認ルート（`GlassUIVisualQARoot`、Form Guide 3D デバッグルート）は `#if DEBUG` かつ launch 引数 `-pulsecue-debug-glass-ui-route` / `-pulsecue-ui-test-form-guide-3d` で駆動。Release では**コンパイル除外**。
- 本PRで **custom-machine UI fixture（`-pulsecue-ui-test-custom-machine-flow`）の挙動を `#if DEBUG` に限定**（従来は Release でも in-memory化・オンボスキップ・`UIテストジム` seed が引数で作動しえた／※launch引数は実機のインストール済みアプリにユーザーが注入できないため実ユーザー到達性はゼロだが、Release完全無効化＝多層防御）。
- Release バイナリ `strings` 実測: `pulsecue-debug-glass-ui-route` / `127.0.0.1:8787` / fake token / `UIテストジム` / `workers.dev` すべて **0件（不在）**。
- 通常起動は `SampleDataSeeder` のみ（QA seed は走らない）。

## 7. シークレット / エンドポイント監査（検証済み）

- ハードコードされた APIキー / 秘密鍵 / bearer トークン / `*.workers.dev` / 本番エンドポイントは**検出なし**。
- ローカル loopback `http://127.0.0.1:8787/` と mock 用 fake token は `#if DEBUG` 限定（Release バイナリに不在を確認）。
- `Authorization: Bearer \(token)` はヘッダ構築コード（`token` は変数、ハードコード値なし）。session token は Keychain（`ServerSessionTokenStore`）。API の base URL は Info.plist から読み、HTTPS 以外・placeholder・資格情報入り URL は拒否する（`PulseCueAPIConfiguration`）。
- OpenFoodFacts への外向き通信（バーコード→食品照会・公開API・キー不要・個人情報送信なし）は存在。App Privacy 回答では「アプリ機能のためのデータ（トラッキングなし）」として整理する（**手動要**）。

## 8. 依存パッケージ（検証済み）

`Package.resolved`: `googlesignin-ios` 7.1.0 / `appauth-ios` 1.7.6 / `gtm-session-fetcher` 3.5.0 / `gtmappauth` 4.1.1（すべて Google Sign-In 用）。`GIDClientID` は実値、`GIDServerClientID` は placeholder（P0）。解析・トラッキングSDKは**なし**。

## 9. 現時点のブロッカー整理

**App Store ブロッカー（提出前に必須・大半が手動）**
- App Store Connect: アプリ名 / 説明 / キーワード / サポートURL / プライバシーポリシーURL（**手動要**）
- スクリーンショット（必須サイズ）（**手動要**）
- App Privacy 質問票の回答（**データ収集あり**: メールアドレス・ユーザ ID。`app-store-privacy-answers.md`）（**手動要**）
- `PulseCueAPIBaseURL` / `GIDServerClientID` の本番値設定と `pulsecue-api` deploy（**P0・手動/外部**）
- プライバシーポリシーにアカウント情報の扱いと削除方法を記載（**手動要**）
- 年齢レーティング設定（**手動要**）
- 実機アーカイブ・署名・アップロード（**未検証**：本環境では実施不可）

**外部ブロッカー**
- 証明書/Distribution プロファイル・App ID capability（Sign in with Apple / HealthKit）の整合（**外部/手動**）
- Google Cloud の Web application OAuth client 作成（`GIDServerClientID` / server `GOOGLE_AUDIENCE`）（**外部**）

**非ブロッキング follow-up**
- レガシー `PulseCue/`（スペース無し）ディレクトリはビルドターゲット外の旧 scaffold（トラッキングされているが未コンパイル）。別PRでの削除を推奨。
- （対応済み）空だった `UIBackgroundModes` は削除。

## 10. 関連ドキュメント

- `Docs/testflight-checklist.md` — 初回 TestFlight ビルドの手順チェックリスト
- `Docs/device-qa-matrix.md` — 実機QAマトリクス（**未実施**フィールドあり）
- `Docs/release-process.md` — アーカイブ/アップロード/ロールバック手順
- `Docs/testflight-readiness-baseline.md` — PR #110 の基盤整備記録（重複回避のため本書は差分/現況に集中）
- `Docs/app-store-listing-draft.md` — 掲載情報ドラフト＋製品クレーム監査
- `Docs/app-store-privacy-answers.md` — App Privacy 回答ドラフト
- `Docs/app-review-notes-draft.md` — 審査メモドラフト
- `Docs/app-store-screenshot-plan.md` — スクリーンショット計画（既存DEBUGルート再利用）
- `Scripts/verify-release-readiness.sh` — ローカル自動チェック（`--full` でビルドも実行）

## 11. 未検証（正直な明示）

- 実機でのアーカイブ・署名・App Store Connect アップロード・processing（本環境で実行不可）。
- 実機QA（`device-qa-matrix.md` の各行）— シミュレータ確認のみ、**実機は未実施**。
- 実VoiceOver操作・メモリ圧迫・回転制限の実機挙動。
- 本番 API に対する Apple / Google サインイン・再起動後の session 復元・logout・アカウント削除（server 未 deploy のため未実施）。
- App Review の合否（外部）。
