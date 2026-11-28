//
//  RunnerNotificationSchedulingTests.swift
//  Pulse CueTests
//
//  Verifies Runner notification ownership and stale-callback protection
//  without touching UNUserNotificationCenter.
//

import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import Pulse_Cue

@MainActor
private final class RunnerNotificationManagerSpy: RunnerNotificationManaging {
    enum Event: Equatable {
        case authorizationRequested
        case removed(identifier: String)
        case scheduled(identifier: String, deadline: Date)
    }

    typealias AuthorizationCompletion = (UNAuthorizationStatus) -> Void

    private(set) var events: [Event] = []
    private(set) var activeRequests: [String: Date] = [:]
    private var authorizationCompletions: [AuthorizationCompletion] = []
    private var scheduleCompletions: [() -> Void] = []

    var pendingAuthorizationCount: Int {
        authorizationCompletions.count
    }

    var pendingScheduleCompletionCount: Int {
        scheduleCompletions.count
    }

    func getAuthorizationStatus(completion: @escaping AuthorizationCompletion) {
        events.append(.authorizationRequested)
        authorizationCompletions.append(completion)
    }

    func scheduleRestNotification(
        deadline: Date,
        identifier: String,
        completion: @escaping () -> Void
    ) {
        events.append(.scheduled(identifier: identifier, deadline: deadline))
        activeRequests[identifier] = deadline
        scheduleCompletions.append(completion)
    }

    func removeNotification(identifier: String) {
        events.append(.removed(identifier: identifier))
        activeRequests.removeValue(forKey: identifier)
    }

    func resolveAuthorization(
        at index: Int = 0,
        with status: UNAuthorizationStatus = .authorized
    ) {
        let completion = authorizationCompletions.remove(at: index)
        completion(status)
    }

    func resolveScheduleCompletion(at index: Int = 0) {
        let completion = scheduleCompletions.remove(at: index)
        completion()
    }

    func clearEvents() {
        events.removeAll()
    }
}

@Suite(.serialized)
@MainActor
struct RunnerNotificationSchedulingTests {
    private struct Fixture {
        let viewModel: RunnerViewModel
        let routine: Routine
        let spy: RunnerNotificationManagerSpy
        let context: ModelContext
    }

