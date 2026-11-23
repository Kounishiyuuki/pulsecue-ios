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

    /// `daysAgo` is counted back from the fixture's fixed `now`, never from the
    /// system clock: "this week" must mean the same week no matter what day the
    /// suite runs on.
    private func session(_ id: UUID = UUID(), routineId: UUID = UUID(), daysAgo: Int, status: SessionStatus = .completed, seconds: Int = 1800) -> Session {
        let startedAt = now.addingTimeInterval(TimeInterval(-daysAgo * 86_400))
        return Session(id: id, routineId: routineId,
                       dayDate: calendar.startOfDay(for: startedAt),
                       startedAt: startedAt,
                       status: status, totalSeconds: seconds)
    }

    private func step(_ exerciseId: String?, id: UUID = UUID(), title: String = "種目") -> Step {
        Step(id: id, routineId: UUID(), order: 0, title: title, sets: 3, repsTarget: 10, restSeconds: 60, exerciseId: exerciseId)
    }

    private func result(_ sessionId: UUID, _ stepId: UUID, set: Int, reps: Int?, done: Bool = true) -> StepResult {
        StepResult(sessionId: sessionId, stepId: stepId, setIndex: set, done: done, actualReps: reps)
    }

    // A calendar fixed so "this week" is deterministic in tests: week starts
    // Monday, reference date is a Wednesday. `now` is the single clock every
    // fixture is built from — no test reads the system date, so the suite
    // behaves identically on any run date.
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.firstWeekday = 2; return c }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 8, day: 5))! } // Wed

    // MARK: - Fixture determinism

    /// Guards the fixture itself: every session must be anchored to `now`, not
    /// to `Date()`. Reintroducing the system clock here silently breaks the
    /// weekly tests once the real date leaves the reference week.
    @Test
    func fixtureSessionsAreAnchoredToTheFixedNow() {
        #expect(session(daysAgo: 0).startedAt == now)
        #expect(session(daysAgo: 9).startedAt == now.addingTimeInterval(-9 * 86_400))
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        #expect(week?.contains(session(daysAgo: 0).startedAt) == true)
        #expect(week?.contains(session(daysAgo: 9).startedAt) == false)
    }

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

    // MARK: - The signal Home and Training observe
    //
    //  Both screens observed `sessions.count` and `stepResults.count`. Two
    //  things the summary shows change neither: finishing a workout, which
    //  flips an existing Session to `.completed`, and renaming the routine
    //  whose name the "last workout" row displays.

    private func signature(
        _ sessions: [Session],
        _ results: [StepResult] = [],
        _ routines: [Routine] = []
    ) -> HomeProgressSummary.ChangeSignature {
        HomeProgressSummary.changeSignature(
            sessions: sessions, results: results, routines: routines
        )
    }

    private func summary(
        _ sessions: [Session],
        _ results: [StepResult] = [],
        _ routines: [Routine] = []
    ) -> HomeProgressSummary {
        HomeProgressSummary.make(
            sessions: sessions, results: results, routines: routines,
            now: now, calendar: calendar
        )
    }

    @Test func completingAWorkoutChangesTheSignalWithoutChangingTheCount() {
        let id = UUID()
        let running = [session(id, daysAgo: 0, status: .inProgress, seconds: 0)]
        let finished = [session(id, daysAgo: 0, status: .completed, seconds: 1_800)]

        #expect(running.count == finished.count)
        #expect(signature(running) != signature(finished))
    }

    @Test func markingASetDoneChangesTheSignalWithoutChangingTheCount() {
        let sessionId = UUID()
        let stepId = UUID()
        let pending = [result(sessionId, stepId, set: 0, reps: 10, done: false)]
        let done = [result(sessionId, stepId, set: 0, reps: 10, done: true)]

        #expect(pending.count == done.count)
        #expect(signature([], pending) != signature([], done))
    }

    @Test func aNewSessionChangesTheSignal() {
        let one = [session(daysAgo: 1)]
        let two = one + [session(daysAgo: 0)]

        #expect(signature(one) != signature(two))
    }

    @Test func anUnchangedStoreLeavesTheSignalAlone() {
        // Otherwise every render would recompute the summary.
        let sessions = [session(daysAgo: 1), session(daysAgo: 3)]
        let results = [result(UUID(), UUID(), set: 0, reps: 8)]
        let routines = [Routine(name: "Push")]

        #expect(
            signature(sessions, results, routines) == signature(sessions, results, routines)
        )
    }

    // MARK: - The routine name the summary displays

    @Test func renamingTheLastWorkoutsRoutineChangesTheSignal() {
        // Nothing about the session changes — same id, same count. Only the
        // name on screen does, and the screens must notice.
        let routineId = UUID()
        let sessions = [session(routineId: routineId, daysAgo: 0)]
        let before = [Routine(id: routineId, name: "Push")]
        let after = [Routine(id: routineId, name: "Upper Push")]

        #expect(before.count == after.count)
        #expect(summary(sessions, [], before).lastWorkout?.routineName == "Push")
        #expect(summary(sessions, [], after).lastWorkout?.routineName == "Upper Push")
        #expect(signature(sessions, [], before) != signature(sessions, [], after))
    }

    @Test func deletingTheRoutineChangesTheSignalAndFallsBack() {
        // The existing fallback, unchanged: a session whose routine is gone
        // still shows in History as 「ワークアウト」.
        let routineId = UUID()
        let sessions = [session(routineId: routineId, daysAgo: 0)]
        let present = [Routine(id: routineId, name: "Push")]

        #expect(summary(sessions, [], present).lastWorkout?.routineName == "Push")
        #expect(summary(sessions, [], []).lastWorkout?.routineName == "ワークアウト")
        #expect(signature(sessions, [], present) != signature(sessions, [], []))
    }

    @Test func renamingAnUnrelatedRoutineIsStillNoticed() {
        // Conservative by design: the signature carries every routine's name
        // because which one is "last" can itself change. A spurious recompute
        // is cheap; a missed one leaves a wrong name on screen.
        let routineId = UUID()
        let sessions = [session(routineId: routineId, daysAgo: 0)]
        let before = [Routine(id: routineId, name: "Push"), Routine(name: "Pull")]
        let after = [Routine(id: routineId, name: "Push"), Routine(name: "Legs")]

        #expect(signature(sessions, [], before) != signature(sessions, [], after))
    }

    @Test func aRoutineFieldTheSummaryNeverReadsIsIgnored() {
        // Pinning the other half: the signature is the summary's inputs, not
        // a serialisation of the model. Editing a routine's pin state would
        // otherwise recompute Home on every reorder.
        let routineId = UUID()
        let sessions = [session(routineId: routineId, daysAgo: 0)]
        let unpinned = [Routine(id: routineId, name: "Push", isPinned: false)]
        let pinned = [Routine(id: routineId, name: "Push", isPinned: true)]

        #expect(signature(sessions, [], unpinned) == signature(sessions, [], pinned))
    }

    @Test func theSignalTracksEveryFieldTheSummaryReads() {
        // The invariant: if the signature is equal, recomputing would produce
        // the same summary. A field used by `make` but missing from the
        // signature would break that, and the screen would go stale.
        let id = UUID()
        let routineId = UUID()
        let routines = [Routine(id: routineId, name: "Push")]
        let before = [session(id, routineId: routineId, daysAgo: 0, seconds: 1_800)]

        for after in [
            [session(id, routineId: routineId, daysAgo: 0, seconds: 2_400)],   // duration
            [session(id, routineId: routineId, daysAgo: 3, seconds: 1_800)],   // startedAt
            [session(id, routineId: UUID(), daysAgo: 0, seconds: 1_800)],      // routine
            [session(id, routineId: routineId, daysAgo: 0, status: .inProgress, seconds: 1_800)]
        ] {
            let summaryChanged = summary(before, [], routines) != summary(after, [], routines)
            let signalChanged = signature(before, [], routines) != signature(after, [], routines)
            #expect(!summaryChanged || signalChanged)
        }
    }

    @Test func theSignalTracksTheRoutineNamesTheSummaryReads() {
        // The same invariant over the routine input.
        let routineId = UUID()
        let sessions = [session(routineId: routineId, daysAgo: 0)]
        let before = [Routine(id: routineId, name: "Push")]

        for after in [[Routine(id: routineId, name: "Upper Push")], []] {
            let summaryChanged = summary(sessions, [], before) != summary(sessions, [], after)
            let signalChanged = signature(sessions, [], before) != signature(sessions, [], after)
            #expect(!summaryChanged || signalChanged)
        }
    }
}

