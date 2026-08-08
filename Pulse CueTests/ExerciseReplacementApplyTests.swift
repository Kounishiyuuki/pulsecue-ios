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