    private static func makeFixture(
        restSeconds: Int = 60,
        stepCount: Int = 1,
        setsPerStep: Int = 3,
        notificationManager: (any RunnerNotificationManaging)? = nil
    ) throws -> Fixture {
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

        let routine = Routine(name: "Notification Test Routine")
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

        let defaults = UserDefaults(suiteName: "test.runner.notification.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.notificationsEnabled = true
        settings.soundEnabled = false
        settings.hapticsEnabled = false

        let spy = RunnerNotificationManagerSpy()
        let viewModel = RunnerViewModel(settings: settings, notificationManager: notificationManager ?? spy)
        viewModel.configure(modelContext: context)
        viewModel.start(routine: routine)

        return Fixture(viewModel: viewModel, routine: routine, spy: spy, context: context)
    }

    private static func flushMainActorTasks() async {
        await Task.yield()
        await Task.yield()
    }

    private static func complete(_ viewModel: RunnerViewModel) throws {
        let context = try #require(viewModel.completeContext)
        viewModel.handle(action: .complete, context: context)
    }

    private static func scheduledEvents(in events: [RunnerNotificationManagerSpy.Event]) -> [(String, Date)] {
        events.compactMap { event in
            guard case let .scheduled(identifier, deadline) = event else { return nil }
            return (identifier, deadline)
        }
    }

    private static func removedIdentifiers(in events: [RunnerNotificationManagerSpy.Event]) -> [String] {
        events.compactMap { event in
            guard case let .removed(identifier) = event else { return nil }
            return identifier
        }
    }

    @Test
    func enteringRestSchedulesTheSessionScopedNotificationAfterAuthorization() async throws {
        let fx = try Self.makeFixture()
        fx.spy.clearEvents()

        try Self.complete(fx.viewModel)

        #expect(fx.spy.pendingAuthorizationCount == 1)
        #expect(Self.scheduledEvents(in: fx.spy.events).isEmpty)
        fx.spy.resolveAuthorization()
        await Self.flushMainActorTasks()

        let sessionId = try #require(fx.viewModel.sessionId)
        let expectedIdentifier = "rest.\(sessionId.uuidString)"
        let scheduled = try #require(Self.scheduledEvents(in: fx.spy.events).last)
        #expect(scheduled.0 == expectedIdentifier)
        #expect(abs(scheduled.1.timeIntervalSince(try #require(fx.viewModel.restDeadline))) < 0.01)
        #expect(fx.spy.activeRequests.count == 1)
        #expect(fx.spy.activeRequests[expectedIdentifier] != nil)
    }

    @Test
    func doubleCompleteSchedulesOnlyOneRestNotification() async throws {
        let fx = try Self.makeFixture(setsPerStep: 2)
        fx.spy.clearEvents()
        let context = try #require(fx.viewModel.completeContext)

        let first = Task { @MainActor in
            fx.viewModel.handle(action: .complete, context: context)
        }
        let second = Task { @MainActor in
            fx.viewModel.handle(action: .complete, context: context)
        }
        await first.value
        await second.value

        #expect(fx.viewModel.phase == .rest)
        #expect(fx.viewModel.currentSetIndex == 0)
        #expect(fx.spy.pendingAuthorizationCount == 1)
        fx.spy.resolveAuthorization()
        await Self.flushMainActorTasks()

        #expect(Self.scheduledEvents(in: fx.spy.events).count == 1)
        #expect(fx.spy.activeRequests.count == 1)
    }

    @Test
    func plusFifteenCancelsThenReschedulesAtTheExtendedDeadline() async throws {
        let fx = try Self.makeFixture()
        try Self.complete(fx.viewModel)
        fx.spy.resolveAuthorization()
        await Self.flushMainActorTasks()
        let originalDeadline = try #require(fx.viewModel.restDeadline)
        fx.spy.clearEvents()

        fx.viewModel.handle(action: .extend)

        let extendedDeadline = try #require(fx.viewModel.restDeadline)
        #expect(abs(extendedDeadline.timeIntervalSince(originalDeadline) - 15) < 0.1)
        #expect(Self.removedIdentifiers(in: fx.spy.events).count == 1)
        #expect(Self.scheduledEvents(in: fx.spy.events).isEmpty)
        fx.spy.resolveAuthorization()
        await Self.flushMainActorTasks()

        let events = fx.spy.events
        let removeIndex = try #require(events.firstIndex {
            if case .removed = $0 { return true }
            return false
        })
        let scheduleIndex = try #require(events.firstIndex {
            if case .scheduled = $0 { return true }
            return false
        })
        #expect(removeIndex < scheduleIndex)
        #expect(abs(try #require(Self.scheduledEvents(in: events).last).1.timeIntervalSince(extendedDeadline)) < 0.01)
        #expect(fx.spy.activeRequests.count == 1)
    }

    @Test
    func minusFifteenCancelsThenReschedulesAtTheShortenedDeadline() async throws {
        let fx = try Self.makeFixture()
        try Self.complete(fx.viewModel)
        fx.spy.resolveAuthorization()
        await Self.flushMainActorTasks()
        let originalDeadline = try #require(fx.viewModel.restDeadline)
        fx.spy.clearEvents()

        fx.viewModel.shortenRest()

        let shortenedDeadline = try #require(fx.viewModel.restDeadline)
        #expect(abs(shortenedDeadline.timeIntervalSince(originalDeadline) + 15) < 0.1)
        #expect(Self.removedIdentifiers(in: fx.spy.events).count == 1)
        fx.spy.resolveAuthorization()
        await Self.flushMainActorTasks()

        let scheduled = try #require(Self.scheduledEvents(in: fx.spy.events).last)
        #expect(abs(scheduled.1.timeIntervalSince(shortenedDeadline)) < 0.01)
        #expect(fx.spy.activeRequests.count == 1)
    }

    @Test
    func repeatedAdjustmentsAllowOnlyTheLatestAuthorizationCallbackToSchedule() async throws {
        let fx = try Self.makeFixture()
        try Self.complete(fx.viewModel)
        fx.viewModel.handle(action: .extend)
        fx.viewModel.shortenRest()
        fx.viewModel.handle(action: .extend)
        let latestDeadline = try #require(fx.viewModel.restDeadline)
        #expect(fx.spy.pendingAuthorizationCount == 4)

        while fx.spy.pendingAuthorizationCount > 1 {
            fx.spy.resolveAuthorization(at: 0)
            await Self.flushMainActorTasks()
        }
        #expect(Self.scheduledEvents(in: fx.spy.events).isEmpty)

        fx.spy.resolveAuthorization()
        await Self.flushMainActorTasks()

        let scheduled = Self.scheduledEvents(in: fx.spy.events)
        #expect(scheduled.count == 1)
        #expect(abs(try #require(scheduled.first).1.timeIntervalSince(latestDeadline)) < 0.01)
        #expect(fx.spy.activeRequests.count == 1)
    }

    @Test
    func finishingRestCancelsTheActiveNotification() async throws {
        let fx = try Self.makeFixture()
        try Self.complete(fx.viewModel)
        fx.spy.resolveAuthorization()
        await Self.flushMainActorTasks()
        #expect(fx.spy.activeRequests.count == 1)
        fx.spy.clearEvents()

        try Self.complete(fx.viewModel)

        #expect(fx.viewModel.phase == .exercise)
        #expect(fx.spy.activeRequests.isEmpty)
        #expect(Self.removedIdentifiers(in: fx.spy.events).count == 1)
        #expect(Self.scheduledEvents(in: fx.spy.events).isEmpty)
    }

    @Test
    func endingSessionDuringRestCancelsTheActiveNotification() async throws {
        let fx = try Self.makeFixture()
        try Self.complete(fx.viewModel)
        fx.spy.resolveAuthorization()
        await Self.flushMainActorTasks()
        fx.spy.clearEvents()

        fx.viewModel.endSessionEarly()

        #expect(fx.viewModel.phase == .done)
        #expect(fx.spy.activeRequests.isEmpty)
        #expect(!Self.removedIdentifiers(in: fx.spy.events).isEmpty)
        #expect(Self.scheduledEvents(in: fx.spy.events).isEmpty)
    }

    @Test
    func skippingRestCancelsTheActiveNotification() async throws {
        let fx = try Self.makeFixture(stepCount: 2)
        try Self.complete(fx.viewModel)
        fx.spy.resolveAuthorization()
        await Self.flushMainActorTasks()
        fx.spy.clearEvents()

        fx.viewModel.handle(action: .skip)

        #expect(fx.viewModel.phase == .exercise)
        #expect(fx.viewModel.currentStepIndex == 1)
        #expect(fx.spy.activeRequests.isEmpty)
        #expect(Self.removedIdentifiers(in: fx.spy.events).count == 1)
        #expect(Self.scheduledEvents(in: fx.spy.events).isEmpty)
    }

    @Test
    func shorteningToZeroCancelsWithoutRescheduling() async throws {
        let fx = try Self.makeFixture(restSeconds: 5)
        try Self.complete(fx.viewModel)
        fx.spy.resolveAuthorization()
        await Self.flushMainActorTasks()
        fx.spy.clearEvents()

        fx.viewModel.shortenRest()

        #expect(fx.viewModel.phase == .exercise)
        #expect(fx.viewModel.restDeadline == nil)
        #expect(fx.spy.activeRequests.isEmpty)
        #expect(Self.removedIdentifiers(in: fx.spy.events).count == 1)
        #expect(Self.scheduledEvents(in: fx.spy.events).isEmpty)
    }

    @Test
    func staleAuthorizationCallbackCannotScheduleOverANewerRest() async throws {
        let fx = try Self.makeFixture(setsPerStep: 3)
        try Self.complete(fx.viewModel)
        #expect(fx.spy.pendingAuthorizationCount == 1)
        try Self.complete(fx.viewModel)
        try Self.complete(fx.viewModel)
        #expect(fx.viewModel.phase == .rest)
        #expect(fx.viewModel.currentSetIndex == 1)
        #expect(fx.spy.pendingAuthorizationCount == 2)
        let newestDeadline = try #require(fx.viewModel.restDeadline)

        fx.spy.resolveAuthorization(at: 0)
        await Self.flushMainActorTasks()
        #expect(Self.scheduledEvents(in: fx.spy.events).isEmpty)

        fx.spy.resolveAuthorization()
        await Self.flushMainActorTasks()

        let scheduled = Self.scheduledEvents(in: fx.spy.events)
        #expect(scheduled.count == 1)
        #expect(abs(try #require(scheduled.first).1.timeIntervalSince(newestDeadline)) < 0.01)
        #expect(fx.spy.activeRequests.count == 1)
    }

    @Test
    func staleAttentionAuthorizationCannotMutateANewSession() async throws {
        let fx = try Self.makeFixture(restSeconds: 5, setsPerStep: 2)
        try Self.complete(fx.viewModel)
        fx.spy.resolveAuthorization()
        await Self.flushMainActorTasks()

        fx.viewModel.shortenRest()
        #expect(fx.viewModel.phase == .exercise)
        #expect(fx.spy.pendingAuthorizationCount == 1)

        fx.viewModel.start(routine: fx.routine)
        #expect(fx.viewModel.phase == .exercise)
        #expect(!fx.viewModel.needsAttention)

        fx.spy.resolveAuthorization(with: .denied)
        await Self.flushMainActorTasks()

        #expect(!fx.viewModel.needsAttention)
    }

    @Test
    func staleScheduleCompletionCannotCancelANewerRestNotification() async throws {
        let fx = try Self.makeFixture(setsPerStep: 3)
        try Self.complete(fx.viewModel)
        fx.spy.resolveAuthorization()
        await Self.flushMainActorTasks()
        #expect(fx.spy.pendingScheduleCompletionCount == 1)

        try Self.complete(fx.viewModel)
        try Self.complete(fx.viewModel)
        fx.spy.resolveAuthorization()
        await Self.flushMainActorTasks()
        let newestDeadline = try #require(fx.viewModel.restDeadline)
        #expect(fx.spy.pendingScheduleCompletionCount == 2)
        #expect(fx.spy.activeRequests.count == 1)

        fx.spy.resolveScheduleCompletion(at: 0)
        await Self.flushMainActorTasks()

        #expect(fx.spy.activeRequests.isEmpty)
        #expect(fx.spy.pendingAuthorizationCount == 1)
        fx.spy.resolveAuthorization()
        await Self.flushMainActorTasks()

        #expect(fx.spy.activeRequests.count == 1)
        #expect(abs(try #require(fx.spy.activeRequests.values.first).timeIntervalSince(newestDeadline)) < 0.01)
    }

    @Test
    func foregroundWithFutureDeadlineCancelsThenReschedulesLatestNotification() async throws {
        let fx = try Self.makeFixture()
        try Self.complete(fx.viewModel)
        fx.spy.resolveAuthorization()
        await Self.flushMainActorTasks()
        fx.spy.clearEvents()

        fx.viewModel.appDidBecomeActive()

        #expect(Self.removedIdentifiers(in: fx.spy.events).count == 1)
        #expect(fx.spy.pendingAuthorizationCount == 1)
        fx.spy.resolveAuthorization()
        await Self.flushMainActorTasks()

        #expect(Self.scheduledEvents(in: fx.spy.events).count == 1)
        #expect(fx.spy.activeRequests.count == 1)
    }

    @Test
    func foregroundWithExpiredDeadlineCancelsWithoutRescheduling() throws {
        let fx = try Self.makeFixture(restSeconds: 1)
        try Self.complete(fx.viewModel)
        // Keep the main actor blocked so the timer cannot consume the expiry
        // before appDidBecomeActive exercises its foreground reconciliation.
        Thread.sleep(forTimeInterval: 1.05)
        fx.spy.clearEvents()

        fx.viewModel.appDidBecomeActive()

        #expect(fx.viewModel.phase == .exercise)
        #expect(fx.viewModel.restDeadline == nil)
        #expect(fx.spy.activeRequests.isEmpty)
        #expect(Self.removedIdentifiers(in: fx.spy.events).count == 1)
        #expect(Self.scheduledEvents(in: fx.spy.events).isEmpty)
    }

    // MARK: - With the production NotificationManager (#272)

    /// Lets the Runner's and the manager's main-actor hops run.
    private static func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    private static func runnerIdentifier(_ fx: Fixture) throws -> String {
        "rest.\(try #require(fx.viewModel.sessionId).uuidString)"
    }

    /// The Runner's deadlines carry fractions of a second; a trigger holds
    /// whole seconds, truncated.
    private static func isTrigger(_ date: Date?, for deadline: Date?) -> Bool {
        guard let date, let deadline else { return false }
        let gap = deadline.timeIntervalSince(date)
        return gap >= 0 && gap < 1
    }

    @Test
    func runnerAdjustmentsAnsweredNewestFirstLeaveOnlyTheFinalDeadline() async throws {
        let center = ControlledNotificationCenter()
        let fx = try Self.makeFixture(restSeconds: 120, notificationManager: NotificationManager(center: center))
        try Self.complete(fx.viewModel)
        await Self.settle()
        fx.viewModel.handle(action: .extend)
        await Self.settle()
        fx.viewModel.handle(action: .extend)
        await Self.settle()
        fx.viewModel.shortenRest()
        await Self.settle()
        #expect(center.held.count == 4)
        while !center.held.isEmpty {
            center.complete(center.held.count - 1)
            await Self.settle()
        }
        let id = try Self.runnerIdentifier(fx)
        #expect(center.pending.count == 1)
        #expect(Self.isTrigger(center.pendingDate(id), for: fx.viewModel.restDeadline))
    }

    @Test
    func runnerRestEndedWhileItsAddIsInFlightLeavesNothing() async throws {
        let center = ControlledNotificationCenter()
        let fx = try Self.makeFixture(notificationManager: NotificationManager(center: center))
        try Self.complete(fx.viewModel)
        await Self.settle()
        #expect(center.held.count == 1)
        try Self.complete(fx.viewModel)                                    // 休憩終了
        #expect(fx.viewModel.phase == .exercise)
        while !center.held.isEmpty {
            center.complete(0)
            await Self.settle()
        }
        #expect(center.pending.isEmpty)
    }

    @Test
    func runnersNextRestKeepsItsNotificationWhenThePreviousAddAnswersLate() async throws {
        let center = ControlledNotificationCenter()
        let fx = try Self.makeFixture(notificationManager: NotificationManager(center: center))
        try Self.complete(fx.viewModel)                                    // rest 1
        await Self.settle()
        try Self.complete(fx.viewModel)                                    // 休憩終了
        try Self.complete(fx.viewModel)                                    // rest 2
        await Self.settle()
        #expect(fx.viewModel.phase == .rest)
        center.complete(center.held.count - 1)                             // rest 2's add
        await Self.settle()
        center.complete(0)                                                 // rest 1's, late
        await Self.settle()
        while !center.held.isEmpty {
            center.complete(0)
            await Self.settle()
        }
        let id = try Self.runnerIdentifier(fx)
        #expect(center.pending.count == 1)
        #expect(Self.isTrigger(center.pendingDate(id), for: fx.viewModel.restDeadline))
    }

    @Test
    func runnerAndFreeWorkoutNeverTakeEachOthersNotification() async throws {
        let center = ControlledNotificationCenter()
        let manager = NotificationManager(center: center)
        let fx = try Self.makeFixture(notificationManager: manager)
        let store = RestTimerStore(notifications: manager, notificationsEnabled: { true }, now: Date.init,
                                   lifecycle: NotificationCenter(), initiallyActive: true, expiryFeedback: {},
                                   scheduleExpiry: { _, _ in })
        let free = UUID()
        try Self.complete(fx.viewModel)
        let token = try #require(store.start(sessionId: free, ownerAccountID: nil, grant: nil, seconds: 120))
        await Self.settle()
        while !center.held.isEmpty {
            center.complete(0)
            await Self.settle()
        }
        let runner = try Self.runnerIdentifier(fx)
        let freeId = RestTimerStore.notificationIdentifier(for: free)
        #expect(Set(center.pending.keys) == [runner, freeId])
        #expect(store.finish(sessionId: free, token: token))               // Free Workout's end
        #expect(Set(center.pending.keys) == [runner])
        _ = try #require(store.start(sessionId: free, ownerAccountID: nil, grant: nil, seconds: 120))
        await Self.settle()
        center.complete(0)
        await Self.settle()
        try Self.complete(fx.viewModel)                                    // the Runner's end
        #expect(Set(center.pending.keys) == [freeId])
        manager.removeAllPending()                                         // Settings off: all, by design
        #expect(center.pending.isEmpty)
    }
}