/// Progress names an exercise after its latest *performed* record: a Skip-only
/// record is not a performance, so it never renames the exercise.
@MainActor
struct WorkoutProgressTitleSelectionTests {

    private let base = Date(timeIntervalSince1970: 1_780_000_000)

    private func session(daysAgo: Int) -> Session {
        let startedAt = base.addingTimeInterval(TimeInterval(-daysAgo * 86_400))
        return Session(routineId: UUID(), dayDate: startedAt, startedAt: startedAt, status: .completed, totalSeconds: 1800)
    }

    private func snap(_ session: Session, _ stepId: UUID, set: Int, title: String, done: Bool, reps: Int?) -> StepResult {
        StepResult(sessionId: session.id, stepId: stepId, setIndex: set, done: done, actualReps: reps,
                   exerciseIdAtExecution: "bench_press", exerciseTitleAtExecution: title)
    }

    private func fixture(newerDone: Bool) -> (sessions: [Session], results: [StepResult]) {
        let older = session(daysAgo: 3), newer = session(daysAgo: 1)
        let results = [
            snap(older, UUID(), set: 0, title: "ベンチプレス", done: true, reps: 10),
            newerDone
                ? snap(newer, UUID(), set: 0, title: "バーベルベンチプレス", done: true, reps: 8)
                : snap(newer, UUID(), set: 0, title: "バーベルベンチプレス", done: false, reps: nil),
        ]
        return ([older, newer], results)
    }

