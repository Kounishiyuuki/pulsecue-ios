//
//  WorkoutCompletionTests.swift
//  Pulse CueTests
//
//  Locks the Workout Completion contract: a normally finished workout hands
//  back exactly one transient summary describing exactly one finalized
//  Session, skipped work is never counted as completed, quitting shows no
//  completion screen, and dismissing the summary writes nothing.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct WorkoutCompletionTests {

    // MARK: - Fixture

    private struct Fixture {
        let viewModel: RunnerViewModel
        let routine: Routine
        let context: ModelContext
    }

    private static func makeFixture(
        stepCount: Int = 1,
        setsPerStep: Int = 1,
        restSeconds: Int = 0
    ) throws -> Fixture {
        RunnerPersistence.clear()

        let schema = Schema([Routine.self, Step.self, Session.self, StepResult.self, DayLog.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let routine = Routine(name: "Completion Routine")
        context.insert(routine)
        for index in 0..<stepCount {
            context.insert(
                Step(
                    routineId: routine.id,
                    order: index,
                    title: "Step \(index)",
                    sets: setsPerStep,
                    repsTarget: 10,
                    restSeconds: restSeconds
                )
            )
        }
        try context.save()

        let defaults = UserDefaults(suiteName: "test.completion.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.notificationsEnabled = false

        let viewModel = RunnerViewModel(settings: settings)
        viewModel.configure(modelContext: context)
        return Fixture(viewModel: viewModel, routine: routine, context: context)
    }

    private static func complete(_ viewModel: RunnerViewModel) throws {
        let context = try #require(viewModel.completeContext)
        viewModel.handle(action: .complete, context: context)
    }

    private static func sessions(_ context: ModelContext) throws -> [Session] {
        try context.fetch(FetchDescriptor<Session>())
    }

    // MARK: - Normal completion

    @Test
    func completingFinalSetProducesCompletionSummary() throws {
        let fx = try Self.makeFixture()
        fx.viewModel.start(routine: fx.routine)
        #expect(fx.viewModel.completion == nil)

        try Self.complete(fx.viewModel)

        let summary = try #require(fx.viewModel.completion)
        #expect(fx.viewModel.isRunning == false)
        #expect(summary.completedExerciseCount == 1)
        #expect(summary.completedSetCount == 1)
    }

    @Test
    func completionDescribesTheOneFinalizedSession() throws {
        let fx = try Self.makeFixture()
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)

        let all = try Self.sessions(fx.context)
        #expect(all.count == 1)
        let session = try #require(all.first)
        let summary = try #require(fx.viewModel.completion)
        #expect(summary.sessionId == session.id)
        #expect(session.status == .completed)
        #expect(session.endedAt != nil)
    }

    @Test
    func durationMatchesTheFinalizedSession() throws {
        let fx = try Self.makeFixture()
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)

        let session = try #require(try Self.sessions(fx.context).first)
        let endedAt = try #require(session.endedAt)
        let summary = try #require(fx.viewModel.completion)
        #expect(session.totalSeconds == Int(endedAt.timeIntervalSince(session.startedAt)))
        // Completion reads the stored seconds, the same value History shows.
        #expect(summary.duration == TimeInterval(session.totalSeconds))
    }

    @Test
    func aFractionalRunnerDurationReadsTheSameAsHistory() throws {
        let fx = try Self.makeFixture()
        fx.viewModel.start(routine: fx.routine)
        let session = try #require(try Self.sessions(fx.context).first)
        session.startedAt = Date().addingTimeInterval(-20.6)
        try Self.complete(fx.viewModel)

        let summary = try #require(fx.viewModel.completion)
        #expect(session.totalSeconds == 20)
        #expect(summary.duration == 20)
        let history = WorkoutCompletionSummary.make(
            sessionId: session.id, duration: TimeInterval(session.totalSeconds),
            results: try fx.context.fetch(FetchDescriptor<StepResult>()), steps: try fx.context.fetch(FetchDescriptor<Step>()))
        #expect(history == summary)
    }

    @Test
    func aTimedRunnerSetRecordsNoReps() throws {
        let fx = try Self.makeFixture()
        let step = try #require(try fx.context.fetch(FetchDescriptor<Step>()).first)
        step.exerciseId = "treadmill_warmup"
        try fx.context.save()
        fx.viewModel.start(routine: fx.routine)
        #expect(fx.viewModel.currentStepTracksReps == false)
        // No duration yet: nothing to complete, and the reason is known.
        #expect(fx.viewModel.currentDurationIssue == .empty)
        #expect(fx.viewModel.completeContext == nil)
        fx.viewModel.setCurrentDuration(DurationEntry(minutes: "5"))
        #expect(fx.viewModel.currentDurationIssue == nil)
        try Self.complete(fx.viewModel)

        let result = try #require(try fx.context.fetch(FetchDescriptor<StepResult>()).first)
        #expect(result.done)
        #expect(result.actualReps == nil)
        #expect(result.actualDurationSeconds == 300)
        #expect(fx.viewModel.completion?.totalReps == 0)
    }

    @Test
    func aTimedRunnerSetCannotCompleteWithAnInvalidDuration() throws {
        let fx = try Self.makeFixture()
        let step = try #require(try fx.context.fetch(FetchDescriptor<Step>()).first)
        step.exerciseId = "treadmill_warmup"
        try fx.context.save()
        fx.viewModel.start(routine: fx.routine)
        for (entry, issue) in [
            (DurationEntry(minutes: "0", seconds: "0"), DurationEntry.Issue.zero),
            (DurationEntry(minutes: "1", seconds: "60"), .invalidSeconds),
            (DurationEntry(minutes: "-1"), .invalidMinutes),
        ] {
            fx.viewModel.setCurrentDuration(entry)
            #expect(fx.viewModel.currentDuration == entry)          // kept as typed, never clamped
            #expect(fx.viewModel.currentDurationIssue == issue)
            #expect(fx.viewModel.completeContext == nil)
        }
        #expect(try fx.context.fetch(FetchDescriptor<StepResult>()).isEmpty)
    }

    @Test
    func aRepRunnerSetIsUnchangedByDurations() throws {
        let fx = try Self.makeFixture()
        fx.viewModel.start(routine: fx.routine)
        #expect(fx.viewModel.currentStepTracksReps)
        fx.viewModel.setCurrentDuration(DurationEntry(minutes: "5"))   // ignored
        #expect(fx.viewModel.currentDuration == DurationEntry())
        #expect(fx.viewModel.currentDurationIssue == nil)
        try Self.complete(fx.viewModel)
        let result = try #require(try fx.context.fetch(FetchDescriptor<StepResult>()).first)
        #expect(result.actualReps != nil)
        #expect(result.actualDurationSeconds == nil)
    }

    @Test
    func multiSetWorkoutCountsEveryCompletedSet() throws {
        let fx = try Self.makeFixture(stepCount: 2, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)
        for _ in 0..<4 { try Self.complete(fx.viewModel) }

        let summary = try #require(fx.viewModel.completion)
        #expect(summary.completedExerciseCount == 2)
        #expect(summary.completedSetCount == 4)
    }

    // MARK: - Skip

    @Test
    func skippingTheFinalExerciseAlsoReachesCompletion() throws {
        let fx = try Self.makeFixture()
        fx.viewModel.start(routine: fx.routine)

        fx.viewModel.handle(action: .skip)

        #expect(fx.viewModel.completion != nil)
        #expect(try Self.sessions(fx.context).count == 1)
    }

    @Test
    func skippedSetsAreNotCountedAsCompleted() throws {
        // Exercise 0 fully completed (2 sets), exercise 1 skipped outright.
        let fx = try Self.makeFixture(stepCount: 2, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)
        try Self.complete(fx.viewModel)
        fx.viewModel.handle(action: .skip)

        let summary = try #require(fx.viewModel.completion)
        #expect(summary.completedExerciseCount == 1)
        #expect(summary.completedSetCount == 2)
    }

    @Test
    func skippingEverythingCompletesWithNothingCounted() throws {
        let fx = try Self.makeFixture(stepCount: 2, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.handle(action: .skip)
        fx.viewModel.handle(action: .skip)

        let summary = try #require(fx.viewModel.completion)
        #expect(summary.completedExerciseCount == 0)
        #expect(summary.completedSetCount == 0)
    }

    // MARK: - Quit

    @Test
    func quittingShowsNoCompletionScreen() throws {
        let fx = try Self.makeFixture(stepCount: 2, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)

        fx.viewModel.endSessionEarly()

        #expect(fx.viewModel.completion == nil)
        #expect(fx.viewModel.shouldPresentRunner == false)
        let session = try #require(try Self.sessions(fx.context).first)
        #expect(session.status == .abandoned)
    }

    // MARK: - Dismissal

    @Test
    func dismissCompletionClearsItWithoutTouchingHistory() throws {
        let fx = try Self.makeFixture()
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)

        let before = try Self.sessions(fx.context)
        #expect(before.count == 1)
        let endedAt = try #require(before.first?.endedAt)

        fx.viewModel.dismissCompletion()

        #expect(fx.viewModel.completion == nil)
        let after = try Self.sessions(fx.context)
        #expect(after.count == 1)
        #expect(after.first?.endedAt == endedAt)
        #expect(after.first?.status == .completed)
    }

    @Test
    func coverStaysPresentedUntilCompletionIsDismissed() throws {
        let fx = try Self.makeFixture()
        fx.viewModel.start(routine: fx.routine)
        #expect(fx.viewModel.shouldPresentRunner)

        try Self.complete(fx.viewModel)
        #expect(fx.viewModel.isRunning == false)
        #expect(fx.viewModel.shouldPresentRunner)

        fx.viewModel.dismissCompletion()
        #expect(fx.viewModel.shouldPresentRunner == false)
    }

    // MARK: - No duplicate finalization

    @Test
    func repeatedFinalActionsDoNotFinalizeTwice() throws {
        let fx = try Self.makeFixture()
        fx.viewModel.start(routine: fx.routine)

        // Capture the context the final Complete was issued with, then replay
        // it plus every other action a stale callback could fire.
        let staleContext = try #require(fx.viewModel.completeContext)
        fx.viewModel.handle(action: .complete, context: staleContext)
        let summary = try #require(fx.viewModel.completion)

        fx.viewModel.handle(action: .complete, context: staleContext)
        fx.viewModel.handle(action: .complete)
        fx.viewModel.handle(action: .skip)
        fx.viewModel.handle(action: .extend)
        fx.viewModel.handle(action: .back)
        fx.viewModel.appDidBecomeActive()

        #expect(fx.viewModel.completion == summary)
        let all = try Self.sessions(fx.context)
        #expect(all.count == 1)
        #expect(all.first?.status == .completed)
        #expect(all.first?.endedAt != nil)
    }

    @Test
    func dismissingCompletionStartsNoNewSession() throws {
        let fx = try Self.makeFixture()
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)
        fx.viewModel.dismissCompletion()

        #expect(fx.viewModel.isRunning == false)
        #expect(try Self.sessions(fx.context).count == 1)
    }

    @Test
    func startingAnotherWorkoutClearsThePreviousCompletion() throws {
        let fx = try Self.makeFixture()
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)
        #expect(fx.viewModel.completion != nil)

        fx.viewModel.start(routine: fx.routine)

        #expect(fx.viewModel.completion == nil)
        #expect(fx.viewModel.isRunning)
        #expect(try Self.sessions(fx.context).count == 2)
    }
}

