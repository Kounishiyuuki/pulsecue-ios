//
//  ExerciseReplacementApplyTests.swift
//  Pulse CueTests
//
//  Applying a replacement in the Preview (GeneratedPlanViewModel) and live in
//  the Runner (RunnerViewModel): only the targeted exercise changes, the
//  original sets / reps / rest carry over, completed sets and session identity
//  are never touched, and a completed / in-progress exercise is refused.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct ExerciseReplacementApplyTests {

    // MARK: - Fixtures

    private static func candidate(
        machineId: String = "chest_press",
        name: String = "チェストプレス",
        exerciseId: ExerciseID? = "machine_chest_press"
    ) -> GeneratedExercise {
        // Intentionally different sets/reps/rest from the fixtures so tests can
        // prove the original prescription is what carries over.
        GeneratedExercise(
            machineId: machineId,
            exerciseName: name,
            sets: 99, reps: 99, restSeconds: 999,
            cue: "置換キュー",
            exerciseId: exerciseId
        )
    }

    // MARK: - Preview replacement (GeneratedPlanViewModel)

    private static func previewContext() throws -> (ModelContext, Gym) {
        let schema = Schema([Routine.self, Step.self, Gym.self, GymMachine.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let repo = GymRepository(modelContext: context)
        let gym = repo.createGym(name: "Test", makeActive: true)
        repo.setMachines(["bench_press", "chest_press", "pec_deck", "incline_chest_press"], for: gym)
        return (context, gym)
    }

    @Test
    func previewReplacesOnlyTheTargetedExerciseAndKeepsPrescription() throws {
        let (context, gym) = try Self.previewContext()
        let vm = GeneratedPlanViewModel(
            gym: gym,
            request: QuickPlanRequest(bodyParts: [.chest], duration: .standardPlus, intensity: .standard)
        )
        vm.configure(modelContext: context)

        let before = try #require(vm.plan)
        try #require(before.exercises.count >= 2)
        let target = 1
        let original = before.exercises[target]
        let othersBefore = before.exercises.enumerated().filter { $0.offset != target }.map(\.element)

        vm.replaceExercise(at: target, with: Self.candidate())

        let after = try #require(vm.plan)
        // Targeted exercise now carries the candidate identity…
        #expect(after.exercises[target].machineId == "chest_press")
        #expect(after.exercises[target].exerciseName == "チェストプレス")
        // …but the ORIGINAL sets / reps / rest, not the candidate's.
        #expect(after.exercises[target].sets == original.sets)
        #expect(after.exercises[target].reps == original.reps)
        #expect(after.exercises[target].restSeconds == original.restSeconds)
        // Every other exercise is untouched.
        let othersAfter = after.exercises.enumerated().filter { $0.offset != target }.map(\.element)
        #expect(othersAfter == othersBefore)
    }

    // MARK: - Runner replacement (RunnerViewModel)

    private struct RunnerFixture {
        let vm: RunnerViewModel
        let routine: Routine
        let context: ModelContext
    }

    private static func runnerFixture(restSeconds: Int, setsPerStep: Int = 2, stepCount: Int = 3) throws -> RunnerFixture {
        RunnerPersistence.clear()
        let schema = Schema([Routine.self, Step.self, Session.self, StepResult.self, DayLog.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let routine = Routine(name: "Test Routine")
        context.insert(routine)
        for index in 0..<stepCount {
            context.insert(Step(
                routineId: routine.id, order: index, title: "Step \(index)",
                sets: setsPerStep, repsTarget: 10, restSeconds: restSeconds,
                exerciseId: "bench_press"
            ))
        }
        try context.save()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.repl.\(UUID().uuidString)")!)
        settings.notificationsEnabled = false
        let vm = RunnerViewModel(settings: settings)
        vm.configure(modelContext: context)
        return RunnerFixture(vm: vm, routine: routine, context: context)
    }

    private static func stepResultCount(_ context: ModelContext) -> Int {
        (try? context.fetch(FetchDescriptor<StepResult>()))?.count ?? 0
    }

    @Test
    func runnerReplacesUnstartedNextExerciseKeepingPrescription() throws {
        let fx = try Self.runnerFixture(restSeconds: 60)
        fx.vm.start(routine: fx.routine)
        let next = try #require(fx.vm.nextStep)
        let originalSets = next.sets, originalReps = next.repsTarget, originalRest = next.restSeconds
        let sessionBefore = fx.vm.sessionId

        #expect(fx.vm.replaceExercise(next, with: Self.candidate()) == true)

        #expect(next.title == "チェストプレス")
        #expect(next.sets == originalSets)
        #expect(next.repsTarget == originalReps)
        #expect(next.restSeconds == originalRest)
        #expect(fx.vm.sessionId == sessionBefore)          // session identity intact
        #expect(Self.stepResultCount(fx.context) == 0)     // no history written
    }

    @Test
    func runnerReplacesCurrentExerciseWhileUnstarted() throws {
        let fx = try Self.runnerFixture(restSeconds: 60)
        fx.vm.start(routine: fx.routine)
        let current = try #require(fx.vm.currentStep)
        #expect(fx.vm.canReplaceCurrentExercise)

        #expect(fx.vm.replaceExercise(current, with: Self.candidate()) == true)
        #expect(current.title == "チェストプレス")
        #expect(fx.vm.currentStepIndex == 0)               // position unchanged
    }

    @Test
    func runnerRefusesToReplaceCurrentAfterASetIsCompleted() throws {
        // restSeconds 0 so completing a set advances the set index without rest.
        let fx = try Self.runnerFixture(restSeconds: 0, setsPerStep: 2)
        fx.vm.start(routine: fx.routine)
        let current = try #require(fx.vm.currentStep)
        let titleBefore = current.title

        let ctx = try #require(fx.vm.completeContext)
        fx.vm.handle(action: .complete, context: ctx)      // set 0 done → set index 1
        #expect(fx.vm.currentSetIndex == 1)
        #expect(!fx.vm.canReplaceCurrentExercise)

        #expect(fx.vm.replaceExercise(current, with: Self.candidate()) == false)
        #expect(current.title == titleBefore)              // in-progress exercise untouched
    }

    @Test
    func runnerRefusesToReplaceACompletedExercise() throws {
        let fx = try Self.runnerFixture(restSeconds: 0, setsPerStep: 1, stepCount: 3)
        fx.vm.start(routine: fx.routine)
        let firstStep = try #require(fx.vm.currentStep)

        // Complete the single set of step 0 → advance to step 1.
        let ctx = try #require(fx.vm.completeContext)
        fx.vm.handle(action: .complete, context: ctx)
        #expect(fx.vm.currentStepIndex == 1)

        let titleBefore = firstStep.title
        #expect(fx.vm.replaceExercise(firstStep, with: Self.candidate()) == false)
        #expect(firstStep.title == titleBefore)            // completed exercise never rewritten
    }

    @Test
    func replacingNextDoesNotDisturbACompletedSetResult() throws {
        let fx = try Self.runnerFixture(restSeconds: 0, setsPerStep: 2)
        fx.vm.start(routine: fx.routine)
        let ctx = try #require(fx.vm.completeContext)
        fx.vm.handle(action: .complete, context: ctx)      // records one StepResult
        let resultsAfterComplete = Self.stepResultCount(fx.context)
        #expect(resultsAfterComplete == 1)

        let next = try #require(fx.vm.nextStep)
        #expect(fx.vm.replaceExercise(next, with: Self.candidate()) == true)
        #expect(Self.stepResultCount(fx.context) == resultsAfterComplete) // unchanged
    }
}

/// Editing sets / reps / rest in the Preview: the estimate follows the edit
/// through the same `WorkoutDurationEstimator`, and 保存 persists the edited
/// values, never the generated ones.
@MainActor
struct GeneratedPlanEditingTests {

    private static func viewModel() throws -> (GeneratedPlanViewModel, ModelContext) {
        let schema = Schema([Routine.self, Step.self, Gym.self, GymMachine.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let repo = GymRepository(modelContext: context)
        let gym = repo.createGym(name: "Test", makeActive: true)
        repo.setMachines(["bench_press", "chest_press", "pec_deck", "incline_chest_press"], for: gym)
        let vm = GeneratedPlanViewModel(
            gym: gym,
            request: QuickPlanRequest(bodyParts: [.chest], duration: .standardPlus, intensity: .standard)
        )
        vm.configure(modelContext: context)
        return (vm, context)
    }

    @Test
    func editingSetsRepsAndRestUpdatesTheEstimate() throws {
        let (vm, _) = try Self.viewModel()
        let plan = try #require(vm.plan)
        try #require(!plan.exercises.isEmpty)
        #expect(vm.estimatedMinutes == WorkoutDurationEstimator.minutes(forPlan: plan.exercises))

        let original = plan.exercises[0]
        var previous = vm.estimatedMinutes
        vm.updatePrescription(at: 0, sets: original.sets + 3)
        #expect(vm.estimatedMinutes > previous)

        previous = vm.estimatedMinutes
        vm.updatePrescription(at: 0, reps: original.reps + 10)
        #expect(vm.estimatedMinutes > previous)

        previous = vm.estimatedMinutes
        vm.updatePrescription(at: 0, restSeconds: 0)
        #expect(vm.estimatedMinutes < previous)

        // Always the shared estimator on the current plan — no second formula.
        #expect(vm.estimatedMinutes == WorkoutDurationEstimator.minutes(forPlan: try #require(vm.plan).exercises))
    }

    @Test
    func replacingAnExerciseKeepsTheEstimateOnTheSameSource() throws {
        let (vm, _) = try Self.viewModel()
        // The 60-minute fixture uses every machine, so pass a candidate directly.
        let candidate = GeneratedExercise(
            machineId: "cable_machine", exerciseName: "ケーブルクロスオーバー",
            sets: 3, reps: 12, restSeconds: 60, cue: "", exerciseId: "cable_crossover"
        )
        vm.replaceExercise(at: 0, with: candidate)
        #expect(try #require(vm.plan).exercises[0].machineId == "cable_machine")
        #expect(vm.estimatedMinutes == WorkoutDurationEstimator.minutes(forPlan: try #require(vm.plan).exercises))
    }

    @Test
    func editsAreClampedToTheEditableRanges() throws {
        let (vm, _) = try Self.viewModel()
        vm.updatePrescription(at: 0, sets: 0, reps: 999, restSeconds: -5)
        let edited = try #require(vm.plan).exercises[0]
        #expect(edited.sets == GeneratedPlanViewModel.editableSets.lowerBound)
        #expect(edited.reps == GeneratedPlanViewModel.editableReps.upperBound)
        #expect(edited.restSeconds == GeneratedPlanViewModel.editableRestSeconds.lowerBound)
    }

    @Test
    func savePersistsTheEditedValues() throws {
        let (vm, context) = try Self.viewModel()
        vm.updatePrescription(at: 0, sets: 6, reps: 5, restSeconds: 150)
        vm.saveAsRoutine()

        let steps = try context.fetch(FetchDescriptor<Step>()).sorted { $0.order < $1.order }
        let first = try #require(steps.first)
        #expect(first.sets == 6)
        #expect(first.repsTarget == 5)
        #expect(first.restSeconds == 150)
        #expect(steps.count == vm.plan?.exercises.count)
    }

    @Test
    func editAfterStartRebuildsTheRoutineFromTheEditedPlan() throws {
        let (vm, context) = try Self.viewModel()
        let runner = RunnerViewModel(settings: SettingsStore(defaults: UserDefaults(suiteName: "test.edit.\(UUID().uuidString)")!))
        vm.startWorkout(restStore: RoutineRestPreferenceStore(), appDefaultRestSeconds: 90, runner: runner)
        vm.updatePrescription(at: 0, sets: 7)
        vm.saveAsRoutine()

        let saved = try context.fetch(FetchDescriptor<Routine>()).filter { $0.origin == .userSaved }
        let routine = try #require(saved.first)
        let steps = try context.fetch(FetchDescriptor<Step>()).filter { $0.routineId == routine.id }
        #expect(steps.first(where: { $0.order == 0 })?.sets == 7)
    }

    @Test
    func replacementIsIgnoredOnceSavedAndStepsStayPut() throws {
        let (vm, context) = try Self.viewModel()
        vm.saveAsRoutine()
        let before = try #require(vm.plan)
        let stepsBefore = try context.fetch(FetchDescriptor<Step>()).map { [$0.title, "\($0.sets)", "\($0.repsTarget)", "\($0.restSeconds)"] }

        vm.replaceExercise(at: 0, with: GeneratedExercise(
            machineId: "cable_machine", exerciseName: "ケーブルクロスオーバー",
            sets: 3, reps: 12, restSeconds: 60, cue: "", exerciseId: "cable_crossover"
        ))
        vm.regenerate()

        #expect(vm.plan == before)
        #expect(vm.isSaved)
        let stepsAfter = try context.fetch(FetchDescriptor<Step>()).map { [$0.title, "\($0.sets)", "\($0.repsTarget)", "\($0.restSeconds)"] }
        #expect(stepsAfter == stepsBefore)
        #expect(try context.fetch(FetchDescriptor<Routine>()).count == 1)
    }

    // MARK: - Live time warnings

    /// 4 chest machines, 90 minutes, 4 exercises: even at the fitted set cap
    /// the plan is short, so it starts with a "届きません" warning.
    private static func shortFixedCountViewModel() throws -> GeneratedPlanViewModel {
        let schema = Schema([Routine.self, Step.self, Gym.self, GymMachine.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let context = ModelContext(try ModelContainer(for: schema, configurations: [config]))
        let repo = GymRepository(modelContext: context)
        let gym = repo.createGym(name: "Test", makeActive: true)
        repo.setMachines(["bench_press", "chest_press", "pec_deck", "incline_chest_press"], for: gym)
        let vm = GeneratedPlanViewModel(
            gym: gym,
            request: QuickPlanRequest(bodyParts: [.chest], duration: .extended, intensity: .standard, exerciseCount: .fixed(4))
        )
        vm.configure(modelContext: context)
        return vm
    }

    private static func timeWarnings(_ vm: GeneratedPlanViewModel) -> [String] {
        vm.warnings.filter { $0.contains("収まりません") || $0.contains("届きません") }
    }

    @Test
    func shortfallWarningClearsOnceEditsReachTheRange() throws {
        let vm = try Self.shortFixedCountViewModel()
        let duration = QuickPlanDuration.extended
        try #require(vm.estimatedMinutes < duration.lowerBoundMinutes)
        let initial = Self.timeWarnings(vm)
        #expect(initial.count == 1)
        // The quoted minutes are the preview's own estimate.
        #expect(initial.first?.contains("届きません（推定\(vm.estimatedMinutes)分）") == true)

        for index in try #require(vm.plan).exercises.indices {
            vm.updatePrescription(at: index, sets: 10)
        }
        try #require((duration.lowerBoundMinutes...duration.upperBoundMinutes).contains(vm.estimatedMinutes))
        #expect(Self.timeWarnings(vm).isEmpty)
    }

    @Test
    func overshootAfterEditingQuotesTheCurrentEstimate() throws {
        let vm = try Self.shortFixedCountViewModel()
        for index in try #require(vm.plan).exercises.indices {
            vm.updatePrescription(at: index, sets: 10, restSeconds: 300)
        }
        try #require(vm.estimatedMinutes > QuickPlanDuration.extended.upperBoundMinutes)
        let timing = Self.timeWarnings(vm)
        #expect(timing == ["4種目では90分に収まりません（推定\(vm.estimatedMinutes)分）。種目数を減らすか時間を延ばしてください。"])
    }

    @Test
    func machineShortageWarningSurvivesEdits() throws {
        let schema = Schema([Routine.self, Step.self, Gym.self, GymMachine.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let context = ModelContext(try ModelContainer(for: schema, configurations: [config]))
        let repo = GymRepository(modelContext: context)
        let gym = repo.createGym(name: "Test", makeActive: true)
        repo.setMachines(["bench_press", "chest_press", "pec_deck"], for: gym)
        let vm = GeneratedPlanViewModel(
            gym: gym,
            request: QuickPlanRequest(bodyParts: [.chest], duration: .standardPlus, intensity: .standard, exerciseCount: .fixed(6))
        )
        vm.configure(modelContext: context)
        let shortage = { vm.warnings.filter { $0.contains("6種目ではなく3種目") } }
        #expect(shortage().count == 1)
        vm.updatePrescription(at: 0, sets: 8)
        #expect(shortage().count == 1)
        // Never shown twice.
        #expect(Set(vm.warnings).count == vm.warnings.count)
    }

    @Test
    func automaticCountGetsNoLiveTimeWarnings() throws {
        let (vm, _) = try Self.viewModel()
        vm.updatePrescription(at: 0, sets: 10, restSeconds: 300)
        #expect(Self.timeWarnings(vm).isEmpty)
        #expect(vm.warnings == (vm.plan?.warnings ?? []))
    }

    @Test
    func editsAreIgnoredOnceSaved() throws {
        let (vm, _) = try Self.viewModel()
        vm.saveAsRoutine()
        let before = try #require(vm.plan)
        vm.updatePrescription(at: 0, sets: 9)
        #expect(vm.plan == before)
    }
}