    @Test func aNewerSkipOnlyRecordDoesNotRenameTheExercise() {
        let fx = fixture(newerDone: false)
        let insights = WorkoutProgressQuery.exerciseInsights(steps: [], sessions: fx.sessions, results: fx.results)
        #expect(insights.map(\.exerciseName) == ["ベンチプレス"])
    }

    @Test func aDoneSetWithoutRepsIsNotAPerformanceEither() {
        let older = session(daysAgo: 3), newer = session(daysAgo: 1)
        let results = [
            snap(older, UUID(), set: 0, title: "ベンチプレス", done: true, reps: 10),
            snap(newer, UUID(), set: 0, title: "バーベルベンチプレス", done: true, reps: nil),
        ]
        let insights = WorkoutProgressQuery.exerciseInsights(steps: [], sessions: [older, newer], results: results)
        #expect(insights.map(\.exerciseName) == ["ベンチプレス"])
    }

    @Test func aNewerPerformedRecordRenamesTheExercise() {
        let fx = fixture(newerDone: true)
        let insights = WorkoutProgressQuery.exerciseInsights(steps: [], sessions: fx.sessions, results: fx.results)
        #expect(insights.map(\.exerciseName) == ["バーベルベンチプレス"])
    }

    @Test func titleSelectionDoesNotDependOnFetchOrder() {
        for newerDone in [false, true] {
            let fx = fixture(newerDone: newerDone)
            let expected = newerDone ? "バーベルベンチプレス" : "ベンチプレス"
            for (sessions, results) in [(fx.sessions, fx.results), (fx.sessions.reversed(), fx.results.reversed())] {
                let insights = WorkoutProgressQuery.exerciseInsights(steps: [], sessions: Array(sessions), results: Array(results))
                #expect(insights.map(\.exerciseName) == [expected])
            }
        }
    }
}

