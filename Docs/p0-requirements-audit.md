# PulseCue P0 Requirements Audit

> **本ドキュメントの目的**: アップロードされた要件定義書の P0
> (ローカル / オフライン / アカウント不要のジム実行支援 + DayLog 中心
> のヘルス記録) を、現状の iOS 実装と突き合わせる。
> 大規模な追加機能 (Worker import の iOS 統合、AI、HealthKit 等) に
> 進む前に、P0 のカバレッジと残ギャップを確定させる。
> **コード変更は含まない**。次の実装 PR で対応する。

監査日: 2026-05-17 / 対象 `main` 末: `f9b6741` (PR #28 merge)

## 1. 目的 (Purpose)

最近の PR #20–#28 で My Gym フロー、ジム候補検索、近隣ジム検索、
Today クイック導線、UI 磨き込み、サーバー側の short-lived token
インフラまでは実装した。が、これらは **P0 の "中核" ではなく追加価値**。
本来の P0 (ルーティン / Runner / 履歴 / DayLog) がどの程度満たされて
いるかを、追加機能を更に積む前に一度棚卸しする。

## 2. 現状実装済みの領域 (Current implemented areas)

- **ルーティン**: モデル + CRUD + 複製 + ピン留め + ステップ編集
- **Runner**: 状態機械 (exercise / rest / done)、4 操作 (Complete / Skip / +10s / Back)、バックグラウンド復元、通知 / ビープ / 触覚、画面常時点灯
- **履歴**: `Session` / `StepResult` モデル + 一覧 + 詳細
- **DayLog / Health**: モデル + クイック入力 + BMR/TDEE/Target Intake/Balance 計算 + 7日サマリー
- **設定**: 通知許可状況、ビープ / 触覚 / 画面常時点灯トグル、アプリ情報
- **My Gym フロー** (PR #20–#24): 手動ジム登録 + マシン選択 + 部位選択 + 自動生成プラン → 既存 `Routine` への変換
- **ジム候補検索** (PR #21 / #22): MapKit テキスト検索 + 現在地検索 + プライバシー文言 + 手動フォールバック
- **UI ポリッシュ** (PR #23 / #24): `MyGymStyle` 共通スタイル、Today に「ジムからメニュー作成」 カード
- **サーバー側 import token インフラ** (PR #25–#28): 戦略ドキュメント + `/api/auth/import-token` 実装 + 短期トークン受け入れ

> 重要: **My Gym とサーバー token は P0 の中核要件ではない。**
> 「設備に合わせたメニュー生成を Today から呼べる」 という便利機能であり、
> ルーティン / Runner / 履歴 / DayLog が動くかどうかには影響しない。

## 3. P0 要件チェックリスト (P0 requirements checklist)

凡例: ✅ Done / 🟡 Partial / ❌ Missing / ❓ Unknown

### 3.1 ルーティン

| 要件 | 状況 | 根拠 / 推定ファイル | リスク | 推奨アクション |
|---|---|---|---|---|
| ルーティン作成 / 編集 / 削除 | ✅ Done | `Pulse Cue/Views/WorkoutView.swift` (一覧 + 削除), `Pulse Cue/Views/RoutineEditorView.swift` (編集) | 低 | 維持 |
| ルーティン複製 | ✅ Done | `WorkoutView.swift:575 duplicateRoutine()`、コンテキストメニュー / スワイプから呼出 | 低 | 維持 |
| ルーティン並び替え | 🟡 Partial | `Pulse Cue/Services/RoutineOrderStore.swift` (永続化あり) + `WorkoutView` ではドラッグ並び替え可。**`RoutinePickerSheet` (Runner から呼ぶピッカー) には並び替え UI なし** | 中 | RunnerPickerSheet にも `.onMove` か並び替えハンドルを足す or "WorkoutView で並び替えてください" を Runner ピッカーに案内する |
| ルーティンピン留め | 🟡 Partial | モデル `Routine.isPinned` + `RoutineOrderStore.setPinned(...)` + `WorkoutView` にトグル UI あり。**`RoutinePickerSheet` にはピン UI なし** | 中 | RunnerPickerSheet の各行にピン アイコンを追加 (タップでトグル) |
| ルーティン検索 / フィルター | ❌ Missing | `RoutinePickerSheet` / `WorkoutView` のどちらにも検索フィールド無し | 中 (ルーティン件数が増えると致命的) | `WorkoutView` に最小限の `.searchable` を 1 行で導入する |

### 3.2 ステップ

| 要件 | 状況 | 根拠 / 推定ファイル | リスク | 推奨アクション |
|---|---|---|---|---|
| ステップ追加 / 編集 / 削除 / 並び替え / 複製 | ✅ Done | `RoutineEditorView.swift` (`addStep`, `.onMove`, スワイプ delete + duplicate) | 低 | 維持 |
| バリデーション (`sets∈[1,20]`, `restSeconds∈[0,600]`, `repsTarget≥1`) | ✅ Done | `Pulse Cue/Models/Step.swift` (init で clamp) + `Pulse CueTests/RoutineFactoryTests.swift` で間接的に検証 | 低 | 維持 |

### 3.3 Runner

| 要件 | 状況 | 根拠 / 推定ファイル | リスク | 推奨アクション |
|---|---|---|---|---|
| 状態機械 (exercise / rest / done) | ✅ Done | `Pulse Cue/ViewModels/RunnerViewModel.swift:14–180` (`phase: RunnerPhase`) | 低 | 維持 |
| Complete | ✅ Done | `RunnerViewModel.completeCurrent()` (StepResult 記録 + rest 開始) | 低 | 維持 |
| Skip | ✅ Done | `RunnerViewModel.skipCurrent()` (rest 通知をキャンセル) | 低 | 維持 |
| +10 秒 | ✅ Done | `RunnerViewModel.extendRest()` (`restDeadline` 加算) | 低 | 維持 |
| Back (1 セット戻る) | ✅ Done | `RunnerViewModel.goBack()` | 低 | 維持 |
| バックグラウンド / kill 復帰 | ✅ Done | `Pulse Cue/Services/RunnerPersistence.swift` + `RunnerViewModel.restoreIfPossible()` + `RunnerView.swift` の `onChange(of: scenePhase)` でアクティブ復帰時に再計算 | 中 (テストが薄い) | 復帰系の自動テスト追加 (`@Test` で `RunnerPersistence` の往復 + 過去 deadline の扱い) |
| ローカル通知 (休憩終了) | ✅ Done | `Pulse Cue/Services/NotificationManager.swift:33–49 scheduleRestNotification`、`RunnerViewModel.scheduleRestNotification`、`Skip` 時にキャンセル | 中 (通知許可拒否時の UX 案内が薄い可能性) | 設定画面の許可状況表示は既にあり (`SettingsView`)。manual-qa にケース追加で済む |
| ビープ音 | ✅ Done | `Pulse Cue/Services/SoundHapticManager.swift:playBeep()` + `RunnerViewModel.signalAttentionIfNeeded()` | 低 | 維持 |
| 触覚 | ✅ Done | `SoundHapticManager.playHaptic()` (UINotificationFeedbackGenerator) | 低 | 維持 |
| 触覚のみフォールバック (音 off / 触覚 on) | 🟡 Partial | `settings.soundEnabled` と `settings.hapticsEnabled` は独立 toggle なので動作上は OK。明示的な「音 off の時は触覚を保証する」コードは無い | 低 | 動作上問題なし。`Docs/manual-qa-checklist.md` に明示ケースを追加するだけで足りる |
| 画面常時点灯 トグル | ✅ Done | `Pulse Cue/Utilities/ScreenWakeManager.swift:apply(_:)` + `SettingsStore` 経由で UIApplication.isIdleTimerDisabled を制御 | 低 | 維持 |
| アクションバーのアクセシビリティ | ✅ Done | `RunnerView.swift:436–448` 「1 セット戻る」「休憩を 10 秒延長」「このステップをスキップ」 + Complete ボタンの文脈別ラベル | 低 | 維持 |
| 残り休憩秒の VoiceOver | ✅ Done | `RunnerView.swift:240` `.accessibilityLabel("残り N 秒")` | 低 | 維持 |

### 3.4 履歴

| 要件 | 状況 | 根拠 / 推定ファイル | リスク | 推奨アクション |
|---|---|---|---|---|
| `Session` モデル | ✅ Done | `Pulse Cue/Models/Session.swift` (status / 合計時間 / dayDate) | 低 | 維持 |
| `StepResult` モデル | ✅ Done | `Pulse Cue/Models/StepResult.swift` (sessionId / stepId / setIndex / done / reps) | 低 | 維持 |
| セッション一覧 | ✅ Done | `Pulse Cue/Views/HistoryView.swift` (最新 hero + ページング) | 低 | 維持 |
| セッション詳細 (✓ / ✕) | ✅ Done | `Pulse Cue/Views/SessionDetailView.swift` (ステップ + セット毎の done フラグ + 実 reps) | 低 | 維持 |

### 3.5 DayLog / Health

| 要件 | 状況 | 根拠 / 推定ファイル | リスク | 推奨アクション |
|---|---|---|---|---|
| `DayLog` モデル (intake / exercise / sleep / weight) | ✅ Done | `Pulse Cue/Models/DayLog.swift` (5 つの optional フィールド) | 低 | 維持 |
| BMR / TDEE / Target Intake / Balance 計算 | ✅ Done | `Pulse Cue/Services/GoalCalculator.swift` + `Pulse CueTests/GoalCalculatorTests.swift` (Mifflin-St Jeor) | 低 | 維持 |
| 7 日週次平均 | ✅ Done | `Pulse Cue/Utilities/HealthSummary.swift` (weeklyIntake/Exercise/Sleep/Balance) + `Pulse Cue/Views/HealthSummaryView.swift` + `Pulse CueTests/DayLogHealthSummaryTests.swift` | 低 | 維持 |
| Today カード (Workout / Nutrition / Sleep / Weight / Balance) | ✅ Done | `Pulse Cue/Views/TodayView.swift` (heroCard + metricsGrid 2×2 + balanceCard) | 低 | 維持 |
| 未入力時のクイック入力 | ✅ Done | `Pulse Cue/Views/DayLogQuickInputSheet.swift` (フィールド別シート) | 低 | 維持 |
| 「ジムからメニュー作成」 (PR #24) | ✅ Done | `Pulse Cue/Views/TodayGymPlanCard.swift` (4 状態) | 低 | P0 外だが既に統合済み |
| 食事ログ (PR #14 系) | ✅ Done | `MealEntry`, `NutritionLedger`, `NutritionView`, `MealEntrySheet` | 低 | P0 外だが統合済み |

### 3.6 設定

| 要件 | 状況 | 根拠 / 推定ファイル | リスク | 推奨アクション |
|---|---|---|---|---|
| 通知許可トグル + 状態表示 | ✅ Done | `Pulse Cue/Views/SettingsView.swift:407–408, 541–579` + `NotificationManager.requestAuthorization()` | 低 | 維持 |
| 音 / 触覚 / 画面常時点灯 | ✅ Done | `SettingsView.swift:416–418` (3 toggle) → `SettingsStore` 経由 | 低 | 維持 |
| アプリ情報 (バージョン) | ✅ Done | `SettingsView.swift:471–474` | 低 | 維持 |
| プロフィール / 目標 (UserProfile, PR #16) | ✅ Done | `Pulse Cue/Models/UserProfile.swift` + `Pulse Cue/Services/UserProfileStore.swift` + `Pulse CueTests/UserProfileStoreTests.swift` (移行込み) | 低 | 維持 |

### 3.7 横断的事項

| 要件 | 状況 | 根拠 | リスク | 推奨アクション |
|---|---|---|---|---|
| オフラインファースト | ✅ Done | ルーティン / Runner / 履歴 / DayLog / My Gym 手動フロー全てが SwiftData のみで動作。MapKit 検索のみネット要 (= P1 機能) | 低 | 維持 |
| SwiftData 永続化 / 移行 | ✅ Done | `PulseCueSchemaV1 → V2` migration (PR #20)、`Gym`/`GymMachine` の追加移行を含む | 低 | 維持 |
| アクセシビリティ ベースライン | 🟡 Partial | Runner のアクションバーと残り休憩秒は OK。**他画面 (TodayView の各カード、HistoryView の行、SettingsView の細かい toggle) の `.accessibilityLabel` 網羅状況は未確認** | 中 | 監査用に画面横断の VoiceOver パスをマニュアル QA に項目追加 |
| 自動テスト | ✅ Mostly Done | 11 ファイル / ~2,129 行。Runner state machine / DayLog 週次 / GoalCalculator / RoutineFactory / ジム候補検索 / Profile 移行などをカバー。 **Runner cold-launch 復帰 と `SoundHapticManager` / `ScreenWakeManager` の組合せ条件は未テスト** | 中 | 復帰系・トグル組合せの XCTest / Swift Testing を追加 |

## 4. ギャップ順位 (Gap ranking)

### 🔴 P0 ブロッカー (絶対に塞ぐべき)

なし。P0 の **コア機能はすべて実装済みで動作している**。ルーティン作成 → Runner 実行 → 履歴記録 → DayLog 入力 という基本ループはユーザーが今日からオフラインで一通り使える。

### 🟠 P0 重要 (リリース前に塞いだほうがいい)

1. **`RoutinePickerSheet` (Runner ピッカー) の reorder / pin UI が無い** — `WorkoutView` 経由でしか並び替え / ピン留めができない。Runner からルーティンを選ぶたびに古い updatedAt 順で並ぶため、ルーティン件数が増えると使いづらい。
2. **ルーティン検索 / フィルターが無い** — `.searchable` 一行で済むが、件数増加時の P0 ループの足を引っ張る。
3. **Runner 復帰のテスト不足** — 機能としては実装済みで挙動も妥当だが、自動テストが薄い。Step / Routine モデル変更時の回帰検出が効かない。

### 🟢 ポリッシュ

- アクセシビリティ ベースラインの監査 (Runner 以外の画面)
- マニュアル QA に「音 off / 触覚 on」「kill 後の Runner 復帰」 のケース追加
- `SoundHapticManager` / `ScreenWakeManager` の組合せ条件の自動テスト

### 🔵 P1 / P2 / 延期

- ジム自動取り込み (現状サーバー側 token 基盤まで完成。iOS `TokenProvider` / `GymMachineImportService` は別 PR、しかも credential strategy の合意に従う必要あり)
- HealthKit 連携 (P2)
- Widget / Live Activity (P2)
- AI Coach / 食事推定 (P2)

## 5. 次の実装 PR の推奨 (Recommended next implementation PR)

**推奨**: **PR-A: ルーティン一覧の検索 / フィルター + `RoutinePickerSheet` の reorder / pin UI**

理由:

- P0 ループ上でユーザーが「今すぐ困る」 唯一の領域。
- 既存の `RoutineOrderStore.setPinned(...)` / `.move(fromOffsets:toOffset:pinned:)` を流用すれば、新規ロジックほぼゼロで UI だけ追加するだけで完結する。リスクが最小。
- 単一 PR で完結し、レビューも軽い。
- マニュアル QA に組み込みやすい (件数を増やしてピン / 並び替え / 検索を試すだけ)。

**次点 (PR-B)**: Runner 復帰系の Swift Testing 追加 + `Pulse CueTests/RunnerStateMachineTests` の拡充 (背景遷移時の `restDeadline` 再計算、Session.status の整合性、二重通知発生防止のリグレッション)。これは仕様変更ゼロのテスト純増 PR。

> なお、要件文書側で示唆される「DayLog Home クイック入力」は既に PR #14 で実装済みなので、改めて完成タスクとして切る必要はない (本監査の根拠は `Pulse Cue/Views/DayLogQuickInputSheet.swift` の存在)。Today カードのコピー / 配置がさらに磨けるかは別の UI ポリッシュ PR の話。

## 6. スコープ外 (Out of scope)

- AI 食事推定 (今後)
- AI Coach (今後)
- ログイン / 同期 (今後)
- Worker import の iOS 統合 (PR-γ 系で、credential strategy 確定後)
- HealthKit
- Widget / Live Activity
- アドバンスドな分析 / グラフ

## 7. 後続 PR 一覧 (Follow-up PR list)

依存と優先度を踏まえた順序:

- **PR-A** (本監査の推奨): ルーティン検索 + `RoutinePickerSheet` の並び替え / ピン UI 拡充。
- **PR-B**: Runner 復帰系 + Sound/Haptic/ScreenWake 組合せの Swift Testing 追加。仕様変更ゼロ。
- **PR-C**: アクセシビリティ ベースラインの監査 + Runner 以外の画面 (Today / History / Settings) の VoiceOver ラベル整備。
- **PR-D**: マニュアル QA チェックリストの再整理 ( `Docs/manual-qa-checklist.md` が章節 ~10 を超えてきたので、優先度別に並べ替え + P0 章を独立化)。
- **PR-E** (要件外だが計画済み): iOS `TokenProvider` + `KeychainTokenStore` (PR-γ1 in `Docs/import-token-endpoint-spec.md` §10)。**App Attest 本検証 (PR-β2) の前段ではあるが、本監査の優先度では PR-A〜D 後**。
- **PR-F**: iOS `GymMachineImportService` (PR-γ2)。サーバー側 PR #27 / #28 が既に着地済みのため、PR-E 後に小さく入る。

---

> **更新ルール**: 本監査は `main` の `f9b6741` 時点のスナップショット。大きなリリースの直前にもう一度行うことを推奨する。
> 採用優先度や延期判断は本ファイル末尾に決定日付付きで追記して残す。
