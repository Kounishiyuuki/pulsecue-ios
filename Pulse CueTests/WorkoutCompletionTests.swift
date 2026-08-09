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
        #expect(abs(summary.duration - endedAt.timeIntervalSince(session.startedAt)) < 0.001)
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