/// Timed exercises in Progress: per-workout duration totals — latest,
/// previous, best — from recorded durations only.
@MainActor
struct WorkoutDurationProgressTests {
    private let base = Date(timeIntervalSince1970: 1_780_000_000)

    private func session(daysAgo: Int, status: SessionStatus = .completed, owner: UUID? = nil) -> Session {
        let start = base.addingTimeInterval(-Double(daysAgo) * 86_400)
        return Session(routineId: UUID(), dayDate: start, startedAt: start, status: status, totalSeconds: 1800, ownerAccountID: owner)
    }

    private func step(_ exerciseId: String?, title: String = "トレッドミル") -> Step {
        Step(routineId: UUID(), order: 0, title: title, sets: 3, repsTarget: 10, restSeconds: 60, exerciseId: exerciseId)
    }

    private func timed(_ session: Session, _ step: Step, set: Int = 0, seconds: Int?, done: Bool = true) -> StepResult {
        StepResult(sessionId: session.id, stepId: step.id, setIndex: set, done: done, actualReps: nil,
                   ownerAccountID: session.ownerAccountID, actualDurationSeconds: seconds)
    }

    private func insight(_ steps: [Step], _ sessions: [Session], _ results: [StepResult]) -> ExerciseDurationProgressInsight? {
        WorkoutProgressQuery.durationInsights(steps: steps, sessions: sessions, results: results)
            .first { $0.exerciseId == "treadmill_warmup" }
    }

    @Test func aWorkoutsSetsAddUp() throws {
        let tread = step("treadmill_warmup"), s = session(daysAgo: 1)
        let got = try #require(insight([tread], [s], [timed(s, tread, set: 0, seconds: 600), timed(s, tread, set: 1, seconds: 300)]))
        #expect(got.latestSeconds == 900)
        #expect(got.previousSeconds == nil)
        #expect(got.bestSeconds == 900)
        #expect(got.trend == .unknown)
        #expect(got.exerciseName == "トレッドミル")
    }

    @Test func twoStepsOfTheSameExerciseInOneWorkoutAddUp() throws {
        let a = step("treadmill_warmup"), b = step("treadmill_warmup"), s = session(daysAgo: 1)
        let got = try #require(insight([a, b], [s], [timed(s, a, seconds: 600), timed(s, b, seconds: 300)]))
        #expect(got.latestSeconds == 900)
        #expect(got.previousSeconds == nil)
    }

