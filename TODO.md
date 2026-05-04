# TODO / Roadmap

P0（ローカルファースト）の現状と、Phase 1 以降に予定している作業。

---

## 既知の小さな改善（短期）

- [ ] AppIcon 画像をスロットに配置（現状はスロットのみで画像なし）
- [ ] バックグラウンド復帰時のタイマー再描画を 1Hz tick に整流（現在は 0.2 秒間隔）
- [ ] Today のバランス計算を「TDEE 推定 - 摂取」へ拡張する選択肢を検討
- [ ] `@MainActor` 既定の影響で残るマイナーな concurrency 整理（必要に応じて）
- [ ] 履歴で抽出条件（期間 / ルーティン）と簡易グラフを追加
- [x] **Runner 状態機械のユニットテスト**（`Pulse CueTests/RunnerStateMachineTests.swift`：start / Complete→rest / 次セット / 次ステップ / done / Skip from exercise / Skip from rest / Back / Back across step / +10 in/out of rest / 復元 in-progress / 復元 cleared）
- [x] **DayLog / HealthSummary のユニットテスト**（`Pulse CueTests/DayLogHealthSummaryTests.swift`：日付正規化、`fetchOrCreate` 冪等性、`recent` 窓、todayBalance、weeklyBalanceAverage、weeklyIntakeAverage、weightMovingAverage、weightTrend rising/falling/flat、filledDayCount、空・欠損データの非クラッシュ）
- [ ] HealthSummary に簡易スパークライン（Charts なしで Path 描画）を追加検討
- [ ] DayLog の手動編集／削除（履歴日付の修正）画面

---

## Phase 1（オフライン強化）

- [ ] HealthKit 連携
  - [ ] 体重を `HKQuantityType.bodyMass` から取得
  - [ ] 睡眠を `HKCategoryType.sleepAnalysis` から取得
  - [ ] 運動消費カロリーを `HKQuantityType.activeEnergyBurned` から取得
  - [ ] HealthKit が無効／未許可なら DayLog の手入力にフォールバック
- [ ] Live Activities（Dynamic Island に休憩タイマー）
- [ ] ウィジェット（今日のルーティン / 残り休憩 / バランス / 体重トレンド）
- [ ] アクセシビリティ（VoiceOver / Dynamic Type）の点検

---

## Phase 2（同期）

- [ ] Sign in with Apple
- [ ] CloudKit / SwiftData 同期（`ModelConfiguration` の `cloudKitDatabase` 指定）
- [ ] バックエンドが必要な機能の API 設計（必要に応じて）

---

## Phase 3（AI / 自動化）

- [ ] AI コーチ：直近の履歴からルーティン提案・負荷調整
- [ ] 食事写真からの摂取カロリー推定（オンデバイス or サーバ）
- [ ] 自然言語からのルーティン入力（「胸の日 4 種目で」）

---

## 設計メモ

- 状態の真実：`RunnerViewModel` は **メモリ上の最新状態**。`UserDefaults`（`RunnerPersistence`）は復帰用のスナップショット。SwiftData は完了済み履歴の永続化（Session / StepResult）。
- 休憩タイマーは `deadlineDate` の保持で実時間ベース。バックグラウンド遷移しても `deadlineDate - now` で残り秒が決まる。
- Skip は **ステップ** 単位。+10 は **休憩中のみ** 有効。Back は 1 セット単位（ステップ境界跨ぎ）。
- iOS 設定で通知が取り消された場合、Settings 画面を開いたタイミングでトグルを自動オフに同期する。
- **DayLog の単一性**：`DayLog.date` は `DateUtils.startOfDay(_:)` で 0:00 に正規化し、`@Attribute(.unique)` で 1 日 1 レコード。重複作成は `DayLogStore.fetchOrCreateToday` が防ぐ。
- **HealthSummary** は `[DayLog]`（降順）の純関数なので、SwiftUI からも単体テストからも同じ計算を使える。週平均は最低 3 日、トレンドは最低 4 日のデータで初めて値を返す。
