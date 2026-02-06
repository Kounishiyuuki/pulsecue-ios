# PulseCue

ジム中の「進行管理（次に何をやるか／休憩はあと何秒か／残りセット数）」を最小操作で回すワークアウトランナーと、摂取・消費・睡眠・体重を日次でまとめる健康ログ（DayLog）を1つに統合したiOSアプリ。

## 技術
- iOS 17+
- SwiftUI
- SwiftData
- MVVM
- 外部ライブラリなし

## 主な機能
### ワークアウトランナー（Runner）
- 固定表示：**Now / Rest / Next**
- 操作：**完了 / スキップ / +10秒 / 戻る**
- 状態：**exercise / rest / done**
- 休憩タイマーは `deadlineDate` 基準で残り時間を算出
- バックグラウンド移行や強制終了後でも復帰できる（実行状態を永続化）

### ルーティン管理
- Routine / Step の作成・編集・削除
- 並べ替え / 複製 / ピン留め / 検索

### 健康ログ（DayLog）
- 日付主キーで **摂取kcal / 運動消費kcal / 睡眠 / 体重** を入力
- Todayでクイック入力し、当日の収支（Balance）を表示

### 合図（通知・音・触覚）
- 休憩終了の通知：
  - 許可あり：ローカル通知
  - 許可なし：画面内強調＋触覚で代替
- ビープ音は設定でON/OFF

## 想定ディレクトリ構成（予定）
- `App/` エントリ・ModelContainer設定
- `Models/` SwiftData @Model
- `Features/Today/`
- `Features/Workout/`
- `Features/Runner/`
- `Features/History/`
- `Features/Settings/`
- `Services/`（将来拡張用のスタブ）

## ロードマップ
### v1（ローカル完結）
- Runnerの安定化（復帰・通知・触覚）
- DayLog＋Todayダッシュボード
- 履歴の基本表示

### v2
- Sign in with Apple
- 複数端末同期（iCloudまたは独自同期）

### v3
- HealthKit連携（睡眠/体重/消費などの取り込み）
- Widget / Live Activity（Runner中心）

### v4
- AIコーチ（個人最適の提案）
- 食事カロリー推定（推定→確認→確定の保存フロー）

## 注意
- オフライン前提の設計（v1ではログイン/バックエンド/AIなし）
- 医療用途ではない。診断や治療の代替はしない