    @Test func latestPreviousAndBestAreWorkoutTotals() throws {
        let tread = step("treadmill_warmup")
        let s1 = session(daysAgo: 3), s2 = session(daysAgo: 2)
        let two = try #require(insight([tread], [s1, s2], [timed(s1, tread, seconds: 600), timed(s2, tread, seconds: 900)]))
        #expect(two.latestSeconds == 900 && two.previousSeconds == 600 && two.bestSeconds == 900)
        #expect(two.trend == .up)

        let s3 = session(daysAgo: 1)
        let three = try #require(insight([tread], [s1, s2, s3], [
            timed(s1, tread, seconds: 600), timed(s2, tread, seconds: 1200), timed(s3, tread, seconds: 900),
        ]))
        #expect(three.latestSeconds == 900 && three.previousSeconds == 1200 && three.bestSeconds == 1200)
        #expect(three.trend == .down)
    }

    @Test func workoutsWithoutARecordedDurationAreLeftOut() throws {
        let tread = step("treadmill_warmup")
        let legacy = session(daysAgo: 3), s2 = session(daysAgo: 2), s3 = session(daysAgo: 1)
        let got = try #require(insight([tread], [legacy, s2, s3], [
            timed(legacy, tread, seconds: nil),       // done before durations: never a time
            timed(s2, tread, seconds: 600),
            timed(s3, tread, seconds: 900),
        ]))
        #expect(got.latestSeconds == 900 && got.previousSeconds == 600 && got.bestSeconds == 900)

        // Only durationless history → no insight at all, never 0分.
        #expect(insight([tread], [legacy], [timed(legacy, tread, seconds: nil)]) == nil)
    }

    @Test func skippedUnfinishedAndNonPositiveAreLeftOut() {
        let tread = step("treadmill_warmup")
        let done = session(daysAgo: 3), open = session(daysAgo: 1, status: .inProgress)
        let results = [
            timed(done, tread, set: 0, seconds: 300, done: false),   // skipped
            timed(done, tread, set: 1, seconds: 0),
            timed(done, tread, set: 2, seconds: -30),
            timed(open, tread, seconds: 900),                        // not finished
        ]
        #expect(insight([tread], [done, open], results) == nil)
    }

    @Test func anEditedDurationCountsAsItIsNow() throws {
        let tread = step("treadmill_warmup"), s = session(daysAgo: 1)
        let r = timed(s, tread, seconds: 750)
        let before = WorkoutProgressQuery.insightSignature(steps: [tread], results: [r])
        r.actualDurationSeconds = 900
        #expect(WorkoutProgressQuery.insightSignature(steps: [tread], results: [r]) != before)   // the screen refreshes
        #expect(try #require(insight([tread], [s], [r])).latestSeconds == 900)
        #expect(insight([tread], [s], []) == nil)                                               // a deleted set is gone
    }

    @Test func eachAccountSeesOnlyItsOwnDurations() throws {
        let a = UUID(), b = UUID(), tread = step("treadmill_warmup")
        let sa = session(daysAgo: 2, owner: a), sg = session(daysAgo: 1)
        let sessions = [sa, sg], results = [timed(sa, tread, seconds: 750), timed(sg, tread, seconds: 300)]
        func seen(_ scope: WorkoutDataScope) -> ExerciseDurationProgressInsight? {
            insight([tread], scope.visible(sessions), scope.visible(results))
        }
        #expect(try #require(seen(.account(a))).latestSeconds == 750)
        #expect(seen(.account(b)) == nil)
        let guest = try #require(seen(.guest))
        #expect(guest.latestSeconds == 300 && guest.previousSeconds == nil)
    }

    @Test func repExercisesKeepTheirInsightsAndGetNoDuration() throws {
        let bench = step("bench_press", title: "ベンチプレス"), tread = step("treadmill_warmup"), s = session(daysAgo: 1)
        let results = [
            StepResult(sessionId: s.id, stepId: bench.id, setIndex: 0, done: true, actualReps: 10, weightKg: 80),
            timed(s, tread, seconds: 600),
        ]
        let reps = WorkoutProgressQuery.exerciseInsights(steps: [bench, tread], sessions: [s], results: results)
        #expect(reps.map(\.exerciseId) == ["bench_press"])
        #expect(reps.first?.latestReps == [10])
        let durations = WorkoutProgressQuery.durationInsights(steps: [bench, tread], sessions: [s], results: results)
        #expect(durations.map(\.exerciseId) == ["treadmill_warmup"])
    }

    @Test func latestMatchesTheEditorsPreviousLine() throws {
        let tread = step("treadmill_warmup"), s1 = session(daysAgo: 2), s2 = session(daysAgo: 1)
        let results = [timed(s1, tread, seconds: 600), timed(s2, tread, set: 0, seconds: 300), timed(s2, tread, set: 1, seconds: 450)]
        let progress = try #require(insight([tread], [s1, s2], results))
        let previous = try #require(PreviousPerformanceQuery.lastTimedPerformance(
            exerciseId: "treadmill_warmup", excludingSessionId: nil, steps: [tread], sessions: [s1, s2], results: results
        ))
        #expect(previous.totalSeconds == progress.latestSeconds)
        #expect(SetDuration.text(progress.latestSeconds) == "12分30秒")
        #expect(SetDuration.text(progress.bestSeconds) == "12分30秒")
    }
}
