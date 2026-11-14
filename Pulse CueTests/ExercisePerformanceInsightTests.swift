//
//  ExercisePerformanceInsightTests.swift
//  Pulse CueTests
//
//  Unit tests for the pure Previous Performance query and Progression rule:
//  exercise matching by stable exerciseId, latest-session selection,
//  completed-set filtering, current-session exclusion, determinism, and the
//  conservative reps guidance (achieve → +1, miss → hold, no data / cardio →
//  none). Fixtures are plain model objects; no ModelContext / persistence.
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct ExercisePerformanceInsightTests {

    private func step(_ exerciseId: String?, id: UUID = UUID()) -> Step {
        Step(id: id, routineId: UUID(), order: 0, title: "x", sets: 3, repsTarget: 10, restSeconds: 60, exerciseId: exerciseId)
    }

    private func session(_ id: UUID, daysAgo: Int) -> Session {
        Session(id: id, routineId: UUID(), dayDate: .now, startedAt: Date().addingTimeInterval(TimeInterval(-daysAgo * 86_400)), status: .completed)
    }

    private func result(_ sessionId: UUID, _ stepId: UUID, set: Int, reps: Int?, done: Bool = true) -> StepResult {
        StepResult(sessionId: sessionId, stepId: stepId, setIndex: set, done: done, actualReps: reps)
    }

    // MARK: - Previous Performance

    @Test
    func noHistoryYieldsNil() {
        let s = step("bench_press")
        let result = PreviousPerformanceQuery.latest(
            exerciseId: "bench_press", excludingSessionId: nil,
            steps: [s], sessions: [], results: []
        )
        #expect(result == nil)
    }

    @Test
    func matchesExerciseByStableIdAndReturnsCompletedReps() {
        let bench = step("bench_press")
        let sess = session(UUID(), daysAgo: 2)
        let results = [
            result(sess.id, bench.id, set: 0, reps: 10),
            result(sess.id, bench.id, set: 1, reps: 10),
            result(sess.id, bench.id, set: 2, reps: 9),
        ]
        let perf = PreviousPerformanceQuery.latest(
            exerciseId: "bench_press", excludingSessionId: nil,
            steps: [bench], sessions: [sess], results: results
        )
        #expect(perf?.setReps == [10, 10, 9])
    }

    @Test
    func selectsLatestSessionAndIgnoresOlder() {
        let bench = step("bench_press")
        let older = session(UUID(), daysAgo: 7)
        let newer = session(UUID(), daysAgo: 2)
        let results = [
            result(older.id, bench.id, set: 0, reps: 8),
            result(newer.id, bench.id, set: 0, reps: 10),
            result(newer.id, bench.id, set: 1, reps: 10),
        ]
        let perf = PreviousPerformanceQuery.latest(
            exerciseId: "bench_press", excludingSessionId: nil,
            steps: [bench], sessions: [older, newer], results: results
        )
        #expect(perf?.setReps == [10, 10]) // newer session, not the older 8
    }

    @Test
    func ignoresIncompleteSetsAndOtherExercises() {
        let bench = step("bench_press")
        let chest = step("chest_press")
        let sess = session(UUID(), daysAgo: 1)
        let results = [
            result(sess.id, bench.id, set: 0, reps: 10),
            result(sess.id, bench.id, set: 1, reps: nil, done: false), // skipped
            result(sess.id, chest.id, set: 0, reps: 12),               // other exercise
        ]
        let perf = PreviousPerformanceQuery.latest(
            exerciseId: "bench_press", excludingSessionId: nil,
            steps: [bench, chest], sessions: [sess], results: results
        )
        #expect(perf?.setReps == [10]) // only the completed bench set
    }

    @Test
    func excludesTheInProgressSession() {
        let bench = step("bench_press")
        let past = session(UUID(), daysAgo: 3)
        let current = session(UUID(), daysAgo: 0)
        let results = [
            result(past.id, bench.id, set: 0, reps: 9),
            result(current.id, bench.id, set: 0, reps: 10), // this session, must be ignored
        ]
        let perf = PreviousPerformanceQuery.latest(
            exerciseId: "bench_press", excludingSessionId: current.id,
            steps: [bench], sessions: [past, current], results: results
        )
        #expect(perf?.setReps == [9]) // the past session, not the current 10
    }

    @Test
    func matchesReplacedExerciseIdentityAcrossRoutines() {
        // A later routine's step carries the same exerciseId (e.g. after an
        // Exercise Replacement swapped to it): history is still found by id.
        let originalStep = step("chest_press")
        let swappedInStep = step("chest_press") // different Step object / routine
        let sess = session(UUID(), daysAgo: 2)
        let results = [result(sess.id, originalStep.id, set: 0, reps: 11)]
        let perf = PreviousPerformanceQuery.latest(
            exerciseId: "chest_press", excludingSessionId: nil,
            steps: [originalStep, swappedInStep], sessions: [sess], results: results
        )
        #expect(perf?.setReps == [11])
    }

    @Test
    func queryIsDeterministic() {
        let bench = step("bench_press")
        let a = session(UUID(), daysAgo: 2)
        let b = session(UUID(), daysAgo: 2) // same date → id tie-break
        let results = [
            result(a.id, bench.id, set: 0, reps: 10),
            result(b.id, bench.id, set: 0, reps: 8),
        ]
        let first = PreviousPerformanceQuery.latest(exerciseId: "bench_press", excludingSessionId: nil, steps: [bench], sessions: [a, b], results: results)
        let second = PreviousPerformanceQuery.latest(exerciseId: "bench_press", excludingSessionId: nil, steps: [bench], sessions: [a, b], results: results)
        #expect(first == second)
    }

    // MARK: - Progression

    @Test
    func achievingEverySetSuggestsOneMoreRep() {
        let prev = PreviousPerformance(date: .now, setReps: [10, 10, 10])
        let s = ProgressionRule.suggest(previous: prev, baselineReps: 10, expectedSets: 3, allowsRepProgression: true, allowsWeightProgression: true)
        #expect(s?.suggestedReps == 11)
        #expect(s?.isProgression == true)
    }

    @Test
    func missingASetHoldsTheTarget() {
        let prev = PreviousPerformance(date: .now, setReps: [10, 10, 8])
        let s = ProgressionRule.suggest(previous: prev, baselineReps: 10, expectedSets: 3, allowsRepProgression: true, allowsWeightProgression: true)
        #expect(s?.suggestedReps == 10)
        #expect(s?.isProgression == false)
    }

    @Test
    func clearRegressionHoldsTheTarget() {
        let prev = PreviousPerformance(date: .now, setReps: [6, 5, 5])
        let s = ProgressionRule.suggest(previous: prev, baselineReps: 10, expectedSets: 3, allowsRepProgression: true, allowsWeightProgression: true)
        #expect(s?.suggestedReps == 10)
    }

    @Test
    func noPreviousDataYieldsNoSuggestion() {
        #expect(ProgressionRule.suggest(previous: nil, baselineReps: 10, expectedSets: 3, allowsRepProgression: true, allowsWeightProgression: true) == nil)
    }

    @Test
    func nonRepExerciseYieldsNoSuggestion() {
        // e.g. cardio — rep progression makes no sense.
        let prev = PreviousPerformance(date: .now, setReps: [10, 10, 10])
        #expect(ProgressionRule.suggest(previous: prev, baselineReps: 10, expectedSets: 3, allowsRepProgression: false, allowsWeightProgression: true) == nil)
    }
}