// MARK: - Summary metrics

/// The totals shown on the Completion screen and in History detail, from a
/// session's results alone.
@MainActor
struct WorkoutSummaryMetricsTests {

    private let context: ModelContext
    private let sessionId = UUID()
    private let routineId = UUID()

    init() throws {
        let schema = Schema([Routine.self, Step.self, Session.self, StepResult.self])
        context = ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]))
    }

    private func step(_ exerciseId: String?, order: Int = 0) -> Step {
        let step = Step(routineId: routineId, order: order, title: exerciseId ?? "カスタム", sets: 3,
                        repsTarget: 10, restSeconds: 0, exerciseId: exerciseId)
        context.insert(step)
        return step
    }

    private func result(_ step: Step, _ index: Int, kg: Double?, reps: Int?, done: Bool = true) -> StepResult {
        let result = StepResult(sessionId: sessionId, stepId: step.id, setIndex: index, done: done,
                                actualReps: reps, weightKg: kg, exerciseIdAtExecution: step.exerciseId)
        context.insert(result)
        return result
    }

    private func summary(_ results: [StepResult], _ steps: [Step], duration: TimeInterval = 0) -> WorkoutCompletionSummary {
        WorkoutCompletionSummary.make(sessionId: sessionId, duration: duration, results: results, steps: steps)
    }

    @Test func aBenchPressOfThreeSets() {
        let bench = step("bench_press")
        let s = summary([result(bench, 0, kg: 80, reps: 10), result(bench, 1, kg: 80, reps: 9),
                         result(bench, 2, kg: 75, reps: 10)], [bench])
        #expect(s.completedExerciseCount == 1)
        #expect(s.completedSetCount == 3)
        #expect(s.totalReps == 29)
        #expect(s.totalVolumeKg == 2270)
    }

    @Test func twoExercisesAddUp() {
        let bench = step("bench_press"), squat = step("smith_bench_press", order: 1)
        let s = summary([result(bench, 0, kg: 80, reps: 10), result(bench, 1, kg: 80, reps: 9),
                         result(squat, 0, kg: 100, reps: 5), result(squat, 1, kg: 100, reps: 5)], [bench, squat])
        #expect(s.completedExerciseCount == 2)
        #expect(s.completedSetCount == 4)
        #expect(s.totalReps == 29)
        #expect(s.totalVolumeKg == 800 + 720 + 500 + 500)
    }

    @Test func skippedSetsAddNothing() {
        let bench = step("bench_press"), skippedOnly = step("smith_bench_press", order: 1)
        let s = summary([result(bench, 0, kg: 80, reps: 10),
                         result(bench, 1, kg: nil, reps: nil, done: false),
                         result(bench, 2, kg: 75, reps: 10),
                         result(skippedOnly, 0, kg: nil, reps: nil, done: false)], [bench, skippedOnly])
        #expect(s.completedExerciseCount == 1)   // an exercise only skipped is not performed
        #expect(s.completedSetCount == 2)
        #expect(s.totalReps == 20)
        #expect(s.totalVolumeKg == 1550)
    }

    @Test func theSameExerciseAddedTwiceCountsAsTwo() {
        let first = step("bench_press"), second = step("bench_press", order: 1)
        let s = summary([result(first, 0, kg: 80, reps: 10), result(second, 0, kg: 60, reps: 12)], [first, second])
        #expect(s.completedExerciseCount == 2)
        #expect(s.totalReps == 22)
        #expect(s.totalVolumeKg == 800 + 720)
    }

    @Test func repsWithoutAWeightAddNoVolume() {
        let bench = step("bench_press"), custom = step(nil, order: 1)
        let s = summary([result(bench, 0, kg: nil, reps: 10), result(custom, 0, kg: nil, reps: 15)], [bench, custom])
        #expect(s.totalReps == 25)
        #expect(s.totalVolumeKg == 0)
    }

    @Test func aBodyweightExerciseWithoutAddedWeightAddsNoVolume() {
        let pullUp = step("pull_up")
        let s = summary([result(pullUp, 0, kg: nil, reps: 10)], [pullUp])
        #expect(s.totalReps == 10)
        #expect(s.totalVolumeKg == 0)   // no body weight is ever guessed in
    }

    @Test func aBodyweightExerciseCountsOnlyItsAddedWeight() {
        let pullUp = step("pull_up"), chinUp = step("chin_up", order: 1)
        let s = summary([result(pullUp, 0, kg: 20, reps: 10), result(pullUp, 1, kg: nil, reps: 6),
                         result(chinUp, 0, kg: 0, reps: 8)], [pullUp, chinUp])
        #expect(s.completedSetCount == 3)
        #expect(s.totalReps == 24)
        #expect(s.totalVolumeKg == 200)   // +20 kg × 10; body weight not added
    }

    @Test func timedExercisesCountNoReps() {
        let treadmill = step("treadmill_warmup")
        // An older timed set may still carry a rep count; it is kept but not summed.
        let s = summary([result(treadmill, 0, kg: nil, reps: 10)], [treadmill])
        #expect(s.completedSetCount == 1)
        #expect(s.totalReps == 0)
    }

    @Test func timedAndRepExercisesMixed() {
        let rower = step("rowing_machine"), bench = step("bench_press", order: 1), bike = step("bike_finisher", order: 2)
        let s = summary([result(rower, 0, kg: nil, reps: 10), result(bench, 0, kg: 80, reps: 10),
                         result(bike, 0, kg: nil, reps: nil)], [rower, bench, bike])
        #expect(s.completedExerciseCount == 3)
        #expect(s.completedSetCount == 3)
        #expect(s.totalReps == 10)
        #expect(s.totalVolumeKg == 800)
    }

    @Test func assistedPullUpAssistanceIsNotVolume() {
        let assisted = step("assisted_pull_up")
        let s = summary([result(assisted, 0, kg: 40, reps: 10)], [assisted])
        #expect(s.totalReps == 10)
        #expect(s.totalVolumeKg == 0)
    }

    @Test func assistedChinUpAssistanceIsNotVolume() {
        let assisted = step("assisted_chin_up")
        let s = summary([result(assisted, 0, kg: 40, reps: 10)], [assisted])
        #expect(s.totalReps == 10)
        #expect(s.totalVolumeKg == 0)
    }

    @Test func aNormalWeightedSetIsUnchanged() {
        let bench = step("bench_press")
        let s = summary([result(bench, 0, kg: 80, reps: 10)], [bench])
        #expect(s.totalReps == 10 && s.totalVolumeKg == 800)
    }

    @Test func onlyTheAssistedMachineMovementsCarryAssistance() {
        let assisted = ExerciseLibrary.all.filter { $0.loadSemantics == .assistance }.map(\.id.rawValue).sorted()
        #expect(assisted == ["assisted_chin_up", "assisted_pull_up"])
    }

    @Test func timedExercisesAddNoVolume() {
        let treadmill = step("treadmill_warmup")
        let s = summary([result(treadmill, 0, kg: 5, reps: 1)], [treadmill])
        #expect(s.completedSetCount == 1)
        #expect(s.totalVolumeKg == 0)
    }

    @Test func aCustomExerciseCountsTheWeightItRecorded() {
        let custom = step(nil)
        let s = summary([result(custom, 0, kg: 20, reps: 10)], [custom])
        #expect(s.totalVolumeKg == 200)
    }

    @Test func durationIsTheOneSuppliedNeverTheClock() {
        let bench = step("bench_press")
        let s = summary([result(bench, 0, kg: 80, reps: 10)], [bench], duration: 2_732)
        #expect(s.duration == 2_732)
    }

    @Test func otherSessionsResultsAreIgnored() {
        let bench = step("bench_press")
        let stray = StepResult(sessionId: UUID(), stepId: bench.id, setIndex: 0, done: true, actualReps: 10, weightKg: 100)
        let s = summary([result(bench, 0, kg: 80, reps: 10), stray], [bench])
        #expect(s.completedSetCount == 1 && s.totalVolumeKg == 800)
    }

    @Test func volumeReadsGroupedWithoutATrailingZero() {
        #expect(WorkoutCompletionSummary.volumeText(6420) == "6,420 kg")
        #expect(WorkoutCompletionSummary.volumeText(6420.5) == "6,420.5 kg")
        #expect(WorkoutCompletionSummary.volumeText(0) == "0 kg")
    }

    @Test func aRoutineWorkoutUsesTheSameTotals() throws {
        // The Runner's completion screen goes through the same calculation.
        let schema = Schema([Routine.self, Step.self, Session.self, StepResult.self, DayLog.self])
        let context = ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]))
        let routine = Routine(name: "胸の日")
        context.insert(routine)
        context.insert(Step(routineId: routine.id, order: 0, title: "ベンチプレス", sets: 1, repsTarget: 10,
                            restSeconds: 0, exerciseId: "bench_press"))
        try context.save()
        RunnerPersistence.clear()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.summary.\(UUID().uuidString)")!)
        settings.notificationsEnabled = false
        let runner = RunnerViewModel(settings: settings)
        runner.configure(modelContext: context)
        runner.start(routine: routine)
        runner.handle(action: .complete, context: try #require(runner.completeContext))

        let summary = try #require(runner.completion)
        let result = try #require(try context.fetch(FetchDescriptor<StepResult>()).first)
        #expect(summary.completedSetCount == 1)
        #expect(summary.totalReps == (result.actualReps ?? 0))
        #expect(summary.totalVolumeKg == (result.weightKg ?? 0) * Double(result.actualReps ?? 0))
    }
}

