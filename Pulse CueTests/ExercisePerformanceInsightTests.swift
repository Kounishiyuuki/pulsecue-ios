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

    private func step(_ exerciseId: String?, id: UUID = UUID(), order: Int = 0) -> Step {
        Step(id: id, routineId: UUID(), order: order, title: "x", sets: 3, repsTarget: 10, restSeconds: 60, exerciseId: exerciseId)
    }

    private func session(_ id: UUID, daysAgo: Int, status: SessionStatus = .completed) -> Session {
        Session(id: id, routineId: UUID(), dayDate: .now, startedAt: Date().addingTimeInterval(TimeInterval(-daysAgo * 86_400)), status: status)
    }

    private func result(_ sessionId: UUID, _ stepId: UUID, set: Int, reps: Int?, done: Bool = true) -> StepResult {
        StepResult(sessionId: sessionId, stepId: stepId, setIndex: set, done: done, actualReps: reps)
    }

    // MARK: - Previous Performance

    @Test
    func noHistoryYieldsNil() {
        let s = step("bench_press")
        let result = PreviousPerformanceQuery.latest(
            exerciseId: "bench_press", excludingSessionId: nil, expectedSets: 3,
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
            exerciseId: "bench_press", excludingSessionId: nil, expectedSets: 3,
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
            exerciseId: "bench_press", excludingSessionId: nil, expectedSets: 3,
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
            exerciseId: "bench_press", excludingSessionId: nil, expectedSets: 3,
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
            exerciseId: "bench_press", excludingSessionId: current.id, expectedSets: 3,
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
            exerciseId: "chest_press", excludingSessionId: nil, expectedSets: 3,
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
        let first = PreviousPerformanceQuery.latest(exerciseId: "bench_press", excludingSessionId: nil, expectedSets: 3, steps: [bench], sessions: [a, b], results: results)
        let second = PreviousPerformanceQuery.latest(exerciseId: "bench_press", excludingSessionId: nil, expectedSets: 3, steps: [bench], sessions: [a, b], results: results)
        #expect(first == second)
    }

    // MARK: - Which session counts as "last time"

    /// `count` done sets of 10 reps (and 60 kg) for `stepId` in `sessionId`.
    private func sets(_ sessionId: UUID, _ stepId: UUID, done count: Int, skipped: Int = 0) -> [StepResult] {
        (0..<count).map { StepResult(sessionId: sessionId, stepId: stepId, setIndex: $0, done: true, actualReps: 10, weightKg: 60) }
            + (count..<(count + skipped)).map { StepResult(sessionId: sessionId, stepId: stepId, setIndex: $0, done: false, actualReps: nil) }
    }

    private func latest(_ bench: Step, _ sessions: [Session], _ results: [StepResult], excluding: UUID? = nil) -> PreviousPerformance? {
        PreviousPerformanceQuery.latest(exerciseId: "bench_press", excludingSessionId: excluding, expectedSets: 3, steps: [bench], sessions: sessions, results: results)
    }

    @Test
    func newerAbandonedPartialDoesNotHideAnOlderFullRecord() {
        let bench = step("bench_press")
        let full = session(UUID(), daysAgo: 5)
        let partial = session(UUID(), daysAgo: 3, status: .abandoned)
        let perf = latest(bench, [full, partial], sets(full.id, bench.id, done: 3) + sets(partial.id, bench.id, done: 1))
        #expect(perf?.date == full.startedAt)
        #expect(perf?.sets.count == 3)
    }

    @Test
    func inProgressSessionIsNeverLastTime() {
        let bench = step("bench_press")
        let full = session(UUID(), daysAgo: 5)
        let running = session(UUID(), daysAgo: 1, status: .inProgress)
        let perf = latest(bench, [full, running], sets(full.id, bench.id, done: 3) + sets(running.id, bench.id, done: 3))
        #expect(perf?.date == full.startedAt)
        // Only an in-progress record → nothing to show.
        #expect(latest(bench, [running], sets(running.id, bench.id, done: 3)) == nil)
    }

    @Test
    func abandonedSessionWithThisExerciseFullyDoneCounts() {
        let bench = step("bench_press")
        let older = session(UUID(), daysAgo: 7)
        let abandoned = session(UUID(), daysAgo: 2, status: .abandoned)
        let perf = latest(bench, [older, abandoned], sets(older.id, bench.id, done: 3) + sets(abandoned.id, bench.id, done: 3))
        #expect(perf?.date == abandoned.startedAt)
    }

    @Test
    func withoutAnyFullRecordTheNewestPartialIsShownAndHeld() throws {
        let bench = step("bench_press")
        let older = session(UUID(), daysAgo: 7, status: .abandoned)
        let newer = session(UUID(), daysAgo: 2, status: .abandoned)
        let perf = try #require(latest(bench, [older, newer], sets(older.id, bench.id, done: 1) + sets(newer.id, bench.id, done: 2)))
        #expect(perf.date == newer.startedAt)
        #expect(perf.sets.count == 2)
        let s = ProgressionRule.suggest(previous: perf, baselineReps: 10, expectedSets: 3, allowsRepProgression: true, allowsWeightProgression: true)
        #expect(s?.kind == .holdReps)
        #expect(s?.suggestedWeightKg == nil)
    }

    @Test
    func resumedSessionCountsOnlyOnceFinished() {
        let bench = step("bench_press")
        let older = session(UUID(), daysAgo: 7)
        let resumed = session(UUID(), daysAgo: 1, status: .inProgress)
        let olderSets = sets(older.id, bench.id, done: 3)
        #expect(latest(bench, [older, resumed], olderSets + sets(resumed.id, bench.id, done: 1))?.date == older.startedAt)
        resumed.status = .completed
        #expect(latest(bench, [older, resumed], olderSets + sets(resumed.id, bench.id, done: 3))?.date == resumed.startedAt)
    }

    @Test
    func completedSessionWithSkippedSetsIsNotAFullRecord() {
        let bench = step("bench_press")
        let full = session(UUID(), daysAgo: 7)
        let skipped = session(UUID(), daysAgo: 2) // .completed, but 2 of 3 skipped
        let perf = latest(bench, [full, skipped], sets(full.id, bench.id, done: 3) + sets(skipped.id, bench.id, done: 1, skipped: 2))
        #expect(perf?.date == full.startedAt)
    }

    @Test
    func newestOfSeveralFullRecordsWins() {
        let bench = step("bench_press")
        let a = session(UUID(), daysAgo: 9)
        let b = session(UUID(), daysAgo: 4)
        let c = session(UUID(), daysAgo: 6, status: .abandoned)
        let perf = latest(bench, [a, b, c], sets(a.id, bench.id, done: 3) + sets(b.id, bench.id, done: 3) + sets(c.id, bench.id, done: 3))
        #expect(perf?.date == b.startedAt)
    }

    // MARK: Duplicated steps of one exercise in one session

    /// `count` done sets for `stepId`, each at `weight` and `reps`.
    private func stepSets(_ sessionId: UUID, _ stepId: UUID, done count: Int, weight: Double = 60, reps: Int = 10) -> [StepResult] {
        (0..<count).map { StepResult(sessionId: sessionId, stepId: stepId, setIndex: $0, done: true, actualReps: reps, weightKg: weight) }
    }

    private func latest(_ steps: [Step], _ sessions: [Session], _ results: [StepResult], order: Int?) -> PreviousPerformance? {
        PreviousPerformanceQuery.latest(exerciseId: "bench_press", excludingSessionId: nil, expectedSets: 3, currentStepOrder: order, steps: steps, sessions: sessions, results: results)
    }

    @Test
    func fullStepWinsOverItsPartialDuplicateInTheSameSession() {
        let a = step("bench_press", order: 0), b = step("bench_press", order: 1)
        let sess = session(UUID(), daysAgo: 2)
        let perf = latest([a, b], [sess], stepSets(sess.id, a.id, done: 3, weight: 80) + stepSets(sess.id, b.id, done: 1, weight: 50), order: 1)
        #expect(perf?.sets.count == 3)
        #expect(perf?.setWeightsKg == [80, 80, 80])
    }

    @Test
    func twoPartialStepsNeverAddUpToAFullRecord() throws {
        let a = step("bench_press", order: 0), b = step("bench_press", order: 1)
        let sess = session(UUID(), daysAgo: 2)
        let perf = try #require(latest([a, b], [sess], stepSets(sess.id, a.id, done: 2) + stepSets(sess.id, b.id, done: 1), order: 0))
        #expect(perf.sets.count == 2) // step A alone, not 2 + 1
        let s = ProgressionRule.suggest(previous: perf, baselineReps: 10, expectedSets: 3, allowsRepProgression: true, allowsWeightProgression: true)
        #expect(s?.kind == .holdReps)
        #expect(s?.suggestedWeightKg == nil)
    }

    @Test
    func twoFullStepsAreNotSixSetsAndThePickIsStable() {
        let a = step("bench_press", id: UUID(), order: 0), b = step("bench_press", id: UUID(), order: 1)
        let sess = session(UUID(), daysAgo: 2)
        let results = stepSets(sess.id, a.id, done: 3, weight: 80) + stepSets(sess.id, b.id, done: 3, weight: 50)
        // No order match → lowest order (A), regardless of input order.
        let first = latest([a, b], [sess], results, order: 5)
        let second = latest([b, a], [sess], results.reversed(), order: 5)
        #expect(first?.sets.count == 3)
        #expect(first?.setWeightsKg == [80, 80, 80])
        #expect(first == second)
    }

    @Test
    func twoPartialStepsAreNotMixedIntoFourSets() {
        let a = step("bench_press", order: 0), b = step("bench_press", order: 1)
        let sess = session(UUID(), daysAgo: 2)
        let perf = latest([a, b], [sess], stepSets(sess.id, a.id, done: 2, weight: 80) + stepSets(sess.id, b.id, done: 2, weight: 50), order: 0)
        #expect(perf?.sets.count == 2)
        #expect(perf?.setWeightsKg == [80, 80])
    }

    @Test
    func matchingStepOrderWinsAmongFullDuplicates() {
        let a = step("bench_press", order: 0), b = step("bench_press", order: 1)
        let sess = session(UUID(), daysAgo: 2)
        let results = stepSets(sess.id, a.id, done: 3, weight: 80) + stepSets(sess.id, b.id, done: 3, weight: 50)
        #expect(latest([a, b], [sess], results, order: 1)?.setWeightsKg == [50, 50, 50])
        #expect(latest([a, b], [sess], results, order: 0)?.setWeightsKg == [80, 80, 80])
    }

    @Test
    func fullDuplicateInAnOlderSessionBeatsANewerPartialStep() {
        let a = step("bench_press", order: 0), b = step("bench_press", order: 1)
        let older = session(UUID(), daysAgo: 7)
        let newer = session(UUID(), daysAgo: 2, status: .abandoned)
        let results = stepSets(older.id, a.id, done: 3) + stepSets(newer.id, a.id, done: 2) + stepSets(newer.id, b.id, done: 1)
        let perf = latest([a, b], [older, newer], results, order: 0)
        #expect(perf?.date == older.startedAt)
        #expect(perf?.sets.count == 3)
    }

    @Test
    func otherExercisesNeverCountTowardTheSetTotal() {
        let bench = step("bench_press")
        let squat = step("barbell_squat")
        let full = session(UUID(), daysAgo: 7)
        let newer = session(UUID(), daysAgo: 2, status: .abandoned)
        // The newer session has 3 done sets in total, but only 1 is bench.
        let results = sets(full.id, bench.id, done: 3) + sets(newer.id, bench.id, done: 1) + sets(newer.id, squat.id, done: 2)
        let perf = PreviousPerformanceQuery.latest(exerciseId: "bench_press", excludingSessionId: nil, expectedSets: 3, steps: [bench, squat], sessions: [full, newer], results: results)
        #expect(perf?.date == full.startedAt)
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
        #expect(s?.kind == .increaseReps)
        #expect(s?.suggestedReps == 11)
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

    @Test func incrementLandingExactlyOnTheMaximumIsAllowed() {
        let s = suggest(prev([10, 10, 10], [997.5, 997.5, 997.5]))
        #expect(s?.kind == .increaseWeight)
        #expect(s?.suggestedWeightKg == 1000.0)
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
        #expect(ProgressionPresentation.suggestionText(s) == "62.5\u{00A0}kg・各セット 10 回")
        #expect(ProgressionPresentation.reasonText(s) == "前回は同じ重量で全セット目標回数を達成")
        #expect(ProgressionPresentation.applyAccessibilityLabel(s) == "目安の重量とレップ数を適用")
        #expect(ProgressionPresentation.previousText(prev([10, 10, 10], [60, 60, 60])) == "60\u{00A0}kg × 10 / 10 / 10 回")
    }

    @Test func weightedHoldText() throws {
        let s = try #require(suggest(prev([10, 10, 9], [60, 60, 60])))
        #expect(ProgressionPresentation.suggestionText(s) == "60\u{00A0}kg・各セット 10 回")
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

    @Test func weightTextNeverSplitsNumberFromUnit() {
        #expect(ProgressionPresentation.weightText(62.5) == "62.5\u{00A0}kg")
        #expect(ProgressionPresentation.weightText(60) == "60\u{00A0}kg")
    }

    @Test func mixedWeightTextKeepsEachSetPaired() {
        #expect(ProgressionPresentation.previousText(prev([10, 10, 9], [60, 60, 57.5])) == "60\u{00A0}kg×10 / 60\u{00A0}kg×10 / 57.5\u{00A0}kg×9")
        #expect(ProgressionPresentation.previousText(prev([10, 8], [60, nil])) == "60\u{00A0}kg×10 / 8回")
    }
}

