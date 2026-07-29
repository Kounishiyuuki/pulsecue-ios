# App Store スクリーンショット計画

PulseCue（iPhone 専用・Portrait）の App Store スクリーンショット計画。**1枚 = 1メッセージ**。すべて `main` の現物挙動から選定。PR #140 の未完成 3D 改善は写さない。

- 作成日: 2026-07-29 / 対象: `main`
- **本タスクでは最終スクショの撮影は行わない**（再現可能な計画＋安全な準備経路が成果物）。
- デバイスサイズ/必要枚数は提出時に Apple 公式の**最新仕様で要確認**（例: 6.9" / 6.5" 系。数値は本書では確定しない）。
- ステータスバー整え（時刻/電波/バッテリ）は**手動**（またはクリーン化ツール）。

## 撮影に使う DEBUG ルート（既存・再利用）

`-pulsecue-debug-glass-ui-route <route>`（`#if DEBUG` のみ・in-memory・ネットワークなし）。既存 `GlassUIVisualQARoot` を再利用し、新規 fixture は追加しない。

| 画面 | route |
|---|---|
| My Gym | `mygym-active` |
| マシン選択 | `machine-selection` |
| プラン候補（週次） | `preview-weekly` |
| 単発プランPreView | `preview-single` |
| 履歴一覧 | `history-populated` |
| 履歴詳細 | `history-detail` |
| Exercise Library | `exercise-library` |
| フォームガイド(3D) | `form-guide` |
| Home/Today | `-pulsecue-ui-test-custom-machine-flow`（Home 到達） |

Runner の実行中/休憩は決定的ルートが**無い**（実セッションが必要）。→ 手動撮影（ダミールーティンを開始）か、将来の小さな DEBUG fixture 追加を推奨。本PRでは Runner 隣接コードに触れないため**手動**扱い。

## 選定スクリーンショット（7枚・価値順）

各: 画面 / メッセージ / 必要状態 / 外観 / 捕捉経路 / ステータスバー手動 / headline / 避けるクレーム

### 1. Home / Today
- メッセージ: 迷わず今日を始められる
- 必要状態: シード済みジム有りの Home（コンディション未入力でOK）
- 外観: Light（任意で Dark 版）
- 捕捉: `-pulsecue-ui-test-custom-machine-flow`
- ステータスバー手動: はい
- headline: **今日のトレーニングを、迷わず開始**
- 避ける: AI/同期/健康分析の示唆

### 2. 週次プラン候補（preview-weekly）
- メッセージ: 使えるマシンから一週間を組める
- 必要状態: 生成済み候補（fixture が整合表示）
- 外観: Light
- 捕捉: route `preview-weekly`
- ステータスバー手動: はい
- headline: **使えるマシンから、一週間のプランを作成**
- 避ける: 「AIが自動生成」。ルールベースである

### 3. ランナー実行中（手動）
- メッセージ: 種目・セットを見ながら進行
- 必要状態: 実セッション（ダミールーティン開始・exercise フェーズ）
- 外観: Light
- 捕捉: **手動**（決定的ルートなし）
- ステータスバー手動: はい
- headline: **種目とセットを見ながら記録**
- 避ける: フォーム保証・リアルタイム矯正

### 4. ランナー休憩タイマー（手動）
- メッセージ: 休憩も同じ画面で管理
- 必要状態: rest フェーズ（休憩タイマー表示）
- 外観: Light
- 捕捉: **手動**
- ステータスバー手動: はい
- headline: **休憩時間も、そのまま管理**
- 避ける: 「最速」等の誇張

### 5. 履歴詳細（history-detail）
- メッセージ: 実施記録がセット単位で残る
- 必要状態: fixture の完了セッション（解決済み種目）
- 外観: Light
- 捕捉: route `history-detail`
- ステータスバー手動: はい
- headline: **振り返りを、次のトレーニングへ**
- 避ける: クラウド/多デバイス

### 6. My Gym / マシン選択（mygym-active or machine-selection）
- メッセージ: 通うジムのマシンを登録して活用
- 必要状態: アクティブなジム＋マシン
- 外観: Light
- 捕捉: route `mygym-active`（必要なら `machine-selection`）
- ステータスバー手動: はい
- headline: **通うジムのマシンを、登録して活用**
- 避ける: サーバレコメンド

### 7. フォームガイド（form-guide）
- メッセージ: 対応種目は動きを 3D＋テキストで確認
- 必要状態: 対応種目のガイド（3Dデモ＋テキスト）
- 外観: Light
- 捕捉: route `form-guide`
- ステータスバー手動: はい
- headline: **対応種目は、動きを3Dとテキストで確認**
- 避ける: 「正しいフォームを保証」。医療助言でない。PR #140 の未完成改善は写さない（main 現状のみ）

