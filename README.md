# PulseCue

ジムの **ワークアウト進行（Runner）** と日々の **健康ログ（DayLog）** を、SwiftUI + SwiftData だけで完結させる iOS アプリ（P0 = ローカルファースト・オフライン専用）。

「次に何をやるか」を考えなくて済む状態を作るのが目的です。Runner は `Now / Rest / Next` の固定 UI と 4 つの操作（Complete / Skip / +10 / Back）でテンポを刻みます。

---

## 技術スタック

- iOS 17+ / Xcode 26
- SwiftUI
- SwiftData
- Swift 5（`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`）
- 外部ライブラリは未使用
- ローカルファースト（バックエンド・サインインなし）

---

## ディレクトリ構成

```
Pulse Cue/
├── App/                  # @main エントリポイントと TabView ルート
│   ├── ContentView.swift
│   └── Pulse_CueApp.swift
├── Models/               # SwiftData @Model（永続化）と enum
│   ├── DayLog.swift
│   ├── Enums.swift       # SessionStatus / RunnerPhase / DayLogField / RunnerAction
│   ├── Routine.swift
│   ├── Session.swift
│   ├── Step.swift
│   └── StepResult.swift
├── ViewModels/
│   └── RunnerViewModel.swift
├── Views/                # SwiftUI 画面とサブシート（HealthSummaryView 等）
├── Services/             # 通知 / 永続化 / サンプル投入 / 音 / 触覚 / 設定 / DayLogStore
├── Utilities/            # AppTab / AppTheme / DateUtils / HealthSummary / ScreenWakeManager
├── Resources/Assets.xcassets
└── Info.plist / Pulse_Cue.entitlements
```

---

## P0 で実装済みの機能

### TabView 構成
- 今日 / ワークアウト / ランナー / 履歴 / 設定 の 5 タブ

### Runner（最重要）
- `Now / Rest / Next` の固定 3 カード UI
- 4 つの主要アクション：**Complete / Skip / +10 / Back**
- 状態機械：`exercise → rest → exercise → ... → done`
  - **Complete**：1 セット完了 → 休憩へ。休憩中なら休憩を即終了。
  - **Skip**：現在の **ステップ** をスキップして次のステップへ。
  - **+10**：休憩中のみ、`deadlineDate` を 10 秒延長。
  - **Back**：1 セット戻る（ステップ境界をまたぐ）。休憩中ならエクササイズ中に戻る。
- 休憩タイマーは `deadlineDate` を保持し、現時刻との差分で残り秒を計算
  → バックグラウンド復帰やアプリ再起動後も同じ締切に向かって減算継続
- Runner 状態は `UserDefaults` に保存され、再起動時に SwiftData から復元
- 通知許可がある場合：休憩終了の `UNCalendarNotificationTrigger` を予約
- 通知が利用できない場合：画面ハイライト + 触覚 + ビープ音（フォールバック）

### Workout（ルーティン管理）
- 作成 / 編集 / 削除 / 複製 / 並び替え / ピン留め / 検索
- ピン留めセクションと通常セクションに分割
- スワイプで「開始」「複製」「ピン留め」「削除」、ロングプレスでも同じ操作

### Step（種目）の編集
- `title / sets(1–20) / repsTarget(1–50) / restSeconds(0–600) / note / isWarmup`
- 各値は保存時にクランプ。タイトル空白時は「無題」に置換。

### Today（DayLog ダッシュボード）
- 5 カード（ワークアウト / 栄養 / 運動消費 / 睡眠 / 体重）+ バランスカード
- 値が未入力ならカードをオレンジ枠でハイライト、ボタンも「入力」表示に
- 入力はクイックシートで 1 項目ずつ。保存後はカードが即時更新（`@Query` で SwiftData の変更を観測）
- バランスカードは「摂取 − 消費」と直近 7 日平均を併記（データ不足時はその旨を表示）
- 体重カードには 7 日移動平均と上昇 / 横ばい / 下降の傾向ラベルを表示
- カード下部の「週間サマリー」リンクから `HealthSummaryView` に遷移
- 当日の `DayLog` は `DayLogStore.fetchOrCreateToday(modelContext:)` で 1 日 1 レコードを保証

### Health Summary（健康サマリー）
- 過去 7 日の摂取 / 運動消費 / バランス / 睡眠の平均（3 日以上のデータが必要）
- 体重の最新値・7 日移動平均・直近の傾向
- 入力済みの日数を `n / 7 日` で表示
- すべてオフラインで端末内のみ計算する **目安値**（HealthKit や同期は P0 範囲外）

### History（履歴）
- セッション一覧（ルーティン名 / 日付 / 状態 / 合計時間）
- 詳細画面でステップ結果（完了 / 未完了）を表示

### Settings（設定）
- 通知の許可状態を表示し、未決定ならリクエストを発行
- iOS 設定で取り消された場合はトグルが自動オフ
- ビープ音 / 触覚 / 画面常時点灯のトグル
- アプリ名・バージョン表示

---

## 開き方・実行方法

1. リポジトリのルートで `Pulse Cue.xcodeproj` を Xcode で開く
2. **Scheme を必ず `Pulse Cue` に設定**（左上のスキーム選択）
3. 任意の iPhone Simulator（iOS 17 以降）を選んで `Run` (⌘R)

> ⚠️ **注意**：Scheme が `Pulse CueTests` や `Pulse CueUITests` のままだと、Run / Preview が想定外の挙動をします。

### 初回起動時
- SwiftData のスキーマ初期化のため、初回ビルドはやや時間がかかります
- 初回起動時にサンプルルーティン 2 件（プッシュ・プル）が自動投入されます
- 投入は `UserDefaults` で 1 度だけ行われます（`SampleDataSeeder`）

---

## 既知の制約 / 既知の問題

- **HealthKit 未対応**：体重・睡眠・運動消費は手入力のみ
- **iCloud 同期なし**：すべてローカル `ModelContainer` 内
- **AppIcon 画像なし**：Asset Catalog のスロットは存在するが画像が未投入のため、Xcode が「No app icon set」警告を出す可能性あり
- **通知の繊細な再スケジュール**：休憩中にバックグラウンド遷移→復帰した際、まれに残り 1 秒以下のズレが残る場合あり
- **エンタイトルメント**：`aps-environment = development` と CloudKit ID が含まれているが、P0 では使用しない（後段で利用予定）

---

## ロードマップ（将来フェーズ）

詳細は [TODO.md](TODO.md) を参照。

- HealthKit から体重 / 睡眠 / 運動消費を読み込む
- Sign in with Apple
- iCloud / CloudKit 同期
- ホーム画面ウィジェット（次のセット / 残り休憩）
- Live Activities（Dynamic Island に休憩タイマー）
- AI コーチによるルーティン提案
- 食事写真からの摂取カロリー推定
