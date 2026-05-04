# Widget / Live Activity 設計メモ（v3 候補）

P0 では新規 Xcode ターゲットを増やすリスクを避けるため、本ドキュメントの段階では **Widget / Live Activity の本実装は行いません**。代わりに、必要な設計判断と段取りをまとめ、実装時の手戻りを最小化します。

## ゴール

ジムで片手・グローブ越しでも瞬時に状況がわかること。

| サーフェス | 内容 |
| --- | --- |
| ホーム画面ウィジェット (small) | 今のステップ名 / 何セット中 / 残り休憩 or「実行中」 |
| ホーム画面ウィジェット (medium) | ↑ + 次のステップ |
| ロック画面 / Dynamic Island Compact | 残り休憩 mm:ss、休憩終了で⌛️→⚡️ |
| Dynamic Island Expanded | Now / Rest / Next の 3 セクション、+10 ボタン |

## 必要なターゲット追加（実装時に Xcode で行う）

1. **`PulseCueWidget`** — App Extension / Widget Extension
   - Bundle ID: `y.Pulse-Cue.Widget`
   - Deployment target: iOS 17.0
   - Frameworks: `WidgetKit`, `SwiftUI`, `ActivityKit`（Live Activity 同居）, `SwiftData`（共有 ModelContainer）
2. **App Group** — `group.y.Pulse-Cue`
   - メインアプリと拡張で SwiftData ストア + UserDefaults を共有するため、両ターゲットの Capabilities に追加
3. **Info.plist 追記**（メインアプリ側）
   - `NSSupportsLiveActivities = YES`
   - `NSSupportsLiveActivitiesFrequentUpdates = YES`（休憩タイマーの 1Hz 更新用）

> 上記はすべて Xcode の Capabilities タブから操作するのが最も安全。`project.pbxproj` を手で書き換えるのは避ける。

## 共有レイヤ

メインアプリと拡張で重複コードを書かないよう、以下を **Shared/** モジュール化（コピーで十分、ターゲット追加時に同じ Swift ファイルを両方のメンバーに含める）：

- `RunnerPersistence`（既存。共有 UserDefaults suite を使うよう書き換え）
- `RunnerPersistentState`
- `Step` / `Routine`（@Model はメインターゲットの SwiftData コンテナを共有）
- 新規 `RunnerSnapshot`：拡張が読み取り専用で扱えるイミュータブル DTO

```swift
struct RunnerSnapshot: Codable, Sendable {
    let phase: RunnerPhase
    let stepTitle: String?
    let nextStepTitle: String?
    let setIndex: Int
    let setsTotal: Int
    let restDeadline: Date?
    let updatedAt: Date
}
```

メインアプリの `RunnerViewModel` が状態変化のたびに `RunnerSnapshot` を共有 UserDefaults（`group.y.Pulse-Cue` suite）に書き出す。Widget は `TimelineProvider` でこれを読み出す。

## TimelineProvider 戦略

- **Snapshot**：直近の `RunnerSnapshot` をそのまま返す。
- **Timeline**：
  - `restDeadline` がある場合：今 → 1 秒ごと → `restDeadline + 1s` までエントリを生成（コストは数十エントリで OK）。`restDeadline` 到達後は「休憩終了」エントリを 1 件追加。
  - `restDeadline` が無い場合：単一エントリで `policy: .never` を返し、メインアプリが書き換えた時に `WidgetCenter.shared.reloadAllTimelines()` で再描画させる。

## Live Activity 戦略

- `ActivityKit.Activity<RunnerAttributes>` を `RunnerViewModel.startRest(for:)` で開始、`onRestFinished` / `finishSession` / `endSessionEarly` で `await activity.end(...)` する。
- `ContentState`：`restDeadline` のみ（または `RunnerSnapshot` を抜粋）。`Date.now ..< deadline` を `ProgressView(timerInterval:)` に渡せばシステムが 1Hz 描画を担当するため、頻繁更新エンタイトルメントは不要。
- Dynamic Island Expanded の右領域に `Button(intent: ExtendRestIntent())` を置き、AppIntents で +10 を実装する（同じ AppIntent を Workout タブのショートカットからも使える）。

## やらないこと（v3 範囲外）

- Apple Watch アプリ
- watchOS Live Activity
- HealthKit ベースのウィジェット（HealthKit 統合後に検討）
- 通知拡張（`UNNotificationServiceExtension`）

## チェックリスト（実装着手時に上から順に）

- [ ] App Group `group.y.Pulse-Cue` を Apple Developer 上で作成・Capabilities に追加
- [ ] `RunnerPersistence` を `UserDefaults(suiteName: "group.y.Pulse-Cue")` 化（既存テストへの影響を確認）
- [ ] `RunnerSnapshot` 型 + `RunnerViewModel` の書き出しフックを追加
- [ ] `PulseCueWidget` ターゲットを Xcode から追加（`File > New > Target > Widget Extension`）
- [ ] WidgetEntryView を SwiftUI で実装、`small` / `medium` の 2 ファミリーに対応
- [ ] Live Activity の Attributes / ContentState を実装
- [ ] `WidgetCenter.shared.reloadAllTimelines()` を Runner 状態遷移時に呼ぶ
- [ ] AppIntent `ExtendRestIntent` を実装し、Dynamic Island の +10 ボタンと連携

## 参考

- [WidgetKit](https://developer.apple.com/documentation/widgetkit)
- [ActivityKit](https://developer.apple.com/documentation/activitykit)
- [App Intents](https://developer.apple.com/documentation/appintents)
