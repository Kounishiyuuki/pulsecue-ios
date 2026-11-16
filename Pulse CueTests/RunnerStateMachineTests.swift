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

    private static func complete(_ viewModel: RunnerViewModel) throws {
        let context = try #require(viewModel.completeContext)
        viewModel.handle(action: .complete, context: context)
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

        try Self.complete(fx.viewModel)

        #expect(fx.viewModel.phase == .rest)
        #expect(fx.viewModel.currentStepIndex == 0)
        #expect(fx.viewModel.currentSetIndex == 0)
        #expect(fx.viewModel.restDeadline != nil)
    }

    @Test
    func contextFreeCompleteIsIgnored() async throws {
        let fx = try Self.makeFixture(restSeconds: 60, stepCount: 1, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)

        fx.viewModel.handle(action: .complete)

        #expect(try fx.context.fetch(FetchDescriptor<StepResult>()).isEmpty)
        #expect(fx.viewModel.phase == .exercise)
        #expect(fx.viewModel.currentStepIndex == 0)
        #expect(fx.viewModel.currentSetIndex == 0)
        #expect(fx.viewModel.restDeadline == nil)
    }

    @Test
    func synchronousDoubleCompleteForSameContextIsIdempotent() async throws {
        let fx = try Self.makeFixture(restSeconds: 60, stepCount: 1, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.adjustCurrentReps(by: -2)
        let context = try #require(fx.viewModel.completeContext)

        fx.viewModel.handle(action: .complete, context: context)
        let firstDeadline = try #require(fx.viewModel.restDeadline)
        let firstReps = fx.viewModel.currentReps
        let firstStepIndex = fx.viewModel.currentStepIndex
        let firstSetIndex = fx.viewModel.currentSetIndex
        let firstResults = try fx.context.fetch(FetchDescriptor<StepResult>())
        #expect(firstResults.count == 1)

        fx.viewModel.handle(action: .complete, context: context)
        let secondResults = try fx.context.fetch(FetchDescriptor<StepResult>())

        #expect(secondResults.count == 1)
        #expect(secondResults.first?.id == firstResults.first?.id)
        #expect(secondResults.first?.actualReps == 8)
        #expect(fx.viewModel.phase == .rest)
        #expect(fx.viewModel.currentStepIndex == firstStepIndex)
        #expect(fx.viewModel.currentSetIndex == firstSetIndex)
        #expect(fx.viewModel.currentReps == firstReps)
        #expect(fx.viewModel.restDeadline == firstDeadline)
    }

    @Test
    func nearConcurrentDoubleCompleteForSameContextIsIdempotent() async throws {
        let fx = try Self.makeFixture(restSeconds: 60, stepCount: 1, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)
        let context = try #require(fx.viewModel.completeContext)

        let first = Task { @MainActor in
            fx.viewModel.handle(action: .complete, context: context)
        }
        let second = Task { @MainActor in
            fx.viewModel.handle(action: .complete, context: context)
        }
        await first.value
        await second.value

        let deadline = try #require(fx.viewModel.restDeadline)
        let results = try fx.context.fetch(FetchDescriptor<StepResult>())
        #expect(results.count == 1)
        #expect(results.first?.actualReps == 10)
        #expect(fx.viewModel.phase == .rest)
        #expect(fx.viewModel.currentStepIndex == 0)
        #expect(fx.viewModel.currentSetIndex == 0)
        #expect(fx.viewModel.currentReps == 10)

        fx.viewModel.handle(action: .complete, context: context)
        #expect(try fx.context.fetch(FetchDescriptor<StepResult>()).count == 1)
        #expect(fx.viewModel.phase == .rest)
        #expect(fx.viewModel.currentStepIndex == 0)
        #expect(fx.viewModel.currentSetIndex == 0)
        #expect(fx.viewModel.currentReps == 10)
        #expect(fx.viewModel.restDeadline == deadline)
    }

    @Test
    func zeroRestSynchronousDoubleCompleteDoesNotCompleteTheNextSet() async throws {
        let fx = try Self.makeFixture(restSeconds: 0, stepCount: 1, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)
        let context = try #require(fx.viewModel.completeContext)

        fx.viewModel.handle(action: .complete, context: context)
        fx.viewModel.handle(action: .complete, context: context)

        let results = try fx.context.fetch(FetchDescriptor<StepResult>())
        #expect(results.count == 1)
        #expect(results.first?.setIndex == 0)
        #expect(fx.viewModel.phase == .exercise)
        #expect(fx.viewModel.currentStepIndex == 0)
        #expect(fx.viewModel.currentSetIndex == 1)
    }

    @Test
    func zeroRestNearConcurrentDoubleCompleteDoesNotCompleteTheNextSet() async throws {
        let fx = try Self.makeFixture(restSeconds: 0, stepCount: 1, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)
        let context = try #require(fx.viewModel.completeContext)

        let first = Task { @MainActor in
            fx.viewModel.handle(action: .complete, context: context)
        }
        let second = Task { @MainActor in
            fx.viewModel.handle(action: .complete, context: context)
        }
        await first.value
        await second.value

        let results = try fx.context.fetch(FetchDescriptor<StepResult>())
        #expect(results.count == 1)
        #expect(results.first?.setIndex == 0)
        #expect(fx.viewModel.phase == .exercise)
        #expect(fx.viewModel.currentStepIndex == 0)
        #expect(fx.viewModel.currentSetIndex == 1)
    }

    @Test
    func skipThenBackRejectsTheStaleCompleteContext() async throws {
        let fx = try Self.makeFixture(restSeconds: 60, stepCount: 2, setsPerStep: 1)
        fx.viewModel.start(routine: fx.routine)
        let staleContext = try #require(fx.viewModel.completeContext)

        fx.viewModel.handle(action: .skip)
        fx.viewModel.handle(action: .back)
        let resultsBeforeStaleComplete = try fx.context.fetch(FetchDescriptor<StepResult>())
        let skippedResult = try #require(resultsBeforeStaleComplete.first)
        #expect(resultsBeforeStaleComplete.count == 1)
        #expect(skippedResult.done == false)
        #expect(skippedResult.actualReps == nil)

        fx.viewModel.handle(action: .complete, context: staleContext)

        let resultsAfterStaleComplete = try fx.context.fetch(FetchDescriptor<StepResult>())
        #expect(resultsAfterStaleComplete.count == 1)
        #expect(resultsAfterStaleComplete.first?.id == skippedResult.id)
        #expect(resultsAfterStaleComplete.first?.done == false)
        #expect(resultsAfterStaleComplete.first?.actualReps == nil)
        #expect(fx.viewModel.phase == .exercise)
        #expect(fx.viewModel.currentStepIndex == 0)
        #expect(fx.viewModel.currentSetIndex == 0)

        try Self.complete(fx.viewModel)
        #expect(try fx.context.fetch(FetchDescriptor<StepResult>()).count == 1)
        #expect(fx.viewModel.phase == .rest)
    }

    @Test
    func adjustedRepsAreRecordedWhenSetCompletes() async throws {
        let fx = try Self.makeFixture(restSeconds: 60, stepCount: 1, setsPerStep: 1)
        fx.viewModel.start(routine: fx.routine)

        fx.viewModel.adjustCurrentReps(by: -2)
        fx.viewModel.adjustCurrentReps(by: 1)
        #expect(fx.viewModel.currentReps == 9)

        try Self.complete(fx.viewModel)

        let results = try fx.context.fetch(FetchDescriptor<StepResult>())
        #expect(results.count == 1)
        #expect(results.first?.done == true)
        #expect(results.first?.actualReps == 9)
    }

    @Test
    func completingAgainAfterBackUpdatesTheSameSetResult() async throws {
        let fx = try Self.makeFixture(restSeconds: 60, stepCount: 1, setsPerStep: 1)
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.adjustCurrentReps(by: -2)
        try Self.complete(fx.viewModel)

        fx.viewModel.handle(action: .back)
        fx.viewModel.adjustCurrentReps(by: 3)
        try Self.complete(fx.viewModel)

        let results = try fx.context.fetch(FetchDescriptor<StepResult>())
        #expect(results.count == 1)
        #expect(results.first?.done == true)
        #expect(results.first?.actualReps == 11)
    }

    @Test
    func repsAdjustmentStopsAtZeroAndResetsForNextSet() async throws {
        let fx = try Self.makeFixture(restSeconds: 0, stepCount: 1, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)

        fx.viewModel.adjustCurrentReps(by: -20)
        #expect(fx.viewModel.currentReps == 0)
        try Self.complete(fx.viewModel)

        #expect(fx.viewModel.phase == .exercise)
        #expect(fx.viewModel.currentSetIndex == 1)
        #expect(fx.viewModel.currentReps == 10)
    }

    @Test
    func restCompletionAdvancesToNextSet() async throws {
        let fx = try Self.makeFixture(restSeconds: 60, stepCount: 1, setsPerStep: 3)
        fx.viewModel.start(routine: fx.routine)

        try Self.complete(fx.viewModel) // exercise → rest
        try Self.complete(fx.viewModel) // finish rest → next set

        #expect(fx.viewModel.phase == .exercise)
        #expect(fx.viewModel.currentStepIndex == 0)
        #expect(fx.viewModel.currentSetIndex == 1)
    }

    @Test
    func restCompletionAdvancesToNextStepAfterFinalSet() async throws {
        let fx = try Self.makeFixture(restSeconds: 60, stepCount: 2, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)

        // step 0 / set 0 → rest → set 1
        try Self.complete(fx.viewModel)
        try Self.complete(fx.viewModel)
        // step 0 / set 1 (last set of step 0) → rest → step 1 / set 0
        try Self.complete(fx.viewModel)
        try Self.complete(fx.viewModel)

        #expect(fx.viewModel.phase == .exercise)
        #expect(fx.viewModel.currentStepIndex == 1)
        #expect(fx.viewModel.currentSetIndex == 0)
    }

    @Test
    func lastSetOfLastStepFinishesSession() async throws {
        // 1 step × 1 set: Complete → rest → Complete (finish rest) → done
        let fx = try Self.makeFixture(restSeconds: 60, stepCount: 1, setsPerStep: 1)
        fx.viewModel.start(routine: fx.routine)

        try Self.complete(fx.viewModel) // exercise → rest
        #expect(fx.viewModel.phase == .rest)

        try Self.complete(fx.viewModel) // finish rest → done

        #expect(fx.viewModel.phase == .done)
        #expect(fx.viewModel.sessionId == nil)
        #expect(!fx.viewModel.isRunning)
    }

    @Test
    func nilExerciseIdStepCompletesAndRemainsQueryableInHistoryData() async throws {
        let fx = try Self.makeFixture(restSeconds: 0, stepCount: 1, setsPerStep: 1)
        let step = try #require(try fx.context.fetch(FetchDescriptor<Step>()).first)
        #expect(step.exerciseId == nil)

        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)

        #expect(fx.viewModel.phase == .done)
        let sessions = try fx.context.fetch(FetchDescriptor<Session>())
        let results = try fx.context.fetch(FetchDescriptor<StepResult>())
        #expect(sessions.count == 1)
        #expect(sessions.first?.routineId == fx.routine.id)
        #expect(sessions.first?.status == .completed)
        #expect(results.count == 1)
        #expect(results.first?.stepId == step.id)
        #expect(results.first?.done == true)
        #expect(step.title == "Step 0")
        #expect(step.exerciseId == nil)
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

        try Self.complete(fx.viewModel) // step 0 / set 0 → rest
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
        try Self.complete(fx.viewModel)
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
        try Self.complete(fx.viewModel)
        try Self.complete(fx.viewModel)
        #expect(fx.viewModel.currentStepIndex == 1)
        #expect(fx.viewModel.currentSetIndex == 0)

        fx.viewModel.handle(action: .back)

        // Should land on the last set of the previous step.
        #expect(fx.viewModel.currentStepIndex == 0)
        #expect(fx.viewModel.currentSetIndex == 1)
    }

    @Test
    func backAtFirstSetIsANoOpAndKeepsAdjustedReps() async throws {
        let fx = try Self.makeFixture(restSeconds: 0, stepCount: 1, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.adjustCurrentReps(by: -3)
        let contextBeforeBack = try #require(fx.viewModel.completeContext)

        fx.viewModel.handle(action: .back)

        #expect(fx.viewModel.phase == .exercise)
        #expect(fx.viewModel.currentStepIndex == 0)
        #expect(fx.viewModel.currentSetIndex == 0)
        #expect(fx.viewModel.currentReps == 7)
        #expect(fx.viewModel.completeContext == contextBeforeBack)

        fx.viewModel.handle(action: .complete, context: contextBeforeBack)
        #expect(fx.viewModel.currentSetIndex == 1)
    }

    @Test
    func backToPreviousSetRestoresItsRecordedActualReps() async throws {
        let fx = try Self.makeFixture(restSeconds: 0, stepCount: 1, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.adjustCurrentReps(by: -3)
        try Self.complete(fx.viewModel)
        #expect(fx.viewModel.currentSetIndex == 1)
        #expect(fx.viewModel.currentReps == 10)

        fx.viewModel.handle(action: .back)

        #expect(fx.viewModel.currentStepIndex == 0)
        #expect(fx.viewModel.currentSetIndex == 0)
        #expect(fx.viewModel.currentReps == 7)
    }

    @Test
    func backAcrossExerciseBoundaryRestoresPreviousExercisesLastRecordedReps() async throws {
        let fx = try Self.makeFixture(restSeconds: 0, stepCount: 2, setsPerStep: 1)
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.adjustCurrentReps(by: -4)
        try Self.complete(fx.viewModel)
        #expect(fx.viewModel.currentStepIndex == 1)
        #expect(fx.viewModel.currentSetIndex == 0)

        fx.viewModel.handle(action: .back)

        #expect(fx.viewModel.currentStepIndex == 0)
        #expect(fx.viewModel.currentSetIndex == 0)
        #expect(fx.viewModel.currentReps == 6)
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
        try Self.complete(fx.viewModel) // → rest

        let before = try #require(fx.viewModel.restDeadline)
        fx.viewModel.handle(action: .extend)
        let after = try #require(fx.viewModel.restDeadline)

        let delta = after.timeIntervalSince(before)
        #expect(abs(delta - 10.0) < 0.05)
        #expect(fx.viewModel.phase == .rest)
    }

    @Test
    func minus10ShortensDeadlineWithoutGoingNegative() async throws {
        let fx = try Self.makeFixture(restSeconds: 60, stepCount: 1, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)

        let before = try #require(fx.viewModel.restDeadline)
        fx.viewModel.shortenRest()
        let after = try #require(fx.viewModel.restDeadline)

        #expect(abs(after.timeIntervalSince(before) + 10.0) < 0.1)
        #expect(fx.viewModel.phase == .rest)
        #expect(fx.viewModel.remainingSeconds >= 0)
    }

    @Test
    func minus10AtEndOfShortRestUsesNormalCompletionTransition() async throws {
        let fx = try Self.makeFixture(restSeconds: 5, stepCount: 1, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)

        fx.viewModel.shortenRest()

        #expect(fx.viewModel.phase == .exercise)
        #expect(fx.viewModel.currentSetIndex == 1)
        #expect(fx.viewModel.restDeadline == nil)
        #expect(fx.viewModel.remainingSeconds == 0)
    }

    @Test
    func recoveryRestoresInProgressSession() async throws {
        // Build fixture and run it forward by one set, then drop the VM.
        let fx = try Self.makeFixture(restSeconds: 0, stepCount: 2, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel) // step 0 set 0 → set 1 (rest=0)
        #expect(fx.viewModel.currentSetIndex == 1)
        fx.viewModel.adjustCurrentReps(by: -3)
        #expect(fx.viewModel.currentReps == 7)

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
        #expect(recovered.currentReps == 7)
        #expect(recovered.phase == .exercise)
        #expect(recovered.isRunning)
    }

    @Test
    func recoveryClearsWhenSessionIsNoLongerInProgress() async throws {
        // Run the routine to completion, then verify a fresh VM starts idle.
        let fx = try Self.makeFixture(restSeconds: 0, stepCount: 1, setsPerStep: 1)
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel) // 1×1 with rest=0 → done

        #expect(fx.viewModel.phase == .done)

        let recovered = RunnerViewModel(settings: SettingsStore(defaults: fx.defaults))
        recovered.configure(modelContext: fx.context)

        #expect(recovered.phase == .done)
        #expect(recovered.sessionId == nil)
        #expect(!recovered.isRunning)
    }

    // MARK: - Cancellation
    //
    //  `endSessionEarly` had no coverage at all: stubbing it out left every
    //  Runner test green. It is the one path that ends a workout the user did
    //  not finish, and what it must *not* do is as important as what it does —
    //  a cancelled session that stayed `.inProgress` would be restored on the
    //  next launch, putting the user back into a workout they walked away from.

    @Test
    func cancellingEndsTheRunAndStopsTheWorkout() async throws {
        let fx = try Self.makeFixture(restSeconds: 60, stepCount: 2, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)
        #expect(fx.viewModel.isRunning)

        fx.viewModel.endSessionEarly()

        #expect(fx.viewModel.isRunning == false)
        #expect(fx.viewModel.restDeadline == nil)
    }

    @Test
    func cancellingRecordsTheSessionAsAbandoned() async throws {
        // It is saved as an interruption, not deleted: the alert says
        // 「このセッションは中断として保存されます」 and History is where that
        // promise is kept. The status is named exactly, because "not
        // completed" would also be satisfied by leaving it `.inProgress` —
        // which is the failure that puts the user back into an abandoned
        // workout on the next launch.
        let fx = try Self.makeFixture(restSeconds: 60, stepCount: 2, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)

        fx.viewModel.endSessionEarly()

        let sessions = try fx.context.fetch(FetchDescriptor<Session>())
        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session.status == .abandoned)
    }

    @Test
    func cancellingClosesTheSessionsTimeRange() async throws {
        // `endedAt` is what makes the row finished rather than open, and
        // `totalSeconds` is derived from it. Asserted as the relationship
        // rather than a literal: the elapsed value depends on how long the
        // test took, but that it equals the range it came from does not.
        let fx = try Self.makeFixture(restSeconds: 60, stepCount: 2, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)

        fx.viewModel.endSessionEarly()

        let session = try #require(try fx.context.fetch(FetchDescriptor<Session>()).first)
        let endedAt = try #require(session.endedAt)
        #expect(endedAt >= session.startedAt)
        #expect(session.totalSeconds == Int(endedAt.timeIntervalSince(session.startedAt)))
        #expect(session.totalSeconds >= 0)
    }

    @Test
    func aCancelledSessionIsNotRestoredOnRelaunch() async throws {
        let fx = try Self.makeFixture(restSeconds: 60, stepCount: 2, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.endSessionEarly()

        // A fresh view model over the same store is what a relaunch looks like.
        let fresh = RunnerViewModel(settings: SettingsStore())
        fresh.configure(modelContext: fx.context)

        #expect(fresh.isRunning == false)
    }

    @Test
    func cancellingDoesNotShowTheCompletionSummary() async throws {
        // The completion screen celebrates a finished workout. Showing it for
        // one the user abandoned would be both wrong and slightly insulting.
        let fx = try Self.makeFixture(restSeconds: 60, stepCount: 2, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)

        fx.viewModel.endSessionEarly()

        #expect(fx.viewModel.completion == nil)
        #expect(fx.viewModel.shouldPresentRunner == false)
    }

    @Test
    func cancellingTwiceCreatesNoSecondSession() async throws {
        let fx = try Self.makeFixture(restSeconds: 60, stepCount: 2, setsPerStep: 2)
        fx.viewModel.start(routine: fx.routine)

        fx.viewModel.endSessionEarly()
        fx.viewModel.endSessionEarly()

        #expect(try fx.context.fetch(FetchDescriptor<Session>()).count == 1)
    }
}

