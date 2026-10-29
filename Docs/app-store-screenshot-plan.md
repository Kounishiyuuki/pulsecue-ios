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
- プレースホルダ認証情報・「設定準備中」等の DEBUG 専用表示（Google ログインは v1.0 で提供し、Release で表示される）
- 偽サーバデータ / 誤解を招く AI 表現
- 開発専用コントロール
- 意図しない空/エラー状態
- PR #140 の未完成 3D 作業

## 自動撮影（`Scripts/capture-app-store-screenshots.sh`）

主素材6枚＋予備2枚を DEBUG ルートから決定的に一括取得する（2026-10-30 更新）。生成 PNG はローカル成果物で、**リポジトリに commit しない**（`--output` には repo 外のディレクトリを推奨）。

```
./Scripts/capture-app-store-screenshots.sh --device <UDID> --output <repo外dir> --force
# 6.9": iPhone 17 Pro Max → 1320×2868 / 6.3": iPhone 17 Pro → 1206×2622（実測）
```

スクリプトの動作: 前提確認 → Debug ビルド/install → **dark 外観**（本体 `ContentView` がダーク固定のため。ライトだと QA root では暗背景に暗文字になり実画面と異なる）・標準 Dynamic Type・クリーンステータスバー（9:41/満充電/電波）設定 → 各ルートを個別 launch → bounded settle → 取得 → 失敗時 nonzero 終了。既存ファイルは `--force` なしで上書きしない。

### ルート → ファイル対応

| ファイル | 画面 | route | 見出し |
|---|---|---|---|
| `01-home.png` | Home/Today（栄養記録済み） | `home` | 今日を、ひと目で |
| `02-weekly-plan.png` | 週次プラン候補 | `preview-weekly` | 通うジムで、1週間のプラン |
| `03-runner-active.png` | Runner 実行中 | `runner-active` | セットに集中できる |
| `04-nutrition.png` | 栄養（今日の食事3件） | `nutrition` | 食事も、同じアプリで |
| `05-progress.png` | 進捗（今週3回） | `progress` | 伸びが、見える |
| `06-my-gym.png` | My Gym | `mygym-active` | あなたのジムに合わせる |
| `07-workout-completion.png`（予備） | ワークアウト完了 | `workout-completion` | — |
| `08-history-detail.png`（予備） | 履歴詳細 | `history-detail` | — |

### fixture（`GlassUIVisualQAFixture`・DEBUG のみ）

- 栄養: `seedNutrition` が今日の食事3件（朝 520 / 昼 780 / 間食 350 kcal、計 1,650 kcal・P 110 g、すべて確定済み・手入力）、ゲストのプロフィール（172 cm / 32歳 / 男性 / 普通 / 目標 70 kg・-0.25 kg/週）と今日の体重 72.4 kg を入れる。目標摂取は本番のプロフィール計算の結果（撮影時 2,273 kcal・残り 623 kcal）。Home の栄養カードも同じデータで埋まる。
- セッション: 撮影時点から 0/2/4 日前（今日は 07:00、未明の撮影では 2 時間前。それ以前は 19:00）。**水〜土曜に撮れば「今週 3回」**。日〜火曜は今週に入る回数が減るので、撮影は水〜土曜に行う。
- 週次プラン: カタログ全体ではなく fixture ジムの13マシン（レッグエクステンション・カーフレイズを追加）から本番のルールベース生成で作る。

Home は DEBUG ルート `home`（`ScreenshotHomeHost` が本番 `TodayView` を fixture の**アクティブジム「Pulse Fitness 渋谷」＋13マシン**上で描画）。UIテスト用の `-pulsecue-ui-test-custom-machine-flow`（「UIテストジム」空状態）は **App Store 用には使用しない**。Runner active/rest は DEBUG ルート（`ScreenshotRunnerHost`・in-memory・fixture routine「上半身プッシュ」を既存 Runner 公開APIで駆動）。**Runner 状態機械は不変**。

スクリーンショットホストの設定は固定名の使い捨て UserDefaults suite `com.pulsecue.screenshot-visualqa`（`.standard` 非使用・固定名のため orphan plist が無制限に増えない）。撮影スクリプトは EXIT trap で当ドメインを best-effort 削除する。

### 使用シミュレータ（今回の取得）

- iPhone 17 Pro Max（UDID `9FC2DBF3-...`）/ 1320×2868 px / Portrait
- iPhone 17 Pro（UDID `A8C1142A-...`）/ 1206×2622 px / Portrait
- 外観 dark / 言語ロケール（端末設定）/ 標準 Dynamic Type / クリーンステータスバー

### 既知の制限

- **Runner 休憩の可視秒は「決定的ではない」**。決定的なのは **相（REST phase）とルート/状態** のみで、表示される残り時間は本番 rest timer による**ライブカウント**（`01:27` 等）。起動→撮影の間に減少し、連続撮影で PNG の秒（ピクセル）は変わり得る。どのフレームも妥当な休憩状態で真実。可視秒の固定には本番 RunnerView/状態機械への DEBUG フック追加が必要で、**本番 Runner 非改変を優先**し本PRでは見送った（bounded but timing-dependent）。
- Runner 休憩・Form Guide は一括撮影の対象外にした（個別撮影は `runner-rest` / `form-guide` route で可能）。
- weekly は全種目が「目安なし」になる。2026-10-30 時点で `MachineCatalog` のどの項目にも `defaultSets/Reps/Rest` が無く、fixture のマシン選択では解消できない（**真実の製品表示**）。消すにはカタログへ既定値を入れる製品変更が必要（別 PR で判断）。
- iOS 26 系 sim は外観トグルが反映されにくい場合あり（`appearance` は best-effort）。撮影後に暗背景・明文字になっているか目視する。
- App Store Connect の必要デバイスセット/寸法は Apple 公式で**手動確認**（本書では確定しない）。

### 最終マーケティング合成（後工程）

取得画像は**アプリUIのみのクリーンなソース**。headline やフレーム合成は App Store 用の別デザイン工程で行い、アプリ本体には埋め込まない。

## 撮影手順（手動・個別）

1. Debug ビルドをシミュレータへインストール。
2. 上表の route（または custom-machine-flow）を launch 引数で起動。
3. `xcrun simctl io <sim> screenshot` で取得。
4. ステータスバーを整える（`xcrun simctl status_bar ... override`）。
5. App Store Connect の必要サイズにトリミング/フレーム（Apple 現行仕様を要確認）。
