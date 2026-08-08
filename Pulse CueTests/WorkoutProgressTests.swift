//
//  WorkoutProgressTests.swift
//  Pulse CueTests
//
//  Unit tests for the pure Home / Progress derivations: weekly summary
//  (completed-only, current week, latest workout), and per-exercise progress
//  (grouping by exerciseId, latest vs previous, reps personal best, filtering,
//  determinism).
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct WorkoutProgressTests {

    private func session(_ id: UUID = UUID(), routineId: UUID = UUID(), daysAgo: Int, status: SessionStatus = .completed, seconds: Int = 1800) -> Session {
        Session(id: id, routineId: routineId, dayDate: .now,
                startedAt: Date().addingTimeInterval(TimeInterval(-daysAgo * 86_400)),
                status: status, totalSeconds: seconds)
    }

    private func step(_ exerciseId: String?, id: UUID = UUID(), title: String = "種目") -> Step {
        Step(id: id, routineId: UUID(), order: 0, title: title, sets: 3, repsTarget: 10, restSeconds: 60, exerciseId: exerciseId)
    }

    private func result(_ sessionId: UUID, _ stepId: UUID, set: Int, reps: Int?, done: Bool = true) -> StepResult {
        StepResult(sessionId: sessionId, stepId: stepId, setIndex: set, done: done, actualReps: reps)
    }

    // A calendar fixed so "this week" is deterministic in tests: week starts
    // Monday, reference date is a Wednesday.
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.firstWeekday = 2; return c }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 8, day: 5))! } // Wed

    // MARK: - Home summary

    @Test
    func noHistoryYieldsEmptySummary() {
        let s = HomeProgressSummary.make(sessions: [], results: [], routines: [], now: now, calendar: calendar)
        #expect(s == .empty)
        #expect(!s.hasHistory)
    }

    @Test
    func summaryCountsOnlyThisWeekCompletedWorkouts() {
        let r = Routine(name: "上半身")
        let thisWeekA = session(routineId: r.id, daysAgo: 0, seconds: 1800)   // Wed (this week)
        let thisWeekB = session(routineId: r.id, daysAgo: 1, seconds: 1200)   // Tue (this week)
        let lastWeek = session(routineId: r.id, daysAgo: 9, seconds: 3600)    // previous week — excluded
        let abandoned = session(routineId: r.id, daysAgo: 0, status: .abandoned) // not counted
        let s = HomeProgressSummary.make(
            sessions: [thisWeekA, thisWeekB, lastWeek, abandoned], results: [], routines: [r],
            now: now, calendar: calendar
        )
        #expect(s.weeklyWorkoutCount == 2)
        #expect(s.weeklyTrainingDays == 2)
        #expect(s.weeklyDurationSeconds == 3000)
    }

    @Test
    func summaryCountsThisWeekCompletedSets() {
        let thisWeek = session(daysAgo: 0)
        let lastWeek = session(daysAgo: 9)
        let stepA = step("bench_press")
        let results = [
            result(thisWeek.id, stepA.id, set: 0, reps: 10),
            result(thisWeek.id, stepA.id, set: 1, reps: 9),
            result(thisWeek.id, stepA.id, set: 2, reps: nil, done: false), // not completed
            result(lastWeek.id, stepA.id, set: 0, reps: 10),               // previous week
        ]
        let s = HomeProgressSummary.make(sessions: [thisWeek, lastWeek], results: results, routines: [], now: now, calendar: calendar)
        #expect(s.weeklyCompletedSets == 2)
    }

    @Test
    func summaryPicksMostRecentCompletedAsLastWorkout() {
        let r = Routine(name: "脚の日")
        let older = session(routineId: r.id, daysAgo: 4, seconds: 2000)
        let newer = session(routineId: r.id, daysAgo: 1, seconds: 2880)
        let s = HomeProgressSummary.make(sessions: [older, newer], results: [], routines: [r], now: now, calendar: calendar)
        #expect(s.lastWorkout?.routineId == r.id)
        #expect(s.lastWorkout?.routineName == "脚の日")
        #expect(s.lastWorkout?.durationSeconds == 2880)
        #expect(s.hasHistory)
    }

    // MARK: - Exercise progress

    @Test
    func exerciseInsightsGroupByIdWithLatestPreviousAndPersonalBest() {
        let bench = step("bench_press", title: "ベンチプレス")
        let older = session(daysAgo: 7)
        let newer = session(daysAgo: 2)
        let results = [
            result(older.id, bench.id, set: 0, reps: 8),
            result(older.id, bench.id, set: 1, reps: 8),
            result(newer.id, bench.id, set: 0, reps: 10),
            result(newer.id, bench.id, set: 1, reps: 9),
        ]
        let insights = WorkoutProgressQuery.exerciseInsights(steps: [bench], sessions: [older, newer], results: results)
        let bp = try! #require(insights.first { $0.exerciseId == "bench_press" })
        #expect(bp.exerciseName == "ベンチプレス")
        #expect(bp.latestReps == [10, 9])
        #expect(bp.previousReps == [8, 8])
        #expect(bp.personalBestReps == 10)
        #expect(bp.trend == .up)
    }

    @Test
    func exerciseInsightsIgnoreIncompleteAndUnrelated() {
        let bench = step("bench_press", title: "ベンチプレス")
        let custom = step(nil, title: "自作")           // no id → skipped
        let sess = session(daysAgo: 1)
        let results = [
            result(sess.id, bench.id, set: 0, reps: 10),
            result(sess.id, bench.id, set: 1, reps: nil, done: false), // incomplete
            result(sess.id, custom.id, set: 0, reps: 20),              // unresolvable id
        ]
        let insights = WorkoutProgressQuery.exerciseInsights(steps: [bench, custom], sessions: [sess], results: results)
        #expect(insights.count == 1)
        #expect(insights[0].latestReps == [10])
        #expect(insights[0].personalBestReps == 10)
    }

    @Test
    func exerciseInsightsAreDeterministic() {
        let bench = step("bench_press")
        let sess = session(daysAgo: 1)
        let results = [result(sess.id, bench.id, set: 0, reps: 10)]
        let a = WorkoutProgressQuery.exerciseInsights(steps: [bench], sessions: [sess], results: results)
        let b = WorkoutProgressQuery.exerciseInsights(steps: [bench], sessions: [sess], results: results)
        #expect(a == b)
    }

    @Test
    func noDataYieldsNoInsights() {
        #expect(WorkoutProgressQuery.exerciseInsights(steps: [], sessions: [], results: []).isEmpty)
    }

    @Test
    func singleSessionHasNoPreviousAndUnknownTrend() {
        let bench = step("bench_press")
        let sess = session(daysAgo: 1)
        let results = [result(sess.id, bench.id, set: 0, reps: 10)]
        let insights = WorkoutProgressQuery.exerciseInsights(steps: [bench], sessions: [sess], results: results)
        #expect(insights[0].previousReps == nil)
        #expect(insights[0].trend == .unknown)
    }
}