// MARK: - Per-set weight

@MainActor
struct RunnerSetWeightTests {

    private struct Fixture {
        let viewModel: RunnerViewModel
        let routine: Routine
        let steps: [Step]
        let context: ModelContext
    }

    private static func makeFixture(exerciseIds: [String?] = ["bench_press", "bench_press"], sets: Int = 2) throws -> Fixture {
        RunnerPersistence.clear()
        let schema = Schema([Routine.self, Step.self, Session.self, StepResult.self, DayLog.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let routine = Routine(name: "Weights")
        context.insert(routine)
        var steps: [Step] = []
        for (index, id) in exerciseIds.enumerated() {
            let step = Step(routineId: routine.id, order: index, title: "Step \(index)", sets: sets, repsTarget: 10, restSeconds: 0, exerciseId: id)
            context.insert(step)
            steps.append(step)
        }
        try context.save()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.weight.\(UUID().uuidString)")!)
        settings.notificationsEnabled = false
        let viewModel = RunnerViewModel(settings: settings)
        viewModel.configure(modelContext: context)
        return Fixture(viewModel: viewModel, routine: routine, steps: steps, context: context)
    }

    private static func complete(_ vm: RunnerViewModel) throws {
        vm.handle(action: .complete, context: try #require(vm.completeContext))
    }

    private static func results(_ fx: Fixture) throws -> [StepResult] {
        let order = Dictionary(uniqueKeysWithValues: fx.steps.enumerated().map { ($1.id, $0) })
        return try fx.context.fetch(FetchDescriptor<StepResult>()).sorted {
            let l = order[$0.stepId] ?? 0, r = order[$1.stepId] ?? 0
            return l != r ? l < r : $0.setIndex < $1.setIndex
        }
    }

    @Test
    func completeRecordsRepsAndWeightOnTheSameResult() throws {
        let fx = try Self.makeFixture()
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.setCurrentWeight(60)
        try Self.complete(fx.viewModel)
        let r = try #require(try Self.results(fx).first)
        #expect(r.done)
        #expect(r.actualReps == 10)
        #expect(r.weightKg == 60)
    }

    @Test
    func decimalWeightIsStoredExactly() throws {
        let fx = try Self.makeFixture()
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.setCurrentWeight(62.5)
        try Self.complete(fx.viewModel)
        #expect(try Self.results(fx).first?.weightKg == 62.5)
    }

    @Test
    func blankWeightStaysNilNotZero() throws {
        let fx = try Self.makeFixture()
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)
        #expect(try Self.results(fx).first?.weightKg == nil)
    }

    @Test
    func invalidWeightsAreRejected() throws {
        let fx = try Self.makeFixture()
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.setCurrentWeight(50)
        for bad in [-1, .nan, .infinity, SetWeight.maximumKg + 1] {
            fx.viewModel.setCurrentWeight(bad)
            #expect(fx.viewModel.currentWeightKg == 50)
        }
        fx.viewModel.setCurrentWeight(0)
        #expect(fx.viewModel.currentWeightKg == 0)
        fx.viewModel.adjustCurrentWeight(by: -2.5)
        #expect(fx.viewModel.currentWeightKg == 0)
    }

    @Test
    func skipLeavesNoWeight() throws {
        let fx = try Self.makeFixture()
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.setCurrentWeight(60)
        fx.viewModel.handle(action: .skip)
        let r = try #require(try Self.results(fx).first)
        #expect(!r.done)
        #expect(r.actualReps == nil)
        #expect(r.weightKg == nil)
    }

    @Test
    func nextSetStartsFromPreviousWeightAndCanChange() throws {
        let fx = try Self.makeFixture()
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.setCurrentWeight(60)
        try Self.complete(fx.viewModel)
        #expect(fx.viewModel.currentSetIndex == 1)
        #expect(fx.viewModel.currentWeightKg == 60)
        // Not recorded for set 2 until it is completed.
        #expect(try Self.results(fx).count == 1)
        fx.viewModel.adjustCurrentWeight(by: 2.5)
        try Self.complete(fx.viewModel)
        let rs = try Self.results(fx)
        #expect(rs.map(\.weightKg) == [60, 62.5])
        #expect(rs.map(\.actualReps) == [10, 10])
    }

    @Test
    func newExerciseStartsWithoutWeight() throws {
        let fx = try Self.makeFixture(sets: 1)
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.setCurrentWeight(80)
        try Self.complete(fx.viewModel)
        #expect(fx.viewModel.currentStepIndex == 1)
        #expect(fx.viewModel.currentWeightKg == nil)
    }

    @Test
    func backRestoresTheRecordedWeightAndRecompleteOverwrites() throws {
        let fx = try Self.makeFixture()
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.setCurrentWeight(60)
        try Self.complete(fx.viewModel)
        fx.viewModel.setCurrentWeight(70)
        fx.viewModel.handle(action: .back)
        #expect(fx.viewModel.currentSetIndex == 0)
        #expect(fx.viewModel.currentWeightKg == 60)
        fx.viewModel.setCurrentWeight(57.5)
        try Self.complete(fx.viewModel)
        let rs = try Self.results(fx)
        #expect(rs.count == 1)
        #expect(rs.first?.weightKg == 57.5)
        #expect(fx.viewModel.currentWeightKg == 57.5)
    }

    @Test
    func resumeRestoresTheUncommittedWeight() throws {
        let fx = try Self.makeFixture()
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.setCurrentWeight(60)
        try Self.complete(fx.viewModel)
        fx.viewModel.adjustCurrentWeight(by: 2.5)

        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.weight.\(UUID().uuidString)")!)
        settings.notificationsEnabled = false
        let resumed = RunnerViewModel(settings: settings)
        resumed.configure(modelContext: fx.context)
        #expect(resumed.currentSetIndex == 1)
        #expect(resumed.currentWeightKg == 62.5)
        try Self.complete(resumed)
        #expect(try Self.results(fx).map(\.weightKg) == [60, 62.5])
        RunnerPersistence.clear()
    }

    @Test
    func legacyPersistedStateDecodesWithoutWeight() throws {
        let json = #"{"sessionId":"\#(UUID().uuidString)","routineId":"\#(UUID().uuidString)","phase":"exercise","stepIndex":0,"setIndex":0,"currentReps":8,"lastUpdatedAt":0}"#
        let state = try JSONDecoder().decode(RunnerPersistentState.self, from: Data(json.utf8))
        #expect(state.currentWeightKg == nil)
        #expect(state.currentReps == 8)
    }

    @Test
    func timedOrCardioExerciseHidesWeightAndRecordsNone() throws {
        let fx = try Self.makeFixture(exerciseIds: ["treadmill_warmup", nil], sets: 1)
        fx.viewModel.start(routine: fx.routine)
        #expect(!fx.viewModel.currentStepAcceptsWeight)
        fx.viewModel.setCurrentWeight(20)
        #expect(fx.viewModel.currentWeightKg == nil)
        try Self.complete(fx.viewModel)
        #expect(try Self.results(fx).first?.weightKg == nil)
        // Custom / unresolved exercise accepts a weight.
        #expect(fx.viewModel.currentStepAcceptsWeight)
    }

    @Test
    func previousPerformanceStillWorksAndCarriesWeights() throws {
        let fx = try Self.makeFixture(exerciseIds: ["bench_press"], sets: 2)
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.setCurrentWeight(60)
        try Self.complete(fx.viewModel)
        fx.viewModel.adjustCurrentWeight(by: 2.5)
        try Self.complete(fx.viewModel)
        try fx.context.save()

        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.refreshExerciseInsight()
        let previous = try #require(fx.viewModel.previousPerformance)
        #expect(previous.setReps == [10, 10])
        #expect(previous.setWeightsKg == [60, 62.5])
        #expect(fx.viewModel.progression != nil)
    }
}

/// Weighted "目安を適用": transient only, recorded on Complete, re-derived after
/// a replacement, and never mixing another account's history.
@MainActor
struct RunnerWeightedProgressionTests {

    private struct Fixture {
        let viewModel: RunnerViewModel
        let routine: Routine
        let step: Step
        let context: ModelContext
    }

    private static func makeFixture(scope: WorkoutDataScope = .guest) throws -> Fixture {
        RunnerPersistence.clear()
        let schema = Schema([Routine.self, Step.self, Session.self, StepResult.self, DayLog.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let routine = Routine(name: "Progression")
        context.insert(routine)
        let step = Step(routineId: routine.id, order: 0, title: "ベンチプレス", sets: 3, repsTarget: 10, restSeconds: 0, exerciseId: "bench_press")
        context.insert(step)
        try context.save()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.wprog.\(UUID().uuidString)")!)
        settings.notificationsEnabled = false
        let viewModel = RunnerViewModel(settings: settings)
        viewModel.configure(modelContext: context, scope: scope)
        return Fixture(viewModel: viewModel, routine: routine, step: step, context: context)
    }

    /// One past completed session of `stepId` with the given sets.
    private static func seedHistory(_ fx: Fixture, stepId: UUID, weights: [Double?], reps: [Int] = [10, 10, 10], owner: UUID? = nil) throws {
        let past = Session(routineId: fx.routine.id, dayDate: .now, startedAt: Date().addingTimeInterval(-86_400), status: .completed)
        past.ownerAccountID = owner
        fx.context.insert(past)
        for (index, (r, w)) in zip(reps, weights).enumerated() {
            fx.context.insert(StepResult(sessionId: past.id, stepId: stepId, setIndex: index, done: true, actualReps: r, ownerAccountID: owner, weightKg: w))
        }
        try fx.context.save()
    }

    private static func resultCount(_ fx: Fixture) throws -> Int {
        try fx.context.fetch(FetchDescriptor<StepResult>()).count
    }

    @Test
    func applyingAWeightSuggestionSetsWeightAndRepsOnly() throws {
        let fx = try Self.makeFixture()
        try Self.seedHistory(fx, stepId: fx.step.id, weights: [60, 60, 60])
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.refreshExerciseInsight()
        let before = try Self.resultCount(fx)
        // Shown, not applied: the set starts with no weight.
        #expect(fx.viewModel.progression?.kind == .increaseWeight)
        #expect(fx.viewModel.currentWeightKg == nil)

        fx.viewModel.applyProgressionSuggestion()
        #expect(fx.viewModel.currentWeightKg == 62.5)
        #expect(fx.viewModel.currentReps == 10)
        #expect(try Self.resultCount(fx) == before)
        #expect(fx.step.repsTarget == 10)
        #expect(fx.step.sets == 3)

        fx.viewModel.handle(action: .complete, context: try #require(fx.viewModel.completeContext))
        let sessionId = try #require(fx.viewModel.sessionId)
        let recorded = try fx.context.fetch(FetchDescriptor<StepResult>()).filter { $0.sessionId == sessionId }
        #expect(recorded.count == 1)
        #expect(recorded.first?.weightKg == 62.5)
        #expect(recorded.first?.actualReps == 10)
        RunnerPersistence.clear()
    }

    @Test
    func userCanEnterAnyWeightWithoutApplying() throws {
        let fx = try Self.makeFixture()
        try Self.seedHistory(fx, stepId: fx.step.id, weights: [60, 60, 60])
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.refreshExerciseInsight()
        fx.viewModel.setCurrentWeight(55)
        fx.viewModel.handle(action: .complete, context: try #require(fx.viewModel.completeContext))
        let sessionId = try #require(fx.viewModel.sessionId)
        let recorded = try fx.context.fetch(FetchDescriptor<StepResult>()).filter { $0.sessionId == sessionId }
        #expect(recorded.first?.weightKg == 55)
        RunnerPersistence.clear()
    }

    @Test
    func replacementRecomputesFromTheNewExercise() throws {
        let fx = try Self.makeFixture()
        try Self.seedHistory(fx, stepId: fx.step.id, weights: [60, 60, 60])
        // History for the replacement target lives on another routine's step.
        let other = Step(routineId: UUID(), order: 0, title: "チェストプレス", sets: 3, repsTarget: 10, restSeconds: 0, exerciseId: "machine_chest_press")
        fx.context.insert(other)
        try Self.seedHistory(fx, stepId: other.id, weights: [40, 40, 40])
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.refreshExerciseInsight()
        #expect(fx.viewModel.progression?.suggestedWeightKg == 62.5)

        let candidate = GeneratedExercise(machineId: "chest_press", exerciseName: "チェストプレス", sets: 3, reps: 10, restSeconds: 0, cue: "", exerciseId: "machine_chest_press")
        #expect(fx.viewModel.replaceExercise(fx.step, with: candidate))
        #expect(fx.viewModel.progression?.suggestedWeightKg == 42.5)
        #expect(fx.viewModel.previousPerformance?.setWeightsKg == [40, 40, 40])
        RunnerPersistence.clear()
    }

    @Test
    func anotherAccountsWeightsAreNeverUsed() throws {
        let me = UUID()
        let fx = try Self.makeFixture(scope: .account(me))
        try Self.seedHistory(fx, stepId: fx.step.id, weights: [100, 100, 100], owner: UUID())
        try Self.seedHistory(fx, stepId: fx.step.id, weights: [100, 100, 100], owner: nil)
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.refreshExerciseInsight()
        #expect(fx.viewModel.previousPerformance == nil)
        #expect(fx.viewModel.progression == nil)

        try Self.seedHistory(fx, stepId: fx.step.id, weights: [60, 60, 60], owner: me)
        fx.viewModel.refreshExerciseInsight()
        #expect(fx.viewModel.progression?.suggestedWeightKg == 62.5)
        RunnerPersistence.clear()
    }

    @Test
    func endingEarlyAfterOneSetKeepsTheOlderFullRecordAsLastTime() throws {
        let fx = try Self.makeFixture()
        try Self.seedHistory(fx, stepId: fx.step.id, weights: [60, 60, 60])
        // Today: one set at 62.5, then "中断して終了".
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.setCurrentWeight(62.5)
        fx.viewModel.handle(action: .complete, context: try #require(fx.viewModel.completeContext))
        fx.viewModel.endSessionEarly()
        try fx.context.save()

        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.refreshExerciseInsight()
        #expect(fx.viewModel.previousPerformance?.setWeightsKg == [60, 60, 60])
        #expect(fx.viewModel.progression?.kind == .increaseWeight)
        #expect(fx.viewModel.progression?.suggestedWeightKg == 62.5)
        RunnerPersistence.clear()
    }

    @Test
    func duplicatedStepUsesOnlyItsOwnHistory() throws {
        let fx = try Self.makeFixture()
        // A second bench step in the same routine (e.g. via 複製).
        let backOff = Step(routineId: fx.routine.id, order: 1, title: "ベンチプレス", sets: 3, repsTarget: 10, restSeconds: 0, exerciseId: "bench_press")
        fx.context.insert(backOff)
        let past = Session(routineId: fx.routine.id, dayDate: .now, startedAt: Date().addingTimeInterval(-86_400), status: .completed)
        fx.context.insert(past)
        for i in 0..<3 { fx.context.insert(StepResult(sessionId: past.id, stepId: fx.step.id, setIndex: i, done: true, actualReps: 10, weightKg: 60)) }
        fx.context.insert(StepResult(sessionId: past.id, stepId: backOff.id, setIndex: 0, done: true, actualReps: 10, weightKg: 40))
        try fx.context.save()

        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.refreshExerciseInsight()
        #expect(fx.viewModel.previousPerformance?.setWeightsKg == [60, 60, 60])
        #expect(fx.viewModel.progression?.suggestedWeightKg == 62.5)
        RunnerPersistence.clear()
    }

    @Test
    func repOnlySuggestionLeavesTheWeightAlone() throws {
        let fx = try Self.makeFixture()
        try Self.seedHistory(fx, stepId: fx.step.id, weights: [nil, nil, nil])
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.refreshExerciseInsight()
        fx.viewModel.setCurrentWeight(50)
        fx.viewModel.applyProgressionSuggestion()
        #expect(fx.viewModel.currentReps == 11)
        #expect(fx.viewModel.currentWeightKg == 50)
        RunnerPersistence.clear()
    }
}


/// `StepResult.plannedSetsAtExecution`: the first result of a
/// (session, step) snapshots `step.sets`, every later one — including after a
/// resume or a Back overwrite — keeps that value.
@MainActor
struct RunnerPlannedSetsSnapshotTests {

    private struct Fixture {
        let viewModel: RunnerViewModel
        let routine: Routine
        let steps: [Step]
        let context: ModelContext
        let defaults: UserDefaults
    }

    private static func makeFixture(sets: [Int], exerciseId: String? = "bench_press", restSeconds: Int = 0) throws -> Fixture {
        RunnerPersistence.clear()
        let schema = Schema(versionedSchema: PulseCueSchemaV14.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let routine = Routine(name: "Planned")
        context.insert(routine)
        let steps = sets.enumerated().map { index, count in
            Step(routineId: routine.id, order: index, title: "Step \(index)", sets: count, repsTarget: 10, restSeconds: restSeconds, exerciseId: exerciseId)
        }
        steps.forEach(context.insert)
        try context.save()
        let defaults = UserDefaults(suiteName: "test.planned.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.notificationsEnabled = false
        let viewModel = RunnerViewModel(settings: settings)
        viewModel.configure(modelContext: context)
        return Fixture(viewModel: viewModel, routine: routine, steps: steps, context: context, defaults: defaults)
    }

    private static func complete(_ vm: RunnerViewModel) throws {
        vm.handle(action: .complete, context: try #require(vm.completeContext))
    }

    /// Results of `step`, in set order.
    private static func results(_ fx: Fixture, _ step: Step) throws -> [StepResult] {
        let stepId = step.id
        return try fx.context.fetch(FetchDescriptor<StepResult>(predicate: #Predicate { $0.stepId == stepId }))
            .sorted { $0.setIndex < $1.setIndex }
    }

    @Test
    func everyCompletedSetCarriesThePlannedCount() throws {
        let fx = try Self.makeFixture(sets: [3])
        fx.viewModel.start(routine: fx.routine)
        for _ in 0..<3 { try Self.complete(fx.viewModel) }
        let results = try Self.results(fx, fx.steps[0])
        #expect(results.map(\.setIndex) == [0, 1, 2])
        #expect(results.map(\.plannedSetsAtExecution) == [3, 3, 3])
        RunnerPersistence.clear()
    }

    @Test
    func aSkippedSetCarriesThePlannedCount() throws {
        let fx = try Self.makeFixture(sets: [3, 3])
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.handle(action: .skip)
        let results = try Self.results(fx, fx.steps[0])
        #expect(results.count == 1)
        #expect(results.first?.done == false)
        #expect(results.first?.plannedSetsAtExecution == 3)
        RunnerPersistence.clear()
    }

    @Test
    func skippingTheRestFromRestLeavesOneOfThree() throws {
        let fx = try Self.makeFixture(sets: [3, 3], restSeconds: 60)
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)
        #expect(fx.viewModel.phase == .rest)
        fx.viewModel.handle(action: .skip) // rest-phase skip: no results for sets 1–2
        #expect(fx.viewModel.currentStepIndex == 1)
        let results = try Self.results(fx, fx.steps[0])
        #expect(results.filter(\.done).count == 1)
        #expect(results.map(\.plannedSetsAtExecution) == [3])
        RunnerPersistence.clear()
    }

    @Test
    func endingEarlyKeepsThePlannedCountOnTheDoneSets() throws {
        let fx = try Self.makeFixture(sets: [4, 3])
        fx.viewModel.start(routine: fx.routine)
        let sessionId = try #require(fx.viewModel.sessionId)
        try Self.complete(fx.viewModel)
        try Self.complete(fx.viewModel)
        fx.viewModel.endSessionEarly()
        let session = try #require(try fx.context.fetch(FetchDescriptor<Session>(predicate: #Predicate { $0.id == sessionId })).first)
        #expect(session.status == .abandoned)
        let results = try Self.results(fx, fx.steps[0])
        #expect(results.map(\.done) == [true, true])
        #expect(results.map(\.plannedSetsAtExecution) == [4, 4])
        RunnerPersistence.clear()
    }

    @Test
    func resumeKeepsTheFirstSnapshotEvenIfTheStepChanged() throws {
        let fx = try Self.makeFixture(sets: [4])
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)
        try Self.complete(fx.viewModel)
        fx.viewModel.appDidEnterBackground()
        // The routine is edited while the workout is suspended.
        fx.steps[0].sets = 5
        try fx.context.save()

        let resumed = RunnerViewModel(settings: SettingsStore(defaults: fx.defaults))
        resumed.configure(modelContext: fx.context)
        #expect(resumed.currentSetIndex == 2)
        try Self.complete(resumed)
        try Self.complete(resumed)
        let results = try Self.results(fx, fx.steps[0])
        #expect(results.map(\.setIndex) == [0, 1, 2, 3])
        #expect(results.map(\.plannedSetsAtExecution) == [4, 4, 4, 4])
        RunnerPersistence.clear()
    }

    @Test
    func resumingALegacySessionKeepsItsUnknownSnapshot() throws {
        let fx = try Self.makeFixture(sets: [4])
        fx.viewModel.start(routine: fx.routine)
        let sessionId = try #require(fx.viewModel.sessionId)
        try Self.complete(fx.viewModel)
        // Stand-in for a V12 result migrated to V13: same session and step,
        // recorded before the snapshot existed, so it is unknown (nil).
        let legacy = try #require(try Self.results(fx, fx.steps[0]).first)
        legacy.plannedSetsAtExecution = nil
        try fx.context.save()
        fx.viewModel.appDidEnterBackground()

        let resumed = RunnerViewModel(settings: SettingsStore(defaults: fx.defaults))
        resumed.configure(modelContext: fx.context)
        #expect(resumed.sessionId == sessionId)
        #expect(resumed.currentSetIndex == 1)
        let session = try #require(try fx.context.fetch(FetchDescriptor<Session>(predicate: #Predicate { $0.id == sessionId })).first)
        #expect(session.status == .inProgress)
        try Self.complete(resumed)

        let results = try Self.results(fx, fx.steps[0])
        #expect(results.count == 2)
        #expect(results.map(\.sessionId) == [sessionId, sessionId])
        #expect(results.map(\.stepId) == [fx.steps[0].id, fx.steps[0].id])
        #expect(results.map(\.setIndex) == [0, 1])
        #expect(results.map(\.done) == [true, true])
        #expect(results.map(\.actualReps) == [10, 10])
        // Never filled in from the live `step.sets` (4), never mixed.
        #expect(results.map(\.plannedSetsAtExecution) == [nil, nil])
        #expect(results.map(\.plannedSetsAtExecution) != [nil, 4])
        RunnerPersistence.clear()
    }

    @Test
    func changingStepSetsAfterTheFirstResultNeverSplitsTheSnapshot() throws {
        let fx = try Self.makeFixture(sets: [4])
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)
        fx.steps[0].sets = 2
        try Self.complete(fx.viewModel)
        #expect(try Self.results(fx, fx.steps[0]).map(\.plannedSetsAtExecution) == [4, 4])
        RunnerPersistence.clear()
    }

    @Test
    func overwritingASetViaBackKeepsItsSnapshot() throws {
        let fx = try Self.makeFixture(sets: [3])
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)
        fx.steps[0].sets = 5
        fx.viewModel.handle(action: .back)
        #expect(fx.viewModel.currentSetIndex == 0)
        fx.viewModel.adjustCurrentReps(by: -2)
        try Self.complete(fx.viewModel)
        let results = try Self.results(fx, fx.steps[0])
        #expect(results.count == 1)
        #expect(results.first?.actualReps == 8)
        #expect(results.first?.plannedSetsAtExecution == 3)
        RunnerPersistence.clear()
    }

    @Test
    func duplicatedStepsOfOneExerciseKeepTheirOwnPlannedCounts() throws {
        let fx = try Self.makeFixture(sets: [3, 4])
        fx.viewModel.start(routine: fx.routine)
        for _ in 0..<7 { try Self.complete(fx.viewModel) }
        #expect(fx.steps.map(\.exerciseId) == ["bench_press", "bench_press"])
        #expect(try Self.results(fx, fx.steps[0]).map(\.plannedSetsAtExecution) == [3, 3, 3])
        #expect(try Self.results(fx, fx.steps[1]).map(\.plannedSetsAtExecution) == [4, 4, 4, 4])
        RunnerPersistence.clear()
    }

    @Test
    func aReplacedExerciseSnapshotsAtItsFirstResult() throws {
        let fx = try Self.makeFixture(sets: [3])
        fx.viewModel.start(routine: fx.routine)
        let candidate = GeneratedExercise(machineId: "chest_press", exerciseName: "チェストプレス", sets: 5, reps: 10, restSeconds: 0, cue: "", exerciseId: "machine_chest_press")
        #expect(fx.viewModel.replaceExercise(fx.steps[0], with: candidate))
        try Self.complete(fx.viewModel)
        // The replacement keeps the step's own sets (3), not the candidate's.
        #expect(fx.steps[0].exerciseId == "machine_chest_press")
        #expect(try Self.results(fx, fx.steps[0]).map(\.plannedSetsAtExecution) == [3])
        RunnerPersistence.clear()
    }

    @Test
    func guestAdoptionKeepsThePlannedCount() throws {
        let fx = try Self.makeFixture(sets: [2])
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)
        try Self.complete(fx.viewModel)
        try fx.context.save()
        let account = UUID()
        let summary = try AccountScopedSyncStore().adoptGuestWorkoutData(for: account, in: fx.context)
        #expect(summary.adoptedStepResults == 2)
        let results = try Self.results(fx, fx.steps[0])
        #expect(results.map(\.ownerAccountID) == [account, account])
        #expect(results.map(\.plannedSetsAtExecution) == [2, 2])
        RunnerPersistence.clear()
    }
}

/// `StepResult.exerciseIdAtExecution` / `exerciseTitleAtExecution`: the first
/// result of a (session, step) snapshots the step's exercise, every later one —
/// after a resume, a Back overwrite, or a live edit of the step — keeps it.
@MainActor
struct RunnerExerciseSnapshotTests {

    private struct Fixture {
        let viewModel: RunnerViewModel
        let routine: Routine
        let steps: [Step]
        let context: ModelContext
        let defaults: UserDefaults
    }

    private static func makeFixture(sets: [Int], exerciseIds: [String?]? = nil, restSeconds: Int = 0) throws -> Fixture {
        RunnerPersistence.clear()
        let schema = Schema(versionedSchema: PulseCueSchemaV14.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let routine = Routine(name: "Exercise")
        context.insert(routine)
        let ids = exerciseIds ?? Array(repeating: "bench_press", count: sets.count)
        let steps = sets.enumerated().map { index, count in
            Step(routineId: routine.id, order: index, title: "ベンチプレス", sets: count, repsTarget: 10, restSeconds: restSeconds, exerciseId: ids[index])
        }
        steps.forEach(context.insert)
        try context.save()
        let defaults = UserDefaults(suiteName: "test.exercise.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.notificationsEnabled = false
        let viewModel = RunnerViewModel(settings: settings)
        viewModel.configure(modelContext: context)
        return Fixture(viewModel: viewModel, routine: routine, steps: steps, context: context, defaults: defaults)
    }

    private static func complete(_ vm: RunnerViewModel) throws {
        vm.handle(action: .complete, context: try #require(vm.completeContext))
    }

    private static func results(_ fx: Fixture, _ step: Step) throws -> [StepResult] {
        let stepId = step.id
        return try fx.context.fetch(FetchDescriptor<StepResult>(predicate: #Predicate { $0.stepId == stepId }))
            .sorted { $0.setIndex < $1.setIndex }
    }

    private static func ids(_ results: [StepResult]) -> [String?] { results.map(\.exerciseIdAtExecution) }
    private static func titles(_ results: [StepResult]) -> [String?] { results.map(\.exerciseTitleAtExecution) }

    private static let chestPress = GeneratedExercise(machineId: "chest_press", exerciseName: "チェストプレス", sets: 3, reps: 10, restSeconds: 0, cue: "", exerciseId: "machine_chest_press")

    @Test
    func everyCompletedSetCarriesTheExercise() throws {
        let fx = try Self.makeFixture(sets: [3])
        fx.viewModel.start(routine: fx.routine)
        for _ in 0..<3 { try Self.complete(fx.viewModel) }
        let results = try Self.results(fx, fx.steps[0])
        #expect(results.map(\.setIndex) == [0, 1, 2])
        #expect(Self.ids(results) == ["bench_press", "bench_press", "bench_press"])
        #expect(Self.titles(results) == ["ベンチプレス", "ベンチプレス", "ベンチプレス"])
        RunnerPersistence.clear()
    }

    @Test
    func aSkippedSetCarriesTheExercise() throws {
        let fx = try Self.makeFixture(sets: [3, 3])
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.handle(action: .skip)
        let results = try Self.results(fx, fx.steps[0])
        #expect(results.map(\.done) == [false])
        #expect(Self.ids(results) == ["bench_press"])
        #expect(Self.titles(results) == ["ベンチプレス"])
        RunnerPersistence.clear()
    }

    @Test
    func skippingTheRestLeavesTheExerciseOnTheRecordedSet() throws {
        let fx = try Self.makeFixture(sets: [3, 3], restSeconds: 60)
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)
        #expect(fx.viewModel.phase == .rest)
        fx.viewModel.handle(action: .skip) // rest-phase skip: no results for sets 1–2
        #expect(fx.viewModel.currentStepIndex == 1)
        let results = try Self.results(fx, fx.steps[0])
        #expect(results.count == 1)
        #expect(Self.ids(results) == ["bench_press"])
        #expect(Self.titles(results) == ["ベンチプレス"])
        RunnerPersistence.clear()
    }

    @Test
    func endingEarlyKeepsTheExerciseOnTheDoneSets() throws {
        let fx = try Self.makeFixture(sets: [4, 3])
        fx.viewModel.start(routine: fx.routine)
        let sessionId = try #require(fx.viewModel.sessionId)
        try Self.complete(fx.viewModel)
        try Self.complete(fx.viewModel)
        fx.viewModel.endSessionEarly()
        let session = try #require(try fx.context.fetch(FetchDescriptor<Session>(predicate: #Predicate { $0.id == sessionId })).first)
        #expect(session.status == .abandoned)
        let results = try Self.results(fx, fx.steps[0])
        #expect(Self.ids(results) == ["bench_press", "bench_press"])
        #expect(Self.titles(results) == ["ベンチプレス", "ベンチプレス"])
        RunnerPersistence.clear()
    }

    @Test
    func resumeKeepsTheFirstSnapshotEvenIfTheStepChanged() throws {
        let fx = try Self.makeFixture(sets: [4])
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)
        try Self.complete(fx.viewModel)
        fx.viewModel.appDidEnterBackground()
        fx.steps[0].exerciseId = "incline_bench_press"
        fx.steps[0].title = "インクラインベンチ"
        try fx.context.save()

        let resumed = RunnerViewModel(settings: SettingsStore(defaults: fx.defaults))
        resumed.configure(modelContext: fx.context)
        #expect(resumed.currentSetIndex == 2)
        try Self.complete(resumed)
        try Self.complete(resumed)
        let results = try Self.results(fx, fx.steps[0])
        #expect(results.map(\.setIndex) == [0, 1, 2, 3])
        #expect(Self.ids(results) == Array(repeating: "bench_press", count: 4))
        #expect(Self.titles(results) == Array(repeating: "ベンチプレス", count: 4))
        RunnerPersistence.clear()
    }

    @Test
    func resumingALegacySessionKeepsItsUnknownExercise() throws {
        let fx = try Self.makeFixture(sets: [4])
        fx.viewModel.start(routine: fx.routine)
        let sessionId = try #require(fx.viewModel.sessionId)
        try Self.complete(fx.viewModel)
        // Stand-in for a V13 result migrated to V14: no exercise snapshot.
        let legacy = try #require(try Self.results(fx, fx.steps[0]).first)
        legacy.exerciseIdAtExecution = nil
        legacy.exerciseTitleAtExecution = nil
        try fx.context.save()
        fx.viewModel.appDidEnterBackground()

        let resumed = RunnerViewModel(settings: SettingsStore(defaults: fx.defaults))
        resumed.configure(modelContext: fx.context)
        #expect(resumed.sessionId == sessionId)
        #expect(resumed.currentSetIndex == 1)
        try Self.complete(resumed)

        let results = try Self.results(fx, fx.steps[0])
        #expect(results.map(\.setIndex) == [0, 1])
        #expect(results.map(\.done) == [true, true])
        // Never filled in from the live step, never mixed.
        #expect(Self.ids(results) == [nil, nil])
        #expect(Self.titles(results) == [nil, nil])
        // The planned-sets snapshot is untouched by the legacy exercise nil.
        #expect(results.map(\.plannedSetsAtExecution) == [4, 4])
        RunnerPersistence.clear()
    }

    @Test
    func changingTheStepAfterTheFirstResultNeverSplitsTheSnapshot() throws {
        let fx = try Self.makeFixture(sets: [3])
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)
        fx.steps[0].exerciseId = "machine_chest_press"
        fx.steps[0].title = "チェストプレス"
        try Self.complete(fx.viewModel)
        try Self.complete(fx.viewModel)
        let results = try Self.results(fx, fx.steps[0])
        #expect(Self.ids(results) == ["bench_press", "bench_press", "bench_press"])
        #expect(Self.titles(results) == ["ベンチプレス", "ベンチプレス", "ベンチプレス"])
        RunnerPersistence.clear()
    }

    @Test
    func overwritingASetViaBackKeepsItsSnapshots() throws {
        let fx = try Self.makeFixture(sets: [3])
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)
        fx.steps[0].exerciseId = "machine_chest_press"
        fx.steps[0].title = "チェストプレス"
        fx.steps[0].sets = 5
        fx.viewModel.handle(action: .back)
        #expect(fx.viewModel.currentSetIndex == 0)
        fx.viewModel.adjustCurrentReps(by: -2)
        try Self.complete(fx.viewModel)
        let results = try Self.results(fx, fx.steps[0])
        #expect(results.count == 1)
        #expect(results.first?.actualReps == 8)
        #expect(Self.ids(results) == ["bench_press"])
        #expect(Self.titles(results) == ["ベンチプレス"])
        #expect(results.first?.plannedSetsAtExecution == 3)
        RunnerPersistence.clear()
    }

    @Test
    func duplicatedStepsKeepTheirOwnSnapshots() throws {
        let fx = try Self.makeFixture(sets: [2, 2])
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)
        try Self.complete(fx.viewModel)
        // Only the second step changes before it starts.
        fx.steps[1].exerciseId = "incline_bench_press"
        fx.steps[1].title = "インクラインベンチ"
        try Self.complete(fx.viewModel)
        try Self.complete(fx.viewModel)
        #expect(Self.ids(try Self.results(fx, fx.steps[0])) == ["bench_press", "bench_press"])
        #expect(Self.ids(try Self.results(fx, fx.steps[1])) == ["incline_bench_press", "incline_bench_press"])
        #expect(Self.titles(try Self.results(fx, fx.steps[1])) == ["インクラインベンチ", "インクラインベンチ"])
        RunnerPersistence.clear()
    }

    @Test
    func aReplacedUnstartedStepSnapshotsTheReplacement() throws {
        let fx = try Self.makeFixture(sets: [3, 3])
        fx.viewModel.start(routine: fx.routine)
        #expect(fx.viewModel.replaceExercise(fx.steps[0], with: Self.chestPress))
        #expect(fx.viewModel.replaceExercise(fx.steps[1], with: Self.chestPress))
        try Self.complete(fx.viewModel)
        let results = try Self.results(fx, fx.steps[0])
        #expect(Self.ids(results) == ["machine_chest_press"])
        #expect(Self.titles(results) == ["チェストプレス"])
        #expect(results.map(\.plannedSetsAtExecution) == [3])
        RunnerPersistence.clear()
    }

    @Test
    func aStepWithARecordedSetCannotBeReplacedMidSet() throws {
        let fx = try Self.makeFixture(sets: [3, 3], restSeconds: 60)
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)
        #expect(fx.viewModel.phase == .rest)
        #expect(!fx.viewModel.canReplaceCurrentExercise)
        #expect(!fx.viewModel.replaceExercise(fx.steps[0], with: Self.chestPress))
        fx.viewModel.handle(action: .skip)
        #expect(fx.viewModel.currentStepIndex == 1)
        // A step already behind the cursor is never rewritten.
        #expect(!fx.viewModel.replaceExercise(fx.steps[0], with: Self.chestPress))
        #expect(fx.steps[0].exerciseId == "bench_press")
        #expect(Self.ids(try Self.results(fx, fx.steps[0])) == ["bench_press"])
        RunnerPersistence.clear()
    }

    @Test
    func editingTheRoutineAfterTheSessionLeavesTheSnapshot() throws {
        let fx = try Self.makeFixture(sets: [2])
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)
        try Self.complete(fx.viewModel)
        #expect(fx.viewModel.phase == .done)
        fx.steps[0].exerciseId = "machine_chest_press"
        fx.steps[0].title = "チェストプレス"
        try fx.context.save()
        let results = try Self.results(fx, fx.steps[0])
        #expect(Self.ids(results) == ["bench_press", "bench_press"])
        #expect(Self.titles(results) == ["ベンチプレス", "ベンチプレス"])
        RunnerPersistence.clear()
    }

    @Test
    func aStepWithoutAnExerciseIdStillSnapshotsItsTitle() throws {
        let fx = try Self.makeFixture(sets: [1], exerciseIds: [nil])
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)
        let results = try Self.results(fx, fx.steps[0])
        #expect(Self.ids(results) == [nil])
        #expect(Self.titles(results) == ["ベンチプレス"])
        RunnerPersistence.clear()
    }

    @Test
    func guestAdoptionKeepsTheExercise() throws {
        let fx = try Self.makeFixture(sets: [2])
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)
        try Self.complete(fx.viewModel)
        try fx.context.save()
        let account = UUID()
        let summary = try AccountScopedSyncStore().adoptGuestWorkoutData(for: account, in: fx.context)
        #expect(summary.adoptedStepResults == 2)
        let results = try Self.results(fx, fx.steps[0])
        #expect(results.map(\.ownerAccountID) == [account, account])
        #expect(Self.ids(results) == ["bench_press", "bench_press"])
        #expect(Self.titles(results) == ["ベンチプレス", "ベンチプレス"])
        #expect(results.map(\.plannedSetsAtExecution) == [2, 2])
        RunnerPersistence.clear()
    }
}

/// Exercise replacement is refused for any step that already has a result in
/// the current session — Back to set 0 does not make a started step unstarted.
@MainActor
struct RunnerReplacementGuardTests {

    private struct Fixture {
        let viewModel: RunnerViewModel
        let routine: Routine
        let steps: [Step]
        let context: ModelContext
    }

    private static func makeFixture(sets: Int = 3, restSeconds: Int = 0) throws -> Fixture {
        RunnerPersistence.clear()
        let schema = Schema(versionedSchema: PulseCueSchemaV14.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let routine = Routine(name: "Guard")
        context.insert(routine)
        let steps = (0..<3).map { index in
            Step(routineId: routine.id, order: index, title: "ベンチプレス", sets: sets, repsTarget: 10, restSeconds: restSeconds, exerciseId: "bench_press")
        }
        steps.forEach(context.insert)
        try context.save()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.replace.\(UUID().uuidString)")!)
        settings.notificationsEnabled = false
        let viewModel = RunnerViewModel(settings: settings)
        viewModel.configure(modelContext: context)
        return Fixture(viewModel: viewModel, routine: routine, steps: steps, context: context)
    }

    private static func complete(_ vm: RunnerViewModel) throws {
        vm.handle(action: .complete, context: try #require(vm.completeContext))
    }

    private static let chestPress = GeneratedExercise(machineId: "chest_press", exerciseName: "チェストプレス", sets: 3, reps: 10, restSeconds: 0, cue: "", exerciseId: "machine_chest_press")

    private static func expectUnchanged(_ step: Step) {
        #expect(step.exerciseId == "bench_press")
        #expect(step.title == "ベンチプレス")
    }

    @Test
    func aFreshCurrentStepCanBeReplaced() throws {
        let fx = try Self.makeFixture()
        fx.viewModel.start(routine: fx.routine)
        #expect(fx.viewModel.canReplaceCurrentExercise)
        #expect(fx.viewModel.replaceExercise(fx.steps[0], with: Self.chestPress))
        #expect(fx.steps[0].exerciseId == "machine_chest_press")
        RunnerPersistence.clear()
    }

    @Test
    func aCompletedSetBlocksReplacement() throws {
        let fx = try Self.makeFixture()
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)
        #expect(fx.viewModel.currentSetIndex == 1)
        #expect(!fx.viewModel.canReplaceCurrentExercise)
        #expect(!fx.viewModel.replaceExercise(fx.steps[0], with: Self.chestPress))
        Self.expectUnchanged(fx.steps[0])
        RunnerPersistence.clear()
    }

    @Test
    func backToSetZeroAfterACompleteStillBlocksReplacement() throws {
        let fx = try Self.makeFixture()
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)
        fx.viewModel.handle(action: .back)
        #expect(fx.viewModel.currentSetIndex == 0)
        #expect(fx.viewModel.phase == .exercise)
        #expect(!fx.viewModel.canReplaceCurrentExercise)
        #expect(!fx.viewModel.replaceExercise(fx.steps[0], with: Self.chestPress))
        Self.expectUnchanged(fx.steps[0])
        RunnerPersistence.clear()
    }

    @Test
    func backToSetZeroAfterASkipStillBlocksReplacement() throws {
        // Skip jumps to the next step; Back lands on the skipped step's last
        // set, which is set 0 for a one-set step.
        let fx = try Self.makeFixture(sets: 1)
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.handle(action: .skip)
        #expect(fx.viewModel.currentStepIndex == 1)
        let stepId = fx.steps[0].id
        let results = try fx.context.fetch(FetchDescriptor<StepResult>(predicate: #Predicate { $0.stepId == stepId }))
        #expect(results.map(\.done) == [false])
        fx.viewModel.handle(action: .back)
        #expect(fx.viewModel.currentStepIndex == 0)
        #expect(fx.viewModel.currentSetIndex == 0)
        #expect(fx.viewModel.phase == .exercise)
        #expect(!fx.viewModel.canReplaceCurrentExercise)
        #expect(!fx.viewModel.replaceExercise(fx.steps[0], with: Self.chestPress))
        Self.expectUnchanged(fx.steps[0])
        RunnerPersistence.clear()
    }

    @Test
    func anUnstartedLaterStepCanBeReplaced() throws {
        let fx = try Self.makeFixture()
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)
        #expect(fx.viewModel.canReplaceNextExercise)
        #expect(fx.viewModel.replaceExercise(fx.steps[1], with: Self.chestPress))
        #expect(fx.viewModel.replaceExercise(fx.steps[2], with: Self.chestPress))
        #expect(fx.steps[1].exerciseId == "machine_chest_press")
        RunnerPersistence.clear()
    }

    @Test
    func aLaterStepWithAResultInThisSessionIsRefused() throws {
        let fx = try Self.makeFixture()
        fx.viewModel.start(routine: fx.routine)
        let sessionId = try #require(fx.viewModel.sessionId)
        fx.context.insert(StepResult(sessionId: sessionId, stepId: fx.steps[1].id, setIndex: 0, done: true, actualReps: 10))
        try fx.context.save()
        #expect(!fx.viewModel.canReplaceNextExercise)
        #expect(!fx.viewModel.replaceExercise(fx.steps[1], with: Self.chestPress))
        Self.expectUnchanged(fx.steps[1])
        // Its untouched sibling is still replaceable.
        #expect(fx.viewModel.replaceExercise(fx.steps[2], with: Self.chestPress))
        RunnerPersistence.clear()
    }

    @Test
    func restingBlocksReplacingTheCurrentStep() throws {
        let fx = try Self.makeFixture(restSeconds: 60)
        fx.viewModel.start(routine: fx.routine)
        try Self.complete(fx.viewModel)
        #expect(fx.viewModel.phase == .rest)
        #expect(!fx.viewModel.canReplaceCurrentExercise)
        #expect(!fx.viewModel.replaceExercise(fx.steps[0], with: Self.chestPress))
        Self.expectUnchanged(fx.steps[0])
        RunnerPersistence.clear()
    }

    @Test
    func anotherSessionsResultsNeverBlockReplacement() throws {
        let fx = try Self.makeFixture()
        let past = Session(routineId: fx.routine.id, dayDate: Date().addingTimeInterval(-86_400))
        past.status = .completed
        fx.context.insert(past)
        for step in fx.steps.prefix(2) {
            fx.context.insert(StepResult(sessionId: past.id, stepId: step.id, setIndex: 0, done: true, actualReps: 10))
        }
        try fx.context.save()
        fx.viewModel.start(routine: fx.routine)
        #expect(fx.viewModel.sessionId != past.id)
        #expect(fx.viewModel.canReplaceCurrentExercise)
        #expect(fx.viewModel.canReplaceNextExercise)
        #expect(fx.viewModel.replaceExercise(fx.steps[0], with: Self.chestPress))
        #expect(fx.viewModel.replaceExercise(fx.steps[1], with: Self.chestPress))
        RunnerPersistence.clear()
    }
}

/// 案F through the Runner: last time's planned-sets snapshot decides the
/// suggestion after the routine's set count changed.
@MainActor
struct RunnerPlannedSetsProgressionTests {

    private struct Fixture {
        let viewModel: RunnerViewModel
        let routine: Routine
        let step: Step
        let context: ModelContext
    }

    private static func makeFixture(sets: Int) throws -> Fixture {
        RunnerPersistence.clear()
        let schema = Schema([Routine.self, Step.self, Session.self, StepResult.self, DayLog.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let routine = Routine(name: "PlannedSets")
        context.insert(routine)
        let step = Step(routineId: routine.id, order: 0, title: "ベンチプレス", sets: sets, repsTarget: 10, restSeconds: 0, exerciseId: "bench_press")
        context.insert(step)
        try context.save()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.pprog.\(UUID().uuidString)")!)
        settings.notificationsEnabled = false
        let viewModel = RunnerViewModel(settings: settings)
        viewModel.configure(modelContext: context, scope: .guest)
        return Fixture(viewModel: viewModel, routine: routine, step: step, context: context)
    }

    private static func seed(_ fx: Fixture, reps: [Int], planned: Int?) throws {
        let past = Session(routineId: fx.routine.id, dayDate: .now, startedAt: Date().addingTimeInterval(-86_400), status: .completed)
        fx.context.insert(past)
        for (index, r) in reps.enumerated() {
            fx.context.insert(StepResult(sessionId: past.id, stepId: fx.step.id, setIndex: index, done: true, actualReps: r, weightKg: 60, plannedSetsAtExecution: planned))
        }
        try fx.context.save()
    }

    private static func run(_ fx: Fixture) {
        fx.viewModel.start(routine: fx.routine)
        fx.viewModel.refreshExerciseInsight()
    }

    @Test
    func fourPlannedToThreeSuggestsHeavier() throws {
        let fx = try Self.makeFixture(sets: 3)
        try Self.seed(fx, reps: [10, 10, 10, 10], planned: 4)
        Self.run(fx)
        #expect(fx.viewModel.previousPerformance?.plannedSetCount == 4)
        #expect(fx.viewModel.progression?.kind == .increaseWeight)
        fx.viewModel.applyProgressionSuggestion()
        #expect(fx.viewModel.currentWeightKg == 62.5)
        #expect(fx.viewModel.currentReps == 10)
        #expect(fx.step.sets == 3)
        RunnerPersistence.clear()
    }

    @Test
    func threePlannedToFourHoldsTheWeight() throws {
        let fx = try Self.makeFixture(sets: 4)
        try Self.seed(fx, reps: [10, 10, 10], planned: 3)
        Self.run(fx)
        #expect(fx.viewModel.progression?.kind == .holdWeight)
        #expect(fx.viewModel.progression?.suggestedWeightKg == 60)
        fx.viewModel.applyProgressionSuggestion()
        #expect(fx.viewModel.currentWeightKg == 60)
        RunnerPersistence.clear()
    }

    @Test
    func legacyHistoryKeepsTheOldBehavior() throws {
        let fx = try Self.makeFixture(sets: 3)
        try Self.seed(fx, reps: [10, 10, 10, 10], planned: nil)
        Self.run(fx)
        #expect(fx.viewModel.previousPerformance?.plannedSetCount == nil)
        #expect(fx.viewModel.progression?.kind == .holdReps)
        #expect(fx.viewModel.progression?.suggestedWeightKg == nil)
        RunnerPersistence.clear()

        let same = try Self.makeFixture(sets: 3)
        try Self.seed(same, reps: [10, 10, 10], planned: nil)
        Self.run(same)
        #expect(same.viewModel.progression?.kind == .increaseWeight)
        RunnerPersistence.clear()
    }

    @Test
    func partialSnapshotNeverProgresses() throws {
        let fx = try Self.makeFixture(sets: 2)
        try Self.seed(fx, reps: [10, 10], planned: 4)
        Self.run(fx)
        #expect(fx.viewModel.progression?.kind == .holdWeight)
        #expect(fx.viewModel.progression?.suggestedWeightKg == 60)
        RunnerPersistence.clear()
    }
}