/// Weighted progression: load increase only when last time is unambiguous,
/// reps-only fallback otherwise, and the Runner card wording.
struct WeightedProgressionRuleTests {

    private func prev(_ reps: [Int], _ weights: [Double?]) -> PreviousPerformance {
        PreviousPerformance(date: .now, sets: zip(reps, weights).map { PreviousSetPerformance(reps: $0, weightKg: $1) })
    }

    private func suggest(_ p: PreviousPerformance?, sets: Int = 3, reps: Bool = true, weight: Bool = true) -> ProgressionSuggestion? {
        ProgressionRule.suggest(previous: p, baselineReps: 10, expectedSets: sets, allowsRepProgression: reps, allowsWeightProgression: weight)
    }

    @Test func sameWeightEverySetAtTargetIncreasesWeight() {
        let s = suggest(prev([10, 10, 10], [60, 60, 60]))
        #expect(s?.kind == .increaseWeight)
        #expect(s?.suggestedWeightKg == 62.5)
        #expect(s?.suggestedReps == 10)
        #expect(s?.previousWorkingWeightKg == 60)
    }

    @Test func aMissedSetHoldsTheWeightNeverDeloads() {
        let s = suggest(prev([10, 10, 9], [60, 60, 60]))
        #expect(s?.kind == .holdWeight)
        #expect(s?.suggestedWeightKg == 60)
        #expect(s?.suggestedReps == 10)
        let worse = suggest(prev([10, 9, 8], [60, 60, 60]))
        #expect(worse?.suggestedWeightKg == 60)
    }

    @Test func fewerSetsThanExpectedNeverProgresses() {
        for p in [prev([10, 10], [60, 60]), prev([10], [60]), prev([10, 10], [nil, nil])] {
            let s = suggest(p)
            #expect(s?.kind == .holdReps)
            #expect(s?.suggestedReps == 10)
            #expect(s?.suggestedWeightKg == nil)
        }
    }

    @Test func moreSetsThanExpectedNeverProgresses() {
        let s = suggest(prev([10, 10, 10, 10], [60, 60, 60, 60]))
        #expect(s?.kind == .holdReps)
        #expect(s?.suggestedWeightKg == nil)
    }

    @Test func mixedWeightsNeverPickAWorkingWeight() {
        let s = suggest(prev([10, 10, 10], [60, 60, 57.5]))
        #expect(s?.suggestedWeightKg == nil)
        #expect(s?.kind != .increaseWeight)
        #expect(s?.kind != .holdWeight)
    }

