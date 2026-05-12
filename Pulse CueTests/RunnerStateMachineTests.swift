//
//  RunnerStateMachineTests.swift
//  Pulse CueTests
//
//  Drives RunnerViewModel through its public action API and asserts on
//  the observable state machine.  No refactor of RunnerViewModel was
//  required: tests use an in-memory ModelContainer and an isolated
//  UserDefaults suite, and rely on Complete-during-rest /
//  Skip-during-rest to advance deterministically without waiting for
//  the rest timer to fire.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct RunnerStateMachineTests {

    // MARK: - Fixture

    private struct Fixture {
        let viewModel: RunnerViewModel
        let routine: Routine
        let context: ModelContext
        let defaults: UserDefaults
    }

    private static func makeFixture(
        restSeconds: Int = 0,
        stepCount: Int = 3,
        setsPerStep: Int = 2
    ) throws -> Fixture {
        // RunnerPersistence reads/writes UserDefaults.standard; make sure no
        // earlier test left state behind.
        RunnerPersistence.clear()

        let schema = Schema([
            Routine.self,
            Step.self,
            Session.self,
            StepResult.self,
            DayLog.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let routine = Routine(name: "Test Routine")
        context.insert(routine)
        for index in 0..<stepCount {
            let step = Step(
                routineId: routine.id,
                order: index,
                title: "Step \(index)",
                sets: setsPerStep,
                repsTarget: 10,
                restSeconds: restSeconds
            )
            context.insert(step)
        }
        try context.save()

        // Isolated UserDefaults so Settings flags don't leak across tests.
        let suiteName = "test.runner.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = SettingsStore(defaults: defaults)
        // Keep notifications off so scheduleRestNotification is a no-op.
        settings.notificationsEnabled = false

        let viewModel = RunnerViewModel(settings: settings)
        viewModel.configure(modelContext: context)

        return Fixture(viewModel: viewModel, routine: routine, context: context, defaults: defaults)
    }

    // MARK: - Tests

    @Test
    func startPutsRunnerIntoExerciseAtFirstStep() async throws {
        let fx = try Self.makeFixture(restSeconds: 60, stepCount: 2, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)

        #expect(fx.viewModel.phase == .exercise)
        #expect(fx.viewModel.currentStepIndex == 0)
        #expect(fx.viewModel.currentSetIndex == 0)
        #expect(fx.viewModel.isRunning)
        #expect(fx.viewModel.sessionId != nil)
    }

    @Test
    func completeFromExerciseEntersRest() async throws {
        let fx = try Self.makeFixture(restSeconds: 60, stepCount: 2, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)

        fx.viewModel.handle(action: .complete)

        #expect(fx.viewModel.phase == .rest)
        #expect(fx.viewModel.currentStepIndex == 0)
        #expect(fx.viewModel.currentSetIndex == 0)
        #expect(fx.viewModel.restDeadline != nil)
    }

    @Test
    func restCompletionAdvancesToNextSet() async throws {
        let fx = try Self.makeFixture(restSeconds: 60, stepCount: 1, setsPerStep: 3)
        fx.viewModel.start(routine: fx.routine)

        fx.viewModel.handle(action: .complete) // exercise → rest
        fx.viewModel.handle(action: .complete) // finish rest → next set

        #expect(fx.viewModel.phase == .exercise)
        #expect(fx.viewModel.currentStepIndex == 0)
        #expect(fx.viewModel.currentSetIndex == 1)
    }

    @Test
    func restCompletionAdvancesToNextStepAfterFinalSet() async throws {
        let fx = try Self.makeFixture(restSeconds: 60, stepCount: 2, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)

        // step 0 / set 0 → rest → set 1
        fx.viewModel.handle(action: .complete)
        fx.viewModel.handle(action: .complete)
        // step 0 / set 1 (last set of step 0) → rest → step 1 / set 0
        fx.viewModel.handle(action: .complete)
        fx.viewModel.handle(action: .complete)

        #expect(fx.viewModel.phase == .exercise)
        #expect(fx.viewModel.currentStepIndex == 1)
        #expect(fx.viewModel.currentSetIndex == 0)
    }

    @Test
    func lastSetOfLastStepFinishesSession() async throws {
        // 1 step × 1 set: Complete → rest → Complete (finish rest) → done
        let fx = try Self.makeFixture(restSeconds: 60, stepCount: 1, setsPerStep: 1)
        fx.viewModel.start(routine: fx.routine)

        fx.viewModel.handle(action: .complete) // exercise → rest
        #expect(fx.viewModel.phase == .rest)

        fx.viewModel.handle(action: .complete) // finish rest → done

        #expect(fx.viewModel.phase == .done)
        #expect(fx.viewModel.sessionId == nil)
        #expect(!fx.viewModel.isRunning)
    }

    @Test
    func skipFromExerciseSkipsCurrentStepEvenWithRemainingSets() async throws {
        let fx = try Self.makeFixture(restSeconds: 0, stepCount: 3, setsPerStep: 5)
        fx.viewModel.start(routine: fx.routine)

        fx.viewModel.handle(action: .skip)

        #expect(fx.viewModel.phase == .exercise)
        #expect(fx.viewModel.currentStepIndex == 1)
        #expect(fx.viewModel.currentSetIndex == 0)
    }

    @Test
    func skipDuringRestSkipsToNextStep() async throws {
        let fx = try Self.makeFixture(restSeconds: 60, stepCount: 2, setsPerStep: 4)
        fx.viewModel.start(routine: fx.routine)

        fx.viewModel.handle(action: .complete) // step 0 / set 0 → rest
        #expect(fx.viewModel.phase == .rest)

        fx.viewModel.handle(action: .skip)

        #expect(fx.viewModel.phase == .exercise)
        #expect(fx.viewModel.currentStepIndex == 1)
        #expect(fx.viewModel.currentSetIndex == 0)
        #expect(fx.viewModel.restDeadline == nil)
    }

    @Test
    func backMovesToPreviousSetWithinSameStep() async throws {
        let fx = try Self.makeFixture(restSeconds: 0, stepCount: 1, setsPerStep: 3)
        fx.viewModel.start(routine: fx.routine)

        // restSeconds=0 → Complete short-circuits past rest and moves to next set.
        fx.viewModel.handle(action: .complete)
        #expect(fx.viewModel.currentSetIndex == 1)

        fx.viewModel.handle(action: .back)

        #expect(fx.viewModel.phase == .exercise)
        #expect(fx.viewModel.currentStepIndex == 0)
        #expect(fx.viewModel.currentSetIndex == 0)
    }

    @Test
    func backCrossesStepBoundary() async throws {
        let fx = try Self.makeFixture(restSeconds: 0, stepCount: 2, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)

        // step 0 / set 0 → set 1 → step 1 / set 0
        fx.viewModel.handle(action: .complete)
        fx.viewModel.handle(action: .complete)
        #expect(fx.viewModel.currentStepIndex == 1)
        #expect(fx.viewModel.currentSetIndex == 0)

        fx.viewModel.handle(action: .back)

        // Should land on the last set of the previous step.
        #expect(fx.viewModel.currentStepIndex == 0)
        #expect(fx.viewModel.currentSetIndex == 1)
    }

    @Test
    func plus10HasNoEffectDuringExercise() async throws {
        let fx = try Self.makeFixture(restSeconds: 60, stepCount: 1, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)
        let deadlineBefore = fx.viewModel.restDeadline

        fx.viewModel.handle(action: .extend)

        #expect(fx.viewModel.restDeadline == deadlineBefore) // both nil
        #expect(fx.viewModel.phase == .exercise)
    }

    @Test
    func plus10ExtendsDeadlineDuringRest() async throws {
        let fx = try Self.makeFixture(restSeconds: 60, stepCount: 1, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.handle(action: .complete) // → rest

        let before = try #require(fx.viewModel.restDeadline)
        fx.viewModel.handle(action: .extend)
        let after = try #require(fx.viewModel.restDeadline)

        let delta = after.timeIntervalSince(before)
        #expect(abs(delta - 10.0) < 0.05)
        #expect(fx.viewModel.phase == .rest)
    }

    @Test
    func recoveryRestoresInProgressSession() async throws {
        // Build fixture and run it forward by one set, then drop the VM.
        let fx = try Self.makeFixture(restSeconds: 0, stepCount: 2, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.handle(action: .complete) // step 0 set 0 → set 1 (rest=0)
        #expect(fx.viewModel.currentSetIndex == 1)

        let savedSessionId = try #require(fx.viewModel.sessionId)

        // Simulate the app being backgrounded (saves persistent state).
        fx.viewModel.appDidEnterBackground()

        // Build a fresh VM against the same context + same UserDefaults.
        let settings = SettingsStore(defaults: fx.defaults)
        let recovered = RunnerViewModel(settings: settings)
        recovered.configure(modelContext: fx.context)

        #expect(recovered.sessionId == savedSessionId)
        #expect(recovered.currentStepIndex == 0)
        #expect(recovered.currentSetIndex == 1)
        #expect(recovered.phase == .exercise)
        #expect(recovered.isRunning)
    }

    @Test
    func recoveryClearsWhenSessionIsNoLongerInProgress() async throws {
        // Run the routine to completion, then verify a fresh VM starts idle.
        let fx = try Self.makeFixture(restSeconds: 0, stepCount: 1, setsPerStep: 1)
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.handle(action: .complete) // 1×1 with rest=0 → done

        #expect(fx.viewModel.phase == .done)

        let recovered = RunnerViewModel(settings: SettingsStore(defaults: fx.defaults))
        recovered.configure(modelContext: fx.context)

        #expect(recovered.phase == .done)
        #expect(recovered.sessionId == nil)
        #expect(!recovered.isRunning)
    }
}
