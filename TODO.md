# TODO / Roadmap

P0（ローカルファースト）の現状と、Phase 1 以降に予定している作業。

---

## 既知の小さな改善（短期）

- [x] **AppIcon プレースホルダ画像をスロットに配置**（universal / dark / tinted の 3 バリアント、`/tmp/make_pulsecue_icons.swift` で再生成可）
- [ ] AppIcon の本番デザインに差し替え
- [ ] バックグラウンド復帰時のタイマー再描画を 1Hz tick に整流（現在は 0.2 秒間隔）
- [ ] Today のバランス計算を「TDEE 推定 - 摂取」へ拡張する選択肢を検討
- [ ] `@MainActor` 既定の影響で残るマイナーな concurrency 整理（必要に応じて）
- [ ] 履歴で抽出条件（期間 / ルーティン）と簡易グラフを追加
- [x] **Runner 状態機械のユニットテスト**（`Pulse CueTests/RunnerStateMachineTests.swift`：start / Complete→rest / 次セット / 次ステップ / done / Skip from exercise / Skip from rest / Back / Back across step / +10 in/out of rest / 復元 in-progress / 復元 cleared）
- [x] **DayLog / HealthSummary のユニットテスト**（`Pulse CueTests/DayLogHealthSummaryTests.swift`：日付正規化、`fetchOrCreate` 冪等性、`recent` 窓、todayBalance、weeklyBalanceAverage、weeklyIntakeAverage、weightMovingAverage、weightTrend rising/falling/flat、filledDayCount、空・欠損データの非クラッシュ）
- [x] **Nutrition / Meal Confirmation のユニットテスト**（`Pulse CueTests/NutritionLedgerTests.swift`：10 ケース。推定は加算しない / 確認待ち manual も加算しない / 確定の累計 / 複数確定の合計 / 推定破棄の安全性 / pending と confirmed 混在 / pending → confirmed 昇格 / 別日リーク回避 / 空ストア / `MealEntry.init` の値クランプ）
- [x] **History に直近 7 完了セッションのスパークライン**（`Path` 描画、データ 3 件以上で表示）
- [ ] DayLog の手動編集／削除（履歴日付の修正）画面

---

## Phase 1 / v3（オフライン強化 + ジム便利機能）

- [x] **HealthKit 連携の基盤**（`HealthKitImporting` プロトコル + `NoopHealthKitImporter` + Settings の状態表示。実装は v3）
- [ ] HealthKit 連携の本実装
  - [ ] HealthKit Capability を Pulse Cue ターゲットに追加（Xcode UI で）
  - [ ] `NSHealthShareUsageDescription` を Info.plist に追加
  - [ ] `HKHealthStore` を使った `HealthKitImporting` 実装を追加し `HealthKitImporterProvider.shared` に差し替え
  - [ ] 体重 `HKQuantityType.bodyMass`、睡眠 `HKCategoryType.sleepAnalysis`、運動消費 `HKQuantityType.activeEnergyBurned`
  - [ ] 取り込みプレビュー UI で `UserConfirmed<HealthKitDailySample>` ラップ後に DayLog 反映
- [x] **Widget / Live Activity の設計ドキュメント**（[Docs/widget-live-activity.md](Docs/widget-live-activity.md)）
- [ ] Widget Extension ターゲット追加（small / medium）
- [ ] Live Activity（Dynamic Island に休憩タイマー、+10 ボタンは AppIntent）
- [x] **AI コーチ / 食事推定の安全境界とスタブ**（`AICoaching` / `MealCalorieEstimating` / `UserConfirmed`、[Docs/ai-privacy-and-safety.md](Docs/ai-privacy-and-safety.md)）
- [x] **AI コーチ プレビュー画面**（`AICoachView`：観察ベースの提案 / 理由 / 選択肢 / 次の一手。HRV 等の医療指標は不使用。`UserConfirmed<AICoachSuggestion>` 経由で `DayLog.note` に追記）
- [x] **Nutrition / 食事ログ画面**（`NutritionView` / `MealEntrySheet` / `MealEntry` / `NutritionLedger`：朝昼夕間食を slot 単位で記録、推定 → 確認待ち → 確定済みの状態遷移、`NutritionLedger.syncDayLogIntake` が確定済み合計を DayLog に反映、AI 推定は `UserConfirmed<MealEstimate>` でのみ確定）
- [x] **Today からの食事ログショートカット**（メトリクスグリッド直下に `NutritionView` への NavigationLink）
- [ ] AI コーチ本実装（API キーは git 管理外、デフォルト OFF、最小情報のみ送信）
- [ ] 食事カロリー推定本実装（写真 / バーコード / 自然言語、`UserConfirmed<MealEstimate>` 経由でのみ DayLog に反映。テキスト先行）
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
- **DayLog.intakeCalories の同期**：`MealEntry.status == .confirmed` の合計が `NutritionLedger.syncDayLogIntake` で書き戻される。確定済み食事が 0 件なら DayLog は触らない（手動 quick-input 値を温存）。AI 推定（`pending` / `source: .ai`）は **明示的な「確定」操作なしには加算されない**（プライバシー境界）。
- **AI 系の `UserConfirmed<Value>` 境界**：`AICoachSuggestion` / `MealEstimate` を SwiftData に書き込む唯一の経路。本実装で外部 AI に差し替える際もこの境界は必須。
