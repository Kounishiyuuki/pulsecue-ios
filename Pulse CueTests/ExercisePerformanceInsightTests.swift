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

    // MARK: Set counts other than 3, and session recency vs step order

    @Test
    func twoSetPlanPrefersTheOlderFullRecordAndProgresses() throws {
        let bench = step("bench_press")
        let full = session(UUID(), daysAgo: 7)
        let partial = session(UUID(), daysAgo: 2, status: .abandoned)
        let perf = try #require(PreviousPerformanceQuery.latest(
            exerciseId: "bench_press", excludingSessionId: nil, expectedSets: 2,
            steps: [bench], sessions: [full, partial],
            results: stepSets(full.id, bench.id, done: 2) + stepSets(partial.id, bench.id, done: 1)
        ))
        #expect(perf.date == full.startedAt)
        #expect(perf.sets.count == 2)
        let s = ProgressionRule.suggest(previous: perf, baselineReps: 10, expectedSets: 2, allowsRepProgression: true, allowsWeightProgression: true)
        #expect(s?.kind == .increaseWeight)
        #expect(s?.suggestedWeightKg == 62.5)
    }

    @Test
    func fourSetPlanPrefersTheOlderFullRecord() {
        let bench = step("bench_press")
        let full = session(UUID(), daysAgo: 7)
        let partial = session(UUID(), daysAgo: 2, status: .abandoned)
        let perf = PreviousPerformanceQuery.latest(
            exerciseId: "bench_press", excludingSessionId: nil, expectedSets: 4,
            steps: [bench], sessions: [full, partial],
            results: stepSets(full.id, bench.id, done: 4) + stepSets(partial.id, bench.id, done: 3)
        )
        #expect(perf?.date == full.startedAt)
        #expect(perf?.sets.count == 4)
    }

    @Test
    func newerSessionBeatsAnOlderOneWhoseStepOrderMatches() {
        let a = step("bench_press", order: 0), b = step("bench_press", order: 1)
        let older = session(UUID(), daysAgo: 5)
        let newer = session(UUID(), daysAgo: 3)
        let results = stepSets(older.id, a.id, done: 3, weight: 80) + stepSets(newer.id, b.id, done: 3, weight: 50)
        // currentStepOrder only breaks ties inside one session; it never
        // reorders sessions by recency.
        let perf = latest([a, b], [older, newer], results, order: 0)
        #expect(perf?.date == newer.startedAt)
        #expect(perf?.setWeightsKg == [50, 50, 50])
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


/// 案F: a changed set count judged against what last time actually planned
/// (`StepResult.plannedSetsAtExecution`), with legacy records kept on the
/// pre-V13 rule and anything ambiguous held.
struct PlannedSetsProgressionRuleTests {

    private func prev(_ reps: [Int], _ weights: [Double?]? = nil, planned: Int?) -> PreviousPerformance {
        let w = weights ?? Array(repeating: nil, count: reps.count)
        return PreviousPerformance(
            date: .now,
            sets: zip(reps, w).map { PreviousSetPerformance(reps: $0, weightKg: $1) },
            plannedSetCount: planned
        )
    }

    private func suggest(_ p: PreviousPerformance, sets: Int, weight: Bool = true) -> ProgressionSuggestion? {
        ProgressionRule.suggest(previous: p, baselineReps: 10, expectedSets: sets, allowsRepProgression: true, allowsWeightProgression: weight)
    }

    // MARK: weighted

    @Test func a_fourToThreeAllAchievedIncreasesWeight() {
        let s = suggest(prev([10, 10, 10, 10], [60, 60, 60, 60], planned: 4), sets: 3)
        #expect(s?.kind == .increaseWeight)
        #expect(s?.suggestedWeightKg == 62.5)
        #expect(s?.suggestedReps == 10)
    }

    @Test func b_fourToThreeLastSetMissedHoldsWeight() {
        let s = suggest(prev([10, 10, 10, 8], [60, 60, 60, 60], planned: 4), sets: 3)
        #expect(s?.kind == .holdWeight)
        #expect(s?.suggestedWeightKg == 60)
        #expect(s?.suggestedReps == 10)
    }

    @Test func c_threeToFourAllAchievedHoldsWeight() {
        let s = suggest(prev([10, 10, 10], [60, 60, 60], planned: 3), sets: 4)
        #expect(s?.kind == .holdWeight)
        #expect(s?.suggestedWeightKg == 60)
        #expect(s?.suggestedReps == 10)
    }

    @Test func d_threeToFourWithMissHoldsWeightNeverDown() {
        let s = suggest(prev([10, 10, 8], [60, 60, 60], planned: 3), sets: 4)
        #expect(s?.kind == .holdWeight)
        #expect(s?.suggestedWeightKg == 60)
    }

    @Test func e_twoToFourHoldsWeight() {
        let s = suggest(prev([10, 10], [60, 60], planned: 2), sets: 4)
        #expect(s?.kind == .holdWeight)
        #expect(s?.suggestedWeightKg == 60)
    }

    @Test func f_fourToTwoAllAchievedIncreasesWeight() {
        let s = suggest(prev([10, 10, 10, 10], [60, 60, 60, 60], planned: 4), sets: 2)
        #expect(s?.kind == .increaseWeight)
        #expect(s?.suggestedWeightKg == 62.5)
    }

    @Test func g_fourToTwoLastSetMissedHoldsWeight() {
        let s = suggest(prev([10, 10, 10, 9], [60, 60, 60, 60], planned: 4), sets: 2)
        #expect(s?.kind == .holdWeight)
        #expect(s?.suggestedWeightKg == 60)
    }

    @Test func sameSnapshotKeepsTheExistingRuleAndCeiling() {
        #expect(suggest(prev([10, 10, 10], [60, 60, 60], planned: 3), sets: 3)?.kind == .increaseWeight)
        #expect(suggest(prev([10, 10, 9], [60, 60, 60], planned: 3), sets: 3)?.kind == .holdWeight)
        let top = suggest(prev([10, 10, 10, 10], [999, 999, 999, 999], planned: 4), sets: 3)
        #expect(top?.kind == .holdWeight)
        #expect(top?.suggestedWeightKg == 999)
    }

    // MARK: reps-only

    @Test func h_repsOnlyThreeToFourHoldsReps() {
        let s = suggest(prev([10, 10, 10], planned: 3), sets: 4)
        #expect(s?.kind == .holdReps)
        #expect(s?.suggestedReps == 10)
    }

    @Test func i_repsOnlyFourToThreeAllAchievedAddsARep() {
        let s = suggest(prev([10, 10, 10, 10], planned: 4), sets: 3)
        #expect(s?.kind == .increaseReps)
        #expect(s?.suggestedReps == 11)
    }

    @Test func j_repsOnlyFourToThreeLastSetMissedHoldsReps() {
        let s = suggest(prev([10, 10, 10, 8], planned: 4), sets: 3)
        #expect(s?.kind == .holdReps)
        #expect(s?.suggestedReps == 10)
    }

    @Test func k_mixedWeightThreeToFourHoldsReps() {
        let s = suggest(prev([10, 10, 10], [60, 57.5, 60], planned: 3), sets: 4)
        #expect(s?.kind == .holdReps)
        #expect(s?.suggestedWeightKg == nil)
    }

    @Test func l_zeroKgThreeToFourHoldsReps() {
        let s = suggest(prev([10, 10, 10], [0, 0, 0], planned: 3), sets: 4)
        #expect(s?.kind == .holdReps)
        #expect(s?.suggestedReps == 10)
    }

    @Test func m_mixedWeightFourToThreeAllAchievedAddsARep() {
        let s = suggest(prev([10, 10, 10, 10], [60, 57.5, 60, 60], planned: 4), sets: 3)
        #expect(s?.kind == .increaseReps)
        #expect(s?.suggestedReps == 11)
    }

    // MARK: partial / inconsistent

    @Test func n_partialSnapshotWeightedHoldsWeight() {
        let s = suggest(prev([10, 10], [60, 60], planned: 4), sets: 4)
        #expect(s?.kind == .holdWeight)
        #expect(s?.suggestedWeightKg == 60)
        // Also when today's count happens to equal the done count.
        #expect(suggest(prev([10, 10], [60, 60], planned: 4), sets: 2)?.kind == .holdWeight)
    }

    @Test func o_partialSnapshotRepsOnlyHoldsReps() {
        #expect(suggest(prev([10, 10], planned: 4), sets: 4)?.kind == .holdReps)
        #expect(suggest(prev([10, 10], planned: 4), sets: 2)?.kind == .holdReps)
    }

    @Test func inconsistentSnapshotNeverProgresses() {
        let p = PreviousPerformance(
            date: .now,
            sets: [10, 10, 10].map { PreviousSetPerformance(reps: $0, weightKg: 60) },
            plannedSetCount: 3,
            hasInconsistentPlannedSets: true
        )
        #expect(p.plannedSetCount == nil)
        #expect(!p.isComplete(expectedSets: 3))
        let s = suggest(p, sets: 3)
        #expect(s?.kind == .holdWeight)
        #expect(s?.suggestedWeightKg == 60)
        #expect(suggest(p, sets: 3, weight: false)?.kind == .holdReps)
    }

    // MARK: legacy

    @Test func p_legacySameCountKeepsTheExistingRule() {
        #expect(suggest(prev([10, 10, 10], [60, 60, 60], planned: nil), sets: 3)?.kind == .increaseWeight)
        #expect(suggest(prev([10, 10, 10], planned: nil), sets: 3)?.kind == .increaseReps)
        let s = suggest(prev([10, 10, 10], [60, 60, 60], planned: nil), sets: 3)
        #expect(s?.previousSetCount == nil)
        #expect(s.flatMap(ProgressionPresentation.reasonText) == "前回は同じ重量で全セット目標回数を達成")
    }

    @Test func q_legacyDifferentCountHoldsAsBefore() {
        // Same data that progresses with a snapshot of 4 → held without one.
        let s = suggest(prev([10, 10, 10, 10], [60, 60, 60, 60], planned: nil), sets: 3)
        #expect(s?.kind == .holdReps)
        #expect(s?.suggestedWeightKg == nil)
        #expect(s.flatMap(ProgressionPresentation.reasonText) == nil)
        #expect(suggest(prev([10, 10, 10], planned: nil), sets: 4)?.kind == .holdReps)
    }

    // MARK: reason

    @Test func reasonNamesTheSetCountChange() {
        let down = suggest(prev([10, 10, 10, 10], [60, 60, 60, 60], planned: 4), sets: 3)
        #expect(down?.previousSetCount == 4)
        #expect(down?.expectedSetCount == 3)
        #expect(down.flatMap(ProgressionPresentation.reasonText) == "前回は4セットをすべて達成。今回は3セット")
        let up = suggest(prev([10, 10, 10], [60, 60, 60], planned: 3), sets: 4)
        #expect(up.flatMap(ProgressionPresentation.reasonText) == "前回は3セット、今回は4セットのため重量を維持")
        let upReps = suggest(prev([10, 10, 10], planned: 3), sets: 4)
        #expect(upReps.flatMap(ProgressionPresentation.reasonText) == "前回は3セット、今回は4セットのため回数を維持")
        let downMiss = suggest(prev([10, 10, 10, 8], [60, 60, 60, 60], planned: 4), sets: 3)
        #expect(downMiss.flatMap(ProgressionPresentation.reasonText) == "前回は4セット中に未達あり。今回は3セットのため重量を維持")
        let downRepsMiss = suggest(prev([10, 10, 10, 8], planned: 4), sets: 3)
        #expect(downRepsMiss.flatMap(ProgressionPresentation.reasonText) == "前回は4セット中に未達あり。今回は3セットのため回数を維持")
        let repsDown = suggest(prev([10, 10, 10, 10], planned: 4), sets: 3)
        #expect(repsDown.flatMap(ProgressionPresentation.reasonText) == "前回は4セットをすべて達成。今回は3セット")
    }

    @Test func noNewReasonWithoutASetCountChangeOrForPartials() {
        #expect(suggest(prev([10, 10, 10], [60, 60, 60], planned: 3), sets: 3).flatMap(ProgressionPresentation.reasonText) == "前回は同じ重量で全セット目標回数を達成")
        #expect(suggest(prev([10, 10, 9], [60, 60, 60], planned: 3), sets: 3).flatMap(ProgressionPresentation.reasonText) == nil)
        #expect(suggest(prev([10, 10], [60, 60], planned: 4), sets: 3).flatMap(ProgressionPresentation.reasonText) == nil)
    }

    @Test func applyLabelUnchanged() throws {
        let w = try #require(suggest(prev([10, 10, 10], [60, 60, 60], planned: 3), sets: 4))
        #expect(ProgressionPresentation.applyAccessibilityLabel(w) == "目安の重量とレップ数を適用")
        let r = try #require(suggest(prev([10, 10, 10], planned: 3), sets: 4))
        #expect(ProgressionPresentation.applyAccessibilityLabel(r) == "目安のレップ数を適用")
    }
}

/// 案F selection: completeness against each record's own snapshot.
@MainActor
struct PlannedSetsPreviousPerformanceQueryTests {

    private func session(daysAgo: Int, status: SessionStatus = .completed) -> Session {
        Session(routineId: UUID(), dayDate: .now, startedAt: Date().addingTimeInterval(TimeInterval(-daysAgo * 86_400)), status: status)
    }

    private func sets(_ s: Session, _ stepId: UUID, reps: [Int], planned: [Int?], weight: Double? = 60) -> [StepResult] {
        zip(reps, planned).enumerated().map { i, pair in
            StepResult(sessionId: s.id, stepId: stepId, setIndex: i, done: true, actualReps: pair.0, weightKg: weight, plannedSetsAtExecution: pair.1)
        }
    }

    private func latest(_ steps: [Step], _ sessions: [Session], _ results: [StepResult], expected: Int, order: Int? = nil) -> PreviousPerformance? {
        PreviousPerformanceQuery.latest(
            exerciseId: "bench_press", excludingSessionId: nil, expectedSets: expected, currentStepOrder: order,
            steps: steps, sessions: sessions, results: results
        )
    }

    private let bench = Step(routineId: UUID(), order: 0, title: "x", sets: 3, repsTarget: 10, restSeconds: 60, exerciseId: "bench_press")

    @Test func s_olderThreeOfThreeBeatsNewerOneOfFour() throws {
        let old = session(daysAgo: 3), new = session(daysAgo: 1)
        let r = sets(old, bench.id, reps: [10, 10, 10], planned: [3, 3, 3]) + sets(new, bench.id, reps: [10], planned: [4])
        let p = try #require(latest([bench], [old, new], r, expected: 4))
        #expect(p.plannedSetCount == 3)
        #expect(p.sets.count == 3)
        #expect(p.isComplete(expectedSets: 4))
    }

    @Test func t_olderFourOfFourBeatsNewerOneOfThree() throws {
        let old = session(daysAgo: 3), new = session(daysAgo: 1)
        let r = sets(old, bench.id, reps: [10, 10, 10, 10], planned: [4, 4, 4, 4]) + sets(new, bench.id, reps: [10], planned: [3])
        let p = try #require(latest([bench], [old, new], r, expected: 3))
        #expect(p.plannedSetCount == 4)
        #expect(p.sets.count == 4)
    }

    @Test func u_abandonedThreeOfThreeIsComplete() throws {
        let old = session(daysAgo: 3), new = session(daysAgo: 1, status: .abandoned)
        let r = sets(old, bench.id, reps: [10, 10, 10], planned: [3, 3, 3]) + sets(new, bench.id, reps: [9, 9, 9], planned: [3, 3, 3])
        let p = try #require(latest([bench], [old, new], r, expected: 4))
        #expect(p.setReps == [9, 9, 9])
        #expect(p.isComplete(expectedSets: 4))
    }

    @Test func v_completedSessionWithThreeOfFourIsPartial() throws {
        let old = session(daysAgo: 3), new = session(daysAgo: 1)
        // Newer: 3 of 4 done — partial even though today's expectedSets is 3.
        let r = sets(old, bench.id, reps: [10, 10, 10], planned: [3, 3, 3]) + sets(new, bench.id, reps: [11, 11, 11], planned: [4, 4, 4])
        let p = try #require(latest([bench], [old, new], r, expected: 3))
        #expect(p.setReps == [10, 10, 10])
        // Alone, the partial one is the fallback and does not progress.
        let only = try #require(latest([bench], [new], sets(new, bench.id, reps: [11, 11, 11], planned: [4, 4, 4]), expected: 3))
        #expect(!only.isComplete(expectedSets: 3))
        #expect(ProgressionRule.suggest(previous: only, baselineReps: 10, expectedSets: 3, allowsRepProgression: true, allowsWeightProgression: true)?.kind == .holdWeight)
    }

    @Test func w_twoStepsOfOneExerciseAreNotMerged() throws {
        let other = Step(routineId: bench.routineId, order: 1, title: "x", sets: 2, repsTarget: 10, restSeconds: 60, exerciseId: "bench_press")
        let s = session(daysAgo: 1)
        let r = sets(s, bench.id, reps: [10, 10], planned: [2, 2]) + sets(s, other.id, reps: [10, 10], planned: [2, 2])
        let p = try #require(latest([bench, other], [s], r, expected: 4))
        #expect(p.sets.count == 2)
        #expect(p.plannedSetCount == 2)
    }

    @Test func x_rankingByStartedAtThenCurrentOrderIsKept() throws {
        let second = Step(routineId: bench.routineId, order: 1, title: "x", sets: 3, repsTarget: 10, restSeconds: 60, exerciseId: "bench_press")
        let old = session(daysAgo: 3), new = session(daysAgo: 1)
        let r = sets(old, bench.id, reps: [12, 12, 12], planned: [3, 3, 3])
            + sets(new, bench.id, reps: [10, 10, 10], planned: [3, 3, 3])
            + sets(new, second.id, reps: [8, 8, 8], planned: [3, 3, 3])
        #expect(latest([bench, second], [old, new], r, expected: 3, order: 1)?.setReps == [8, 8, 8])
        #expect(latest([bench, second], [old, new], r, expected: 3, order: 0)?.setReps == [10, 10, 10])
        #expect(latest([bench, second], [old, new], r, expected: 3)?.setReps == [10, 10, 10])
    }

    @Test func r_newerLegacyPartialDoesNotHideOlderSnapshotComplete() throws {
        let old = session(daysAgo: 3), new = session(daysAgo: 1)
        let r = sets(old, bench.id, reps: [10, 10, 10, 10], planned: [4, 4, 4, 4]) + sets(new, bench.id, reps: [10, 10], planned: [nil, nil])
        let p = try #require(latest([bench], [old, new], r, expected: 3))
        #expect(p.plannedSetCount == 4)
        // A newer legacy record that is full by the old rule still wins (compatibility).
        let r2 = sets(old, bench.id, reps: [10, 10, 10, 10], planned: [4, 4, 4, 4]) + sets(new, bench.id, reps: [9, 9, 9], planned: [nil, nil, nil])
        let p2 = try #require(latest([bench], [old, new], r2, expected: 3))
        #expect(p2.plannedSetCount == nil)
        #expect(p2.setReps == [9, 9, 9])
    }

    @Test func legacyRecordStaysUnknown() throws {
        let s = session(daysAgo: 1)
        let p = try #require(latest([bench], [s], sets(s, bench.id, reps: [10, 10, 10], planned: [nil, nil, nil]), expected: 3))
        #expect(p.plannedSetCount == nil)
        #expect(!p.hasInconsistentPlannedSets)
        #expect(p.isComplete(expectedSets: 3))
    }

    @Test func inconsistentSnapshotIsUnknownPartialAndHeld() throws {
        let old = session(daysAgo: 3), new = session(daysAgo: 1)
        let bad = sets(new, bench.id, reps: [10, 10, 10], planned: [3, 4, 3])
        let alone = try #require(latest([bench], [new], bad, expected: 3))
        #expect(alone.hasInconsistentPlannedSets)
        #expect(alone.plannedSetCount == nil)
        #expect(ProgressionRule.suggest(previous: alone, baselineReps: 10, expectedSets: 3, allowsRepProgression: true, allowsWeightProgression: true)?.kind == .holdWeight)
        #expect(ProgressionRule.suggest(previous: alone, baselineReps: 10, expectedSets: 4, allowsRepProgression: true, allowsWeightProgression: true)?.kind == .holdWeight)
        // nil mixed with a value is also inconsistent.
        let mixed = try #require(latest([bench], [new], sets(new, bench.id, reps: [10, 10, 10], planned: [3, nil, 3]), expected: 3))
        #expect(mixed.hasInconsistentPlannedSets)
        // An older consistent complete record is preferred over it.
        let withGood = bad + sets(old, bench.id, reps: [10, 10, 10], planned: [3, 3, 3])
        #expect(latest([bench], [old, new], withGood, expected: 3)?.plannedSetCount == 3)
    }
}

/// Hardening of 案F: inconsistent snapshots (skipped results included), the
/// snapshot-partial vs legacy-complete conflict, and the miss reason line.
@MainActor
struct PlannedSetsHardeningTests {

    private let bench = Step(routineId: UUID(), order: 0, title: "x", sets: 3, repsTarget: 10, restSeconds: 60, exerciseId: "bench_press")

    private func session(daysAgo: Int) -> Session {
        Session(routineId: UUID(), dayDate: .now, startedAt: Date().addingTimeInterval(TimeInterval(-daysAgo * 86_400)), status: .completed)
    }

    private func result(_ s: Session, set: Int, planned: Int?, done: Bool = true, reps: Int? = 10, weight: Double? = 60) -> StepResult {
        StepResult(sessionId: s.id, stepId: bench.id, setIndex: set, done: done, actualReps: done ? reps : nil, weightKg: done ? weight : nil, plannedSetsAtExecution: planned)
    }

    private func latest(_ sessions: [Session], _ results: [StepResult], expected: Int = 3) -> PreviousPerformance? {
        PreviousPerformanceQuery.latest(
            exerciseId: "bench_press", excludingSessionId: nil, expectedSets: expected,
            steps: [bench], sessions: sessions, results: results
        )
    }

    private func suggest(_ p: PreviousPerformance, expected: Int = 3, weight: Bool = true) -> ProgressionSuggestion? {
        ProgressionRule.suggest(previous: p, baselineReps: 10, expectedSets: expected, allowsRepProgression: true, allowsWeightProgression: weight)
    }

    /// Full sets at 60 kg × 10, every one at target, with the given snapshots.
    private func assertInconsistentHolds(_ planned: [Int?]) throws {
        let s = session(daysAgo: 1)
        let p = try #require(latest([s], planned.enumerated().map { result(s, set: $0, planned: $1) }))
        #expect(p.sets.count == 3)
        #expect(p.setReps == [10, 10, 10])
        #expect(p.hasInconsistentPlannedSets)
        #expect(p.plannedSetCount == nil)
        #expect(!p.isComplete(expectedSets: 3))

        let weighted = try #require(suggest(p))
        #expect(weighted.kind == .holdWeight)
        #expect(weighted.suggestedWeightKg == 60)
        #expect(weighted.suggestedReps == 10)
        #expect(!weighted.isProgression)
        #expect(weighted.previousSetCount == nil)
        #expect(ProgressionPresentation.reasonText(weighted) == nil)

        let reps = try #require(suggest(p, weight: false))
        #expect(reps.kind == .holdReps)
        #expect(reps.suggestedReps == 10)
        #expect(reps.suggestedWeightKg == nil)
    }

    @Test func a_valueNilValueIsInconsistentAndHeld() throws { try assertInconsistentHolds([3, nil, 3]) }
    @Test func b_nilValueNilIsInconsistentAndHeld() throws { try assertInconsistentHolds([nil, 3, nil]) }
    @Test func c_twoValuesAreInconsistentAndHeld() throws { try assertInconsistentHolds([3, 4, 3]) }

    @Test func skippedResultJoinsTheConsistencyCheck() throws {
        let s = session(daysAgo: 1)
        let r = [
            result(s, set: 0, planned: 3),
            result(s, set: 1, planned: 4, done: false),
            result(s, set: 2, planned: 3),
        ]
        let p = try #require(latest([s], r, expected: 2))
        // Sets still come from completed results only.
        #expect(p.setReps == [10, 10])
        #expect(p.hasInconsistentPlannedSets)
        #expect(p.plannedSetCount == nil)
        #expect(!p.isComplete(expectedSets: 2))
        let sug = try #require(suggest(p, expected: 2))
        #expect(sug.kind == .holdWeight)
        #expect(sug.suggestedWeightKg == 60)
        #expect(suggest(p, expected: 2, weight: false)?.kind == .holdReps)
    }

    @Test func consistentSkippedResultKeepsTheSnapshot() throws {
        // Normal V13 data: a skipped set carries the same snapshot.
        let s = session(daysAgo: 1)
        let r = [result(s, set: 0, planned: 3), result(s, set: 1, planned: 3), result(s, set: 2, planned: 3, done: false)]
        let p = try #require(latest([s], r))
        #expect(!p.hasInconsistentPlannedSets)
        #expect(p.plannedSetCount == 3)
        #expect(!p.isComplete(expectedSets: 3))
        #expect(suggest(p)?.kind == .holdWeight)
    }

    @Test func conflictC_newerSnapshotPartialLosesToOlderLegacyComplete() throws {
        let old = session(daysAgo: 5), new = session(daysAgo: 1)
        let r = [result(old, set: 0, planned: nil, reps: 12), result(old, set: 1, planned: nil, reps: 12), result(old, set: 2, planned: nil, reps: 12),
                 result(new, set: 0, planned: 4), result(new, set: 1, planned: 4)]
        let p = try #require(latest([old, new], r, expected: 3))
        #expect(p.date == old.startedAt)
        #expect(p.setReps == [12, 12, 12])
        #expect(p.plannedSetCount == nil)
        #expect(!p.hasInconsistentPlannedSets)
        #expect(p.isComplete(expectedSets: 3))
        // Legacy rule then applies unchanged.
        #expect(suggest(p)?.kind == .increaseWeight)
        #expect(suggest(p)?.suggestedWeightKg == 62.5)
    }

    // MARK: reason

    private func prev(_ reps: [Int], weight: Double? = 60, planned: Int) -> PreviousPerformance {
        PreviousPerformance(date: .now, sets: reps.map { PreviousSetPerformance(reps: $0, weightKg: weight) }, plannedSetCount: planned)
    }

    @Test func d_fewerSetsWithAMissNamesItWeighted() throws {
        let s = try #require(suggest(prev([10, 10, 10, 8], planned: 4)))
        #expect(s.kind == .holdWeight)
        #expect(s.suggestedWeightKg == 60)
        let reason = try #require(ProgressionPresentation.reasonText(s))
        #expect(reason.contains("未達"))
        #expect(reason.contains("重量を維持"))
        #expect(reason == "前回は4セット中に未達あり。今回は3セットのため重量を維持")
    }

    @Test func e_fewerSetsWithAMissNamesItRepsOnly() throws {
        let s = try #require(suggest(prev([10, 10, 10, 8], weight: nil, planned: 4)))
        #expect(s.kind == .holdReps)
        #expect(s.suggestedReps == 10)
        let reason = try #require(ProgressionPresentation.reasonText(s))
        #expect(reason.contains("未達"))
        #expect(reason.contains("回数を維持"))
    }

    @Test func f_fewerSetsAllAchievedSaysSo() throws {
        for w in [Double?(60), nil] {
            let s = try #require(suggest(prev([10, 10, 10, 10], weight: w, planned: 4)))
            #expect(s.isProgression)
            let reason = try #require(ProgressionPresentation.reasonText(s))
            #expect(reason.contains("すべて達成"))
            #expect(!reason.contains("未達"))
        }
    }

    @Test func g_moreSetsReasonUnchanged() {
        #expect(suggest(prev([10, 10, 10], planned: 3), expected: 4).flatMap(ProgressionPresentation.reasonText) == "前回は3セット、今回は4セットのため重量を維持")
        #expect(suggest(prev([10, 10, 8], weight: nil, planned: 3), expected: 4).flatMap(ProgressionPresentation.reasonText) == "前回は3セット、今回は4セットのため回数を維持")
    }

    @Test func ceilingHoldAfterFewerSetsNeverClaimsAMiss() throws {
        let s = try #require(suggest(prev([10, 10, 10, 10], weight: 999, planned: 4)))
        #expect(s.kind == .holdWeight)
        #expect(s.suggestedWeightKg == 999)
        #expect(ProgressionPresentation.reasonText(s) == "前回は4セット、今回は3セット")
    }

    @Test func legacyAndPartialStillShowNoSetCountReason() {
        let legacy = PreviousPerformance(date: .now, setReps: [10, 10, 10, 8], setWeightsKg: [60, 60, 60, 60])
        #expect(suggest(legacy).flatMap(ProgressionPresentation.reasonText) == nil)
        #expect(suggest(prev([10, 8], planned: 4)).flatMap(ProgressionPresentation.reasonText) == nil)
    }
}