// MARK: - Estimated calories

/// The estimated-calorie figure: one workout-level MET, the owner's weight
/// at the time of the workout, and nothing shown when either input is missing.
@MainActor
struct WorkoutEstimatedCaloriesTests {

    private let context: ModelContext
    private let accountA = UUID()
    private let accountB = UUID()

    init() throws {
        let schema = Schema([Routine.self, Step.self, Session.self, StepResult.self, DayLog.self, UserProfile.self])
        context = ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]))
    }

    private func day(_ month: Int, _ day: Int, hour: Int = 0) -> Date {
        let start = DateUtils.startOfDay(Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day))!)
        return start.addingTimeInterval(TimeInterval(hour * 3600))
    }

    private func weigh(_ date: Date, _ kg: Double?, owner: UUID? = nil) {
        context.insert(DayLog(date: DateUtils.startOfDay(date), weightKg: kg, ownerAccountID: owner))
    }

    private func session(at start: Date, owner: UUID? = nil) -> Session {
        let session = Session(routineId: UUID(), dayDate: DateUtils.startOfDay(start), startedAt: start, ownerAccountID: owner)
        context.insert(session)
        return session
    }

    private func weight(_ session: Session) -> Double? {
        WorkoutCalorieEstimator.bodyWeightKg(for: session, modelContext: context)
    }

    // MARK: formula

    @Test func metIsTheConservativeResistanceTrainingValue() {
        #expect(WorkoutCalorieEstimator.met == 3.5)
    }

    @Test func eightyKilogramsForAnHourIs294Kcal() {
        // 3.5 × 3.5 × 80 / 200 × 60 = 294
        #expect(WorkoutCalorieEstimator.estimatedCalories(bodyWeightKg: 80, duration: 3_600) == 294)
    }

    @Test func fractionalKcalRoundToTheNearestWholeNumber() {
        // 3.5 × 3.5 × 61 / 200 × 10 = 37.3625 → 37
        #expect(WorkoutCalorieEstimator.estimatedCalories(bodyWeightKg: 61, duration: 600) == 37)
        // 3.5 × 3.5 × 70 / 200 × 31 = 132.90625 → 133
        #expect(WorkoutCalorieEstimator.estimatedCalories(bodyWeightKg: 70, duration: 1_860) == 133)
    }

    @Test func noWeightOrNoDurationGivesNoEstimate() {
        #expect(WorkoutCalorieEstimator.estimatedCalories(bodyWeightKg: nil, duration: 3_600) == nil)
        #expect(WorkoutCalorieEstimator.estimatedCalories(bodyWeightKg: 0, duration: 3_600) == nil)
        #expect(WorkoutCalorieEstimator.estimatedCalories(bodyWeightKg: 80, duration: 0) == nil)
        #expect(WorkoutCalorieEstimator.estimatedCalories(bodyWeightKg: 80, duration: -60) == nil)
    }

    @Test func textAndSummaryCarryTheEstimate() {
        #expect(WorkoutCalorieEstimator.text(245) == "245 kcal")
        let none = WorkoutCompletionSummary.make(sessionId: UUID(), duration: 3_600, results: [], steps: [])
        #expect(none.estimatedCalories == nil)
        let some = WorkoutCompletionSummary.make(sessionId: UUID(), duration: 3_600, results: [], steps: [], bodyWeightKg: 80)
        #expect(some.estimatedCalories == 294)
    }

    @Test func zeroVolumeStillHasAnEstimate() {
        // A bodyweight / timed workout lifts nothing, yet it took time.
        let summary = WorkoutCompletionSummary.make(sessionId: UUID(), duration: 1_800, results: [], steps: [], bodyWeightKg: 80)
        #expect(summary.totalVolumeKg == 0)
        #expect(summary.estimatedCalories == 147)
    }

    // MARK: body weight lookup

    @Test func usesTheNewestWeighInOnOrBeforeTheWorkout() {
        weigh(day(11, 1), 82); weigh(day(11, 8), 80); weigh(day(11, 12), 79)
        #expect(weight(session(at: day(11, 10, hour: 18))) == 80)
    }

    @Test func aLaterWeighInIsNeverUsed() {
        weigh(day(11, 2), 80)
        #expect(weight(session(at: day(11, 1, hour: 18))) == nil)
    }

    @Test func aWeighInFromTheWorkoutsOwnDayCounts() {
        weigh(day(11, 1), 82); weigh(day(11, 10), 78)
        #expect(weight(session(at: day(11, 10, hour: 6))) == 78)
    }

    @Test func aGoalWeightIsNotABodyWeight() {
        weigh(day(11, 1), nil)   // a log with no weight in it
        let profile = UserProfile()
        profile.goalWeightKg = 65
        context.insert(profile)
        let summary = WorkoutCompletionSummary.make(sessionId: UUID(), duration: 3_600, results: [], steps: [],
                                                    bodyWeightKg: weight(session(at: day(11, 10))))
        #expect(summary.estimatedCalories == nil)
    }

    @Test func anAccountsWorkoutUsesOnlyThatAccountsWeight() {
        weigh(day(11, 1), 80, owner: accountA)
        weigh(day(11, 1), 60, owner: accountB)
        weigh(day(11, 1), 70)
        #expect(weight(session(at: day(11, 10), owner: accountA)) == 80)
        #expect(weight(session(at: day(11, 10), owner: accountB)) == 60)
    }

    @Test func aGuestWorkoutUsesOnlyGuestWeight() {
        weigh(day(11, 1), 90, owner: accountA)
        #expect(weight(session(at: day(11, 10))) == nil)
        weigh(day(11, 2), 70)
        #expect(weight(session(at: day(11, 10))) == 70)
    }

    // MARK: Runner

    @Test func runnerCompletionShowsTheSameEstimateAsHistory() throws {
        RunnerPersistence.clear()
        let routine = Routine(name: "Calorie Routine")
        context.insert(routine)
        context.insert(Step(routineId: routine.id, order: 0, title: "Squat", sets: 1, repsTarget: 10, restSeconds: 0))
        weigh(Date().addingTimeInterval(-3 * 86_400), 80)
        try context.save()

        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.calories.\(UUID().uuidString)")!)
        settings.notificationsEnabled = false
        let viewModel = RunnerViewModel(settings: settings)
        viewModel.configure(modelContext: context)
        viewModel.start(routine: routine)
        let running = try #require(try context.fetch(FetchDescriptor<Session>()).first)
        running.startedAt = running.startedAt.addingTimeInterval(-1_800)
        viewModel.handle(action: .complete, context: try #require(viewModel.completeContext))

        let summary = try #require(viewModel.completion)
        let finished = try #require(try context.fetch(FetchDescriptor<Session>()).first)
        #expect(summary.estimatedCalories == WorkoutCalorieEstimator.estimatedCalories(
            bodyWeightKg: 80, duration: TimeInterval(finished.totalSeconds)))
        #expect(summary.estimatedCalories != nil)

        let history = WorkoutCompletionSummary.make(
            sessionId: finished.id, duration: TimeInterval(finished.totalSeconds),
            results: try context.fetch(FetchDescriptor<StepResult>()),
            steps: try context.fetch(FetchDescriptor<Step>()),
            bodyWeightKg: weight(finished)
        )
        #expect(history == summary)
    }
}
