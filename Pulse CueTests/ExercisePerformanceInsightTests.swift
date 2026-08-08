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
        let s = ProgressionRule.suggest(previous: prev, baselineReps: 10, allowsRepProgression: true)
        #expect(s?.suggestedReps == 11)
        #expect(s?.isProgression == true)
    }

    @Test
    func missingASetHoldsTheTarget() {
        let prev = PreviousPerformance(date: .now, setReps: [10, 10, 8])
        let s = ProgressionRule.suggest(previous: prev, baselineReps: 10, allowsRepProgression: true)
        #expect(s?.suggestedReps == 10)
        #expect(s?.isProgression == false)
    }

    @Test
    func clearRegressionHoldsTheTarget() {
        let prev = PreviousPerformance(date: .now, setReps: [6, 5, 5])
        let s = ProgressionRule.suggest(previous: prev, baselineReps: 10, allowsRepProgression: true)
        #expect(s?.suggestedReps == 10)
    }

    @Test
    func noPreviousDataYieldsNoSuggestion() {
        #expect(ProgressionRule.suggest(previous: nil, baselineReps: 10, allowsRepProgression: true) == nil)
    }

    @Test
    func nonRepExerciseYieldsNoSuggestion() {
        // e.g. cardio — rep progression makes no sense.
        let prev = PreviousPerformance(date: .now, setReps: [10, 10, 10])
        #expect(ProgressionRule.suggest(previous: prev, baselineReps: 10, allowsRepProgression: false) == nil)
    }
}