    @Test func partlyMissingWeightNeverIncreasesLoad() {
        let s = suggest(prev([10, 10, 10], [60, nil, 60]))
        #expect(s?.suggestedWeightKg == nil)
        #expect(s?.kind != .increaseWeight)
    }

    @Test func legacyHistoryWithoutWeightKeepsTheRepRule() {
        let up = suggest(prev([10, 10, 10], [nil, nil, nil]))
        #expect(up?.kind == .increaseReps)
        #expect(up?.suggestedReps == 11)
        #expect(up?.suggestedWeightKg == nil)
        let hold = suggest(prev([10, 10, 8], [nil, nil, nil]))
        #expect(hold?.kind == .holdReps)
        #expect(hold?.suggestedReps == 10)
    }

    @Test func zeroKilogramsFallsBackToReps() {
        let s = suggest(prev([10, 10, 10], [0, 0, 0]))
        #expect(s?.kind == .increaseReps)
        #expect(s?.suggestedWeightKg == nil)
        #expect(s?.suggestedReps == 11)
    }

    @Test func neverSuggestsAboveTheMaximum() {
        let s = suggest(prev([10, 10, 10], [SetWeight.maximumKg, SetWeight.maximumKg, SetWeight.maximumKg]))
        #expect(s?.kind == .holdWeight)
        #expect(s?.suggestedWeightKg == SetWeight.maximumKg)
        let near = suggest(prev([10, 10, 10], [999, 999, 999]))
        #expect((near?.suggestedWeightKg ?? 0) <= SetWeight.maximumKg)
        #expect(near?.kind == .holdWeight)
    }

    @Test func cardioOrNonRepYieldsNoSuggestion() {
        #expect(suggest(prev([10, 10, 10], [60, 60, 60]), reps: false) == nil)
    }

    @Test func weightUntrackedExerciseUsesTheRepRuleOnly() {
        // e.g. a duration-based exercise: load never drives the suggestion.
        let s = suggest(prev([10, 10, 10], [60, 60, 60]), weight: false)
        #expect(s?.kind == .increaseReps)
        #expect(s?.suggestedWeightKg == nil)
    }

    @Test func insufficientHistoryYieldsNothing() {
        #expect(suggest(nil) == nil)
        #expect(suggest(PreviousPerformance(date: .now, sets: [])) == nil)
    }

    @Test func incrementIsOneConstant() {
        #expect(ProgressionRule.weightIncrementKg == 2.5)
    }

    @Test func repsAndWeightStayPairedPerSet() {
        let p = PreviousPerformance(date: .now, setReps: [10, 9], setWeightsKg: [60])
        #expect(p.sets == [PreviousSetPerformance(reps: 10, weightKg: 60), PreviousSetPerformance(reps: 9, weightKg: nil)])
        #expect(p.setReps == [10, 9])
        #expect(p.setWeightsKg == [60, nil])
    }

    // MARK: - Presentation

    @Test func weightIncreaseText() throws {
        let s = try #require(suggest(prev([10, 10, 10], [60, 60, 60])))
        #expect(ProgressionPresentation.suggestionText(s) == "62.5 kg・各セット 10 回")
        #expect(ProgressionPresentation.reasonText(s) == "前回は同じ重量で全セット目標回数を達成")
        #expect(ProgressionPresentation.applyAccessibilityLabel(s) == "目安の重量とレップ数を適用")
        #expect(ProgressionPresentation.previousText(prev([10, 10, 10], [60, 60, 60])) == "60 kg × 10 / 10 / 10 回")
    }

    @Test func weightedHoldText() throws {
        let s = try #require(suggest(prev([10, 10, 9], [60, 60, 60])))
        #expect(ProgressionPresentation.suggestionText(s) == "60 kg・各セット 10 回")
        #expect(ProgressionPresentation.reasonText(s) == nil)
    }

    @Test func legacyRepTextIsUnchanged() throws {
        let up = try #require(suggest(prev([10, 10, 10], [nil, nil, nil])))
        #expect(ProgressionPresentation.suggestionText(up) == "各セット 10〜11 回")
        #expect(ProgressionPresentation.applyAccessibilityLabel(up) == "目安のレップ数を適用")
        #expect(ProgressionPresentation.previousText(prev([10, 10, 10], [nil, nil, nil])) == "10 / 10 / 10 回")
        let hold = try #require(suggest(prev([10, 10], [nil, nil])))
        #expect(ProgressionPresentation.suggestionText(hold) == "各セット 10 回")
    }

    @Test func mixedWeightTextKeepsEachSetPaired() {
        #expect(ProgressionPresentation.previousText(prev([10, 10, 9], [60, 60, 57.5])) == "60\u{00A0}kg×10 / 60\u{00A0}kg×10 / 57.5\u{00A0}kg×9")
        #expect(ProgressionPresentation.previousText(prev([10, 8], [60, nil])) == "60\u{00A0}kg×10 / 8回")
    }
}

