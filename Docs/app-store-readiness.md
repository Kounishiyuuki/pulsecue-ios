# App Store / TestFlight リリース準備状況

PulseCue v1.0（Pre-API・ローカルファースト MVP）の提出準備監査。**リポジトリを唯一の正**として実測した結果をまとめる。過去レポート（`testflight-readiness-baseline.md` PR #110）を土台に、現時点の実測で更新した差分レポート。

- 監査日: 2026-07-29
- 監査対象 HEAD: `origin/main`（worktree `chore/app-store-release-readiness`）
- 本レポートは**虚偽のコンプライアンス主張をしない**。各項目は下記バケツで分類する。

判定バケツ: **検証済み**（リポジトリで実測）/ **未検証**（本環境で確認不可）/ **手動要**（App Store Connect等の人手作業）/ **外部ブロッカー**（Apple Developer Program / 外部設定）/ **意図的に保留**（このフェーズでは実装しない）/ **App Storeブロッカー** / **非ブロッキング follow-up**。

---

## 1. 総評

TestFlight 配信・App Store 提出に対する**コード/設定側の技術的ブロッカーは検出されなかった**。残るのは主に **App Store Connect 上の手動作業**（メタデータ、スクリーンショット、App Privacy 回答、テスター設定）と **アーカイブ/署名/アップロードの実機作業**。

このリリースは意図的に「ローカルファースト・実API/実認証なし」。Sign in with Apple のみ有効、Google Sign-In はプレースホルダで**無効**。**Release UI では Google コントロールを表示しない**（未提供機能を出さない・「設定準備中」も非表示）。Debug では明示的な unavailable 状態を開発用に残す。

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
- `NSPrivacyTracking = false`、`NSPrivacyTrackingDomains = []`、`NSPrivacyCollectedDataTypes = []`
- Required Reason API: **UserDefaults `CA92.1`**（`SettingsStore` / `RunnerPersistence` が UserDefaults を使用 → 宣言と実装が一致）

未使用機能の権限は**宣言しない**方針。追加の Required Reason API（file timestamp / system boot time / disk space / active keyboard）はアプリコードで使用が確認できないため未宣言（**検証済み: 該当なし**）。第三者SDK（Google/AppAuth/GTM）は各自の PrivacyInfo を同梱する。

## 4. パーミッション（Info.plist・検証済み）

| キー | 用途 | 実使用 |
|---|---|---|
| `NSCameraUsageDescription` | 食品バーコード読取 | ✅ `BarcodeScannerView` |
| `NSLocationWhenInUseUsageDescription` | 近くのジム検索 | ✅ ジム登録フロー |

- マイク / 写真 / 連絡先 / モーション / HealthKit の権限文字列は**無し**（いずれも未使用のため正しい）。
- HealthKit は**未統合**（`HealthKitImporter` は Noop プレースホルダのみ、`import HealthKit`/`HKHealthStore` 実使用なし）。DayLog 等の「健康データ」は端末内 SwiftData のローカル入力のみ。

## 5. Entitlements / Capabilities（検証済み）

`Pulse Cue/Pulse_Cue.entitlements`:
- **有効**: Sign in with Apple（`com.apple.developer.applesignin = [Default]`）→ `LoginView` の `SignInWithAppleButton` と一致。
- **意図的に不在**: Push / iCloud・CloudKit / App Groups / Keychain sharing / Associated Domains / Background Modes（空だった `UIBackgroundModes` は削除済み）。
- **後で必要**: 実API/認証フェーズで Associated Domains 等が必要になる可能性（現フェーズ対象外）。
- **外部ブロッカー**: Sign in with Apple の App ID capability 有効化は Apple Developer で設定要（署名時に自動処理される想定・**手動要**）。

## 6. DEBUG / Release 分離（検証済み）

- QA/ビジュアル確認ルート（`GlassUIVisualQARoot`、Form Guide 3D デバッグルート）は `#if DEBUG` かつ launch 引数 `-pulsecue-debug-glass-ui-route` / `-pulsecue-ui-test-form-guide-3d` で駆動。Release では**コンパイル除外**。
- 本PRで **custom-machine UI fixture（`-pulsecue-ui-test-custom-machine-flow`）の挙動を `#if DEBUG` に限定**（従来は Release でも in-memory化・オンボスキップ・`UIテストジム` seed が引数で作動しえた／※launch引数は実機のインストール済みアプリにユーザーが注入できないため実ユーザー到達性はゼロだが、Release完全無効化＝多層防御）。
- Release バイナリ `strings` 実測: `pulsecue-debug-glass-ui-route` / `127.0.0.1:8787` / fake token / `UIテストジム` / `workers.dev` すべて **0件（不在）**。
- 通常起動は `SampleDataSeeder` のみ（QA seed は走らない）。

## 7. シークレット / エンドポイント監査（検証済み）

- ハードコードされた APIキー / 秘密鍵 / bearer トークン / `*.workers.dev` / 本番エンドポイントは**検出なし**。
- ローカル loopback `http://127.0.0.1:8787/` と mock 用 fake token は `#if DEBUG` 限定（Release バイナリに不在を確認）。
- `Authorization: Bearer \(token)` はヘッダ構築コード（`token` は変数、ハードコード値なし）。実API未接続。
- OpenFoodFacts への外向き通信（バーコード→食品照会・公開API・キー不要・個人情報送信なし）は存在。App Privacy 回答では「アプリ機能のためのデータ（トラッキングなし）」として整理する（**手動要**）。

## 8. 依存パッケージ（検証済み）

`Package.resolved`: `googlesignin-ios` / `appauth-ios` / `gtm-session-fetcher` / `gtmappauth`（すべて Google Sign-In 用）。現フェーズでは Google Sign-In は**プレースホルダで無効**（`GIDClientID = YOUR_IOS_CLIENT_ID...` のためボタン非活性）。解析・トラッキングSDKは**なし**。

## 9. 現時点のブロッカー整理

**App Store ブロッカー（提出前に必須・大半が手動）**
- App Store Connect: アプリ名 / 説明 / キーワード / サポートURL / プライバシーポリシーURL（**手動要**）
- スクリーンショット（必須サイズ）（**手動要**）
- App Privacy 質問票の回答（カメラ・位置・OpenFoodFacts 通信を反映）（**手動要**）
- 年齢レーティング設定（**手動要**）
- 実機アーカイブ・署名・アップロード（**未検証**：本環境では実施不可）

**外部ブロッカー**
- Apple Developer Program 有効・証明書/プロファイル（**外部**）
- Sign in with Apple の App ID capability（**外部/手動**）

**非ブロッキング follow-up**
- Google Sign-In の実クライアントID設定（プレースホルダのまま提出可・ボタンは無効表示）
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
- App Review の合否（外部）。
