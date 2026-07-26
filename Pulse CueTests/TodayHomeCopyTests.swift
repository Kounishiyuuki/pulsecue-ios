//
//  TodayHomeCopyTests.swift
//  Pulse CueTests
//
//  Guards two Home contracts touched by the UI-simplification PR:
//   - the condition copy maps purely to recording completeness (0...4) and
//     makes no health/physiological claim,
//   - the tab set is the intended 4 tabs (no lingering Runner tab).
//

import Testing
@testable import Pulse_Cue

struct TodayHomeCopyTests {

    // MARK: - Condition copy mapping

    @Test func headlineMapsToRecordingCompleteness() {
        #expect(TodayConditionCopy.headline(filledCount: 0) == "今日をはじめよう")
        #expect(TodayConditionCopy.headline(filledCount: 1) == "今日を記録中")
        #expect(TodayConditionCopy.headline(filledCount: 2) == "今日を記録中")
        #expect(TodayConditionCopy.headline(filledCount: 3) == "記録がそろってきました")
        #expect(TodayConditionCopy.headline(filledCount: 4) == "今日の記録がそろいました")
    }

    @Test func subheadMapsForEachCount() {
        #expect(TodayConditionCopy.subhead(filledCount: 0) == "コンディションを記録して1日を始めましょう")
        #expect(TodayConditionCopy.subhead(filledCount: 1) == "記録を続けましょう")
        #expect(TodayConditionCopy.subhead(filledCount: 2) == "半分ほど記録できました")
        #expect(TodayConditionCopy.subhead(filledCount: 3) == "あと1項目で今日の記録が完了します")
        #expect(TodayConditionCopy.subhead(filledCount: 4) == "本日のコンディション記録は完了です")
    }

    @Test func copyMakesNoHealthQualityClaim() {
        // Regression guard: the misleading physiological labels are gone.
        let banned = ["絶好調", "良好", "順調"]
        for count in 0...4 {
            let text = TodayConditionCopy.headline(filledCount: count)
                + TodayConditionCopy.subhead(filledCount: count)
            for word in banned {
                #expect(!text.contains(word))
            }
        }
    }

    @Test func outOfRangeCountsAreHandled() {
        // Defensive: negative / >4 never trap and stay sensible.
        #expect(TodayConditionCopy.headline(filledCount: -1) == "今日をはじめよう")
        #expect(TodayConditionCopy.headline(filledCount: 9) == "今日の記録がそろいました")
    }

    // MARK: - Tab structure

    @Test func tabSetIsTheFourIntendedTabs() {
        #expect(AppTab.allCases == [.today, .workout, .history, .settings])
        #expect(AppTab.allCases.count == 4)
    }
}
