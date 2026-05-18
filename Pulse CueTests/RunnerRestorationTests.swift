//
//  RunnerRestorationTests.swift
//  Pulse CueTests
//
//  Focused tests for the Runner's persistence + restoration paths.
//  PulseCue's core product value depends on the Runner correctly
//  re-attaching to an in-flight workout after the app is
//  backgrounded or force-quit, so these tests lock in:
//
//    - `RunnerPersistence` (UserDefaults round-trip + clear)
//    - `RunnerViewModel.configure(modelContext:)`'s implicit
//      `restoreIfPossible()` against various persisted/SwiftData
//      consistency states.
//
//  Each test that touches `UserDefaults.standard` calls
//  `RunnerPersistence.clear()` first to match the cleanup pattern
//  already used by `RunnerStateMachineTests`. Tests run serially
//  within this `@MainActor struct` suite, so the shared key cannot
//  interleave.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct RunnerRestorationTests {

    // MARK: - Fixture

    private struct Fixture {
        let viewModel: RunnerViewModel
        let routine: Routine
        let session: Session
        let context: ModelContext
    }

    /// Builds an in-memory SwiftData container with a routine, N
    /// steps, and an in-progress Session. The fixture does **not**
    /// call `viewModel.configure(...)` — the caller decides when to
    /// trigger the restore by either calling `configure` directly or
    /// by writing the persisted state first.
    private static func makeFixture(
        stepCount: Int = 3,
        setsPerStep: Int = 2,
        restSeconds: Int = 30
    ) throws -> Fixture {
        RunnerPersistence.clear()

        let schema = Schema([
            Routine.self,
            Step.self,
            Session.self,
            StepResult.self,
            DayLog.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let routine = Routine(name: "Restoration Routine")
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
        let session = Session(routineId: routine.id, dayDate: Date(), status: .inProgress)
        context.insert(session)
        try context.save()

        // Isolated UserDefaults suite so `SettingsStore` flags don't
        // leak across the suite. Notifications kept off so
        // `scheduleRestNotification` is a no-op.
        let suiteName = "test.runner.restore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = SettingsStore(defaults: defaults)
        settings.notificationsEnabled = false

        let viewModel = RunnerViewModel(settings: settings)

        return Fixture(
            viewModel: viewModel,
            routine: routine,
            session: session,
            context: context,
        )
    }

    private static func persist(
        sessionId: UUID,
        routineId: UUID,
        phase: RunnerPhase,
        stepIndex: Int,
        setIndex: Int,
        restDeadline: Date?,
    ) {
        RunnerPersistence.save(
            RunnerPersistentState(
                sessionId: sessionId,
                routineId: routineId,
                phase: phase,
                stepIndex: stepIndex,
                setIndex: setIndex,
                restDeadline: restDeadline,
                lastUpdatedAt: Date(),
            ),
        )
    }

    // MARK: - RunnerPersistence round-trip (UserDefaults only)

    @Test
    func loadReturnsNilWhenNothingHasBeenSaved() {
        RunnerPersistence.clear()
        #expect(RunnerPersistence.load() == nil)
    }

    @Test
    func clearRemovesPreviouslySavedState() {
        RunnerPersistence.clear()
        let state = RunnerPersistentState(
            sessionId: UUID(),
            routineId: UUID(),
            phase: .exercise,
            stepIndex: 0,
            setIndex: 0,
            restDeadline: nil,
            lastUpdatedAt: Date(),
        )
        RunnerPersistence.save(state)
        #expect(RunnerPersistence.load() != nil)

        RunnerPersistence.clear()
        #expect(RunnerPersistence.load() == nil)
    }

    @Test
    func saveOverwritesPreviousState() {
        RunnerPersistence.clear()
        let firstId = UUID()
        let secondId = UUID()
        RunnerPersistence.save(
            RunnerPersistentState(
                sessionId: firstId,
                routineId: UUID(),
                phase: .exercise,
                stepIndex: 0,
                setIndex: 0,
                restDeadline: nil,
                lastUpdatedAt: Date(),
            ),
        )
        RunnerPersistence.save(
            RunnerPersistentState(
                sessionId: secondId,
                routineId: UUID(),
                phase: .done,
                stepIndex: 5,
                setIndex: 3,
                restDeadline: nil,
                lastUpdatedAt: Date(),
            ),
        )

        let loaded = RunnerPersistence.load()
        #expect(loaded?.sessionId == secondId)
        #expect(loaded?.phase == .done)
        #expect(loaded?.stepIndex == 5)
        #expect(loaded?.setIndex == 3)
    }

    @Test
    func roundTripPreservesAllFields() throws {
        RunnerPersistence.clear()
        let sessionId = UUID()
        let routineId = UUID()
        let deadline = Date().addingTimeInterval(45)
        let savedAt = Date().addingTimeInterval(-5)
        let state = RunnerPersistentState(
            sessionId: sessionId,
            routineId: routineId,
            phase: .rest,
            stepIndex: 2,
            setIndex: 1,
            restDeadline: deadline,
            lastUpdatedAt: savedAt,
        )
        RunnerPersistence.save(state)

        let loaded = try #require(RunnerPersistence.load())
        #expect(loaded.sessionId == sessionId)
        #expect(loaded.routineId == routineId)
        #expect(loaded.phase == .rest)
        #expect(loaded.stepIndex == 2)
        #expect(loaded.setIndex == 1)
        #expect(loaded.restDeadline?.timeIntervalSince1970 == deadline.timeIntervalSince1970)
        #expect(loaded.lastUpdatedAt.timeIntervalSince1970 == savedAt.timeIntervalSince1970)
    }

    @Test
    func roundTripPreservesEachRunnerPhase() throws {
        for phase in [RunnerPhase.exercise, .rest, .done] {
            RunnerPersistence.clear()
            RunnerPersistence.save(
                RunnerPersistentState(
                    sessionId: UUID(),
                    routineId: UUID(),
                    phase: phase,
                    stepIndex: 0,
                    setIndex: 0,
                    restDeadline: nil,
                    lastUpdatedAt: Date(),
                ),
            )
            let loaded = try #require(RunnerPersistence.load())
            #expect(loaded.phase == phase, "phase round-trip failed for \(phase)")
        }
    }

    @Test
    func roundTripPreservesNilAndDatedRestDeadlines() throws {
        RunnerPersistence.clear()
        // Nil
        RunnerPersistence.save(
            RunnerPersistentState(
                sessionId: UUID(),
                routineId: UUID(),
                phase: .exercise,
                stepIndex: 0,
                setIndex: 0,
                restDeadline: nil,
                lastUpdatedAt: Date(),
            ),
        )
        #expect(try #require(RunnerPersistence.load()).restDeadline == nil)

        // Future date
        let future = Date().addingTimeInterval(60)
        RunnerPersistence.save(
            RunnerPersistentState(
                sessionId: UUID(),
                routineId: UUID(),
                phase: .rest,
                stepIndex: 0,
                setIndex: 0,
                restDeadline: future,
                lastUpdatedAt: Date(),
            ),
        )
        #expect(
            try #require(RunnerPersistence.load()).restDeadline?.timeIntervalSince1970 ==
                future.timeIntervalSince1970,
        )

        // Past date
        let past = Date().addingTimeInterval(-300)
        RunnerPersistence.save(
            RunnerPersistentState(
                sessionId: UUID(),
                routineId: UUID(),
                phase: .rest,
                stepIndex: 0,
                setIndex: 0,
                restDeadline: past,
                lastUpdatedAt: Date(),
            ),
        )
        #expect(
            try #require(RunnerPersistence.load()).restDeadline?.timeIntervalSince1970 ==
                past.timeIntervalSince1970,
        )
    }

    // MARK: - RunnerViewModel restoration

    @Test
    func configureWithNoPersistedStateLeavesViewModelInIdle() throws {
        let fixture = try Self.makeFixture()
        // No call to RunnerPersistence.save before configure.
        fixture.viewModel.configure(modelContext: fixture.context)

        // Idle state after init: phase .done, no session/routine ids.
        #expect(fixture.viewModel.phase == .done)
        #expect(fixture.viewModel.sessionId == nil)
        #expect(fixture.viewModel.routineId == nil)
    }

    @Test
    func restoresExercisePhaseWithSavedIndices() throws {
        let fixture = try Self.makeFixture(stepCount: 3, setsPerStep: 3)
        Self.persist(
            sessionId: fixture.session.id,
            routineId: fixture.routine.id,
            phase: .exercise,
            stepIndex: 1,
            setIndex: 2,
            restDeadline: nil,
        )

        fixture.viewModel.configure(modelContext: fixture.context)

        #expect(fixture.viewModel.phase == .exercise)
        #expect(fixture.viewModel.sessionId == fixture.session.id)
        #expect(fixture.viewModel.routineId == fixture.routine.id)
        #expect(fixture.viewModel.currentStepIndex == 1)
        #expect(fixture.viewModel.currentSetIndex == 2)
        #expect(fixture.viewModel.restDeadline == nil)
    }

    @Test
    func restoresRestPhaseWhenDeadlineIsInTheFuture() throws {
        let fixture = try Self.makeFixture()
        let futureDeadline = Date().addingTimeInterval(45)
        Self.persist(
            sessionId: fixture.session.id,
            routineId: fixture.routine.id,
            phase: .rest,
            stepIndex: 0,
            setIndex: 0,
            restDeadline: futureDeadline,
        )

        fixture.viewModel.configure(modelContext: fixture.context)

        #expect(fixture.viewModel.phase == .rest)
        #expect(fixture.viewModel.restDeadline?.timeIntervalSince1970 ==
            futureDeadline.timeIntervalSince1970)
    }

    @Test
    func expiredRestDeadlineAdvancesToTheNextSet() throws {
        // Step 0 has 2 sets; persisted state says we're resting after
        // set 0. With a past deadline the restore path should run
        // `advanceAfterRest()` which moves to set 1, phase .exercise.
        let fixture = try Self.makeFixture(stepCount: 2, setsPerStep: 2)
        let pastDeadline = Date().addingTimeInterval(-30)
        Self.persist(
            sessionId: fixture.session.id,
            routineId: fixture.routine.id,
            phase: .rest,
            stepIndex: 0,
            setIndex: 0,
            restDeadline: pastDeadline,
        )

        fixture.viewModel.configure(modelContext: fixture.context)

        #expect(fixture.viewModel.phase == .exercise)
        #expect(fixture.viewModel.restDeadline == nil)
        #expect(fixture.viewModel.currentStepIndex == 0)
        #expect(fixture.viewModel.currentSetIndex == 1)
    }

    @Test
    func expiredRestDeadlineAtLastSetAdvancesToNextStep() throws {
        // setsPerStep = 1, so resting after set 0 of step 0 should
        // jump to step 1 set 0 on stale restore.
        let fixture = try Self.makeFixture(stepCount: 3, setsPerStep: 1)
        Self.persist(
            sessionId: fixture.session.id,
            routineId: fixture.routine.id,
            phase: .rest,
            stepIndex: 0,
            setIndex: 0,
            restDeadline: Date().addingTimeInterval(-10),
        )

        fixture.viewModel.configure(modelContext: fixture.context)

        #expect(fixture.viewModel.phase == .exercise)
        #expect(fixture.viewModel.currentStepIndex == 1)
        #expect(fixture.viewModel.currentSetIndex == 0)
        #expect(fixture.viewModel.restDeadline == nil)
    }

    @Test
    func restorationClearsStateWhenSessionIsMissing() throws {
        let fixture = try Self.makeFixture()
        // Persist a state pointing at a session id that does not
        // exist in the SwiftData store.
        Self.persist(
            sessionId: UUID(),
            routineId: fixture.routine.id,
            phase: .exercise,
            stepIndex: 0,
            setIndex: 0,
            restDeadline: nil,
        )
        #expect(RunnerPersistence.load() != nil)

        fixture.viewModel.configure(modelContext: fixture.context)

        // Restore aborted → state cleared, VM stays idle.
        #expect(RunnerPersistence.load() == nil)
        #expect(fixture.viewModel.sessionId == nil)
        #expect(fixture.viewModel.phase == .done)
    }

    @Test
    func restorationClearsStateWhenRoutineIsMissing() throws {
        let fixture = try Self.makeFixture()
        Self.persist(
            sessionId: fixture.session.id,
            routineId: UUID(), // does not exist
            phase: .exercise,
            stepIndex: 0,
            setIndex: 0,
            restDeadline: nil,
        )

        fixture.viewModel.configure(modelContext: fixture.context)

        #expect(RunnerPersistence.load() == nil)
        #expect(fixture.viewModel.sessionId == nil)
    }

    @Test
    func restorationClearsStateWhenSessionIsNotInProgress() throws {
        let fixture = try Self.makeFixture()
        fixture.session.status = .completed
        try fixture.context.save()

        Self.persist(
            sessionId: fixture.session.id,
            routineId: fixture.routine.id,
            phase: .exercise,
            stepIndex: 0,
            setIndex: 0,
            restDeadline: nil,
        )

        fixture.viewModel.configure(modelContext: fixture.context)

        #expect(RunnerPersistence.load() == nil)
        #expect(fixture.viewModel.sessionId == nil)
    }

    @Test
    func restorationClampsOutOfRangeStepIndex() throws {
        let fixture = try Self.makeFixture(stepCount: 3)
        // stepIndex far beyond routine length — restoration should
        // clamp to `steps.count - 1` rather than crash / leave the
        // VM in an inconsistent state.
        Self.persist(
            sessionId: fixture.session.id,
            routineId: fixture.routine.id,
            phase: .exercise,
            stepIndex: 999,
            setIndex: 0,
            restDeadline: nil,
        )

        fixture.viewModel.configure(modelContext: fixture.context)

        #expect(fixture.viewModel.currentStepIndex == 2)
    }
}
