# TestFlight Readiness Baseline (PR #110)

PulseCue を TestFlight / App Store 提出可能な状態にするためのベースライン整備記録と、
App Store Connect の App Privacy 回答に必要な情報をまとめる。

> このフェーズではまだ実 AI / 実 API / 本番エンドポイント / 認証実装は含まない。
> データはローカルのみ。トラッキングなし。第三者 SDK なし。

---

## 1. 本 PR で実施した内容

| 項目 | 変更前 | 変更後 |
|---|---|---|
| `PrivacyInfo.xcprivacy` | なし | `Pulse Cue/PrivacyInfo.xcprivacy` を追加（ターゲット Resources に登録） |
| Required Reason API | 未宣言 | UserDefaults `CA92.1` を宣言 |
| `PRODUCT_BUNDLE_IDENTIFIER` | `y.Pulse-Cue` | `com.kounishiyuuki.pulsecue` |
| `CFBundleDisplayName` | 未設定（`Pulse Cue` 表示） | `PulseCue` |
| `TARGETED_DEVICE_FAMILY` | `1,2`（iPhone+iPad） | `1`（iPhone-only） |
| iPhone orientation | Portrait + Landscape×2 | Portrait のみ |
| iPad orientation キー | 設定あり | 削除（iPhone-only 化に伴い不要） |

### 据え置いた項目（今回は触らない）
- Team（`58A7G4U27M`）・Automatic Signing は維持。
- テストターゲットの bundle ID（`y.Pulse-CueTests` / `y.Pulse-CueUITests`）と
  `TARGETED_DEVICE_FAMILY = 1,2` は提出非対象のため据え置き。
- AI / API / production endpoint / Worker URL のデフォルト化はしない。
- token 永続化 / Keychain 保存はしない。
- ログイン / Auth 実装はしない（後続 PR）。
- SwiftData schema / `@Model`、AI プランの明示保存境界は変更しない。
- 旧 `PulseCue.xcodeproj` / `PulseCue/`（非アクティブ）の整理は別途。
- Launch Screen のカスタム化は別途（現状は自動生成）。

---

## 2. App Store Connect — App Privacy 回答メモ

### 2.1 トラッキング
- **トラッキングなし。** `NSPrivacyTracking = false` / `NSPrivacyTrackingDomains = []`。
- 広告 / アトリビューション SDK なし。IDFA 不使用。

### 2.2 データ収集（Data Collection）
- **収集データなし。** `NSPrivacyCollectedDataTypes = []`。
- 健康・トレーニング・栄養データはすべて端末ローカル（SwiftData / UserDefaults）。
- サーバー同期 / CloudKit / アカウント連携はこのフェーズでは未実装。

### 2.3 Required Reason API
| API カテゴリ | Reason | 用途 |
|---|---|---|
| `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1` | アプリ自身の設定・状態の保存／読み出しのみ（端末内・アプリ専用） |

- 他の Required Reason API（file timestamp / disk space / system boot time / sysctl 等）は未使用。

### 2.4 ネットワーク通信（参考・既存 MVP 機能）
| 通信先 | 用途 | 備考 |
|---|---|---|
| `world.openfoodfacts.org`（OpenFoodFacts） | 食品バーコード検索 | ユーザー操作起点。個人を特定する情報は送信しない。 |
| AI トレーニングプラン提供 | — | **デフォルトは offline mock。本番 / Worker URL のデフォルトは持たない。** `127.0.0.1:8787` は `#if DEBUG` 限定。 |

### 2.5 権限文言（Info.plist 既存）
- `NSCameraUsageDescription`: 食品バーコードを読み取るためにカメラを使用します。
- `NSLocationWhenInUseUsageDescription`: ジム登録の際、近くのジムを検索するために位置情報を使います。現在地は近くのジム検索にのみ使用します。

---

## 3. TestFlight 提出チェックリスト

### 3.1 プロジェクト設定
- [x] Bundle ID を reverse-DNS（`com.kounishiyuuki.pulsecue`）に確定
- [x] Display Name = `PulseCue`
- [x] iPhone-only（`TARGETED_DEVICE_FAMILY = 1`）
- [x] Portrait-only（`UISupportedInterfaceOrientations~iphone = Portrait`）
- [x] Deployment Target iOS 17.0
- [x] `MARKETING_VERSION = 1.0` / `CURRENT_PROJECT_VERSION = 1`
- [x] AppIcon（1024 単一サイズ・light/dark/tinted）設定済み
- [x] `PrivacyInfo.xcprivacy` をターゲットにバンドル

### 3.2 ビルド / テスト（本 PR 時点）
- [x] Debug build 成功（iPhone 16 Pro Simulator）
- [x] Release build 成功（iPhone 16 Pro Simulator）
- [x] Unit tests: 534 tests / 44 suites passed
- [x] Release leakage scan: clean（`127.0.0.1` / `8787` / `fake-valid` / `fake-expired` / `workers.dev` / `debugLocalMock` / `DebugFakeToken` すべて 0 件）

### 3.3 提出前に App Store Connect 側で必要な作業（このフェーズの対象外・参考）
- [ ] App ID `com.kounishiyuuki.pulsecue` を Developer Portal / ASC に登録
- [ ] App ID で `Sign in with Apple` Capability を有効化（手順は `Docs/testflight-external-setup.md` §1 を参照）
- [ ] Google ログインは Info.plist がプレースホルダのまま無効でも提出可。実値で有効化する場合の手順は `Docs/testflight-external-setup.md` §2・§3 を参照
- [ ] Archive（Generic iOS Device / 実機署名）作成 → App Store Connect へアップロード
- [ ] App Privacy 質問への回答（本ドキュメント §2 に基づく）
- [ ] 輸出コンプライアンス（暗号化）回答
- [ ] TestFlight ベータ情報 / テスター招待

> §3.3 は実機署名・ASC 登録が必要なため、ローカルのシミュレータ検証範囲外。
> 実機署名や App ID 登録でローカル環境依存のエラーが出た場合は回避実装せず、エラー内容を共有する方針。

> 関連ドキュメント:
> - 外部設定（Apple Developer Portal / Google Cloud OAuth / Info.plist 置換）の実作業: `Docs/testflight-external-setup.md`
> - 提出前の手動 QA（認証準備フェーズを含む）: `Docs/manual-qa-checklist.md`

---

## 4. 検証ログ（本 PR）

Release `Info.plist`（ビルド成果物）で以下を確認:

- `CFBundleIdentifier = com.kounishiyuuki.pulsecue`
- `CFBundleDisplayName = PulseCue`
- `UIDeviceFamily = [1]`
- `UISupportedInterfaceOrientations~iphone = [UIInterfaceOrientationPortrait]`（iPad キーなし）
- `PrivacyInfo.xcprivacy` が `.app` 内に同梱