## Headline 一覧（日本語・機能で裏付け済み）

1. 今日のトレーニングを、迷わず開始
2. 使えるマシンから、一週間のプランを作成
3. 種目とセットを見ながら記録
4. 休憩時間も、そのまま管理
5. 振り返りを、次のトレーニングへ
6. 通うジムのマシンを、登録して活用
7. 対応種目は、動きを3Dとテキストで確認

**禁止語**（根拠なく使わない）: 最適 / 完璧 / AIが自動で / 科学的に証明 / 絶対 / 最速 / 正しいフォームを保証。

## 露出させない要素（撮影時チェック）

- DEBUG ラベル / スクリーンショットルート痕跡
- プレースホルダ認証情報・未提供の Google ログイン（Release では非表示）
- 偽サーバデータ / 誤解を招く AI 表現
- 開発専用コントロール
- 意図しない空/エラー状態
- PR #140 の未完成 3D 作業

## 自動撮影（`Scripts/capture-app-store-screenshots.sh`）

7画面を DEBUG ルートから決定的に一括取得する。生成 PNG はローカル成果物（`build/app-store-screenshots/`・`.gitignore` 済み、**リポジトリに commit しない**）。

```
./Scripts/capture-app-store-screenshots.sh --device <UDID> --output build/app-store-screenshots
# 上書きは --force。UDID 省略時は booted simulator を使用。
```

スクリプトの動作: 前提確認 → Debug ビルド/install → light 外観・標準 Dynamic Type・クリーンステータスバー（9:41/満充電/電波）設定 → 各ルートを個別 launch → bounded settle（Form Guide のみ RealityKit 用に追加待機）→ 取得 → 決定的ファイル名保存 → 失敗時 nonzero 終了。既存ファイルは `--force` なしで上書きしない。

### ルート → ファイル対応

| ファイル | 画面 | 起動引数 |
|---|---|---|
| `01-home.png` | Home/Today | `-pulsecue-ui-test-custom-machine-flow` |
| `02-weekly-plan.png` | 週次プラン候補 | `-pulsecue-debug-glass-ui-route preview-weekly` |
| `03-runner-active.png` | Runner 実行中 | `-pulsecue-debug-glass-ui-route runner-active` |
| `04-runner-rest.png` | Runner 休憩 | `-pulsecue-debug-glass-ui-route runner-rest` |
| `05-history-detail.png` | 履歴詳細 | `-pulsecue-debug-glass-ui-route history-detail` |
| `06-my-gym.png` | My Gym | `-pulsecue-debug-glass-ui-route mygym-active` |
| `07-form-guide.png` | フォームガイド | `-pulsecue-debug-glass-ui-route form-guide` |

Runner active/rest は本PRで追加した DEBUG ルート（`ScreenshotRunnerHost`・in-memory・fixture routine「上半身プッシュ」を既存 Runner 公開APIで駆動）。**Runner 状態機械は不変**。

### 使用シミュレータ（今回の取得）

- iPhone 17 Pro（UDID `A8C1142A-...`）/ iOS 26.5 / 1206×2622 px / @3x / Portrait
- 外観 light / 言語ロケール（端末設定）/ 標準 Dynamic Type / クリーンステータスバー

### 既知の制限

- **Runner 休憩タイマーはライブカウント**（`01:27` 等、フレームにより秒が前後）。どのフレームも妥当な休憩状態で真実。完全固定が必要なら将来 DEBUG の static-progress フックを検討（本PRでは Runner 非改変を優先）。
- Form Guide の 3D は RealityKit のため取得直前に追加 settle（`PULSECUE_FORMGUIDE_DELAY`）。**main 現状の capsule モデル**であり PR #140 の改良は含まない。
- iOS 26 系 sim は外観トグルが反映されにくい場合あり（`appearance` は best-effort）。
- App Store Connect の必要デバイスセット/寸法は Apple 公式で**手動確認**（本書では確定しない）。

### 最終マーケティング合成（後工程）

取得画像は**アプリUIのみのクリーンなソース**。headline やフレーム合成は App Store 用の別デザイン工程で行い、アプリ本体には埋め込まない。

## 撮影手順（手動・個別）

1. Debug ビルドをシミュレータへインストール。
2. 上表の route（または custom-machine-flow）を launch 引数で起動。
3. `xcrun simctl io <sim> screenshot` で取得。
4. ステータスバーを整える（`xcrun simctl status_bar ... override`）。
5. App Store Connect の必要サイズにトリミング/フレーム（Apple 現行仕様を要確認）。
