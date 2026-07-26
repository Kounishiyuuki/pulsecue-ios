//
//  RunnerPresenterTests.swift
//  Pulse CueTests
//
//  Locks the Runner presentation contract at a deterministic level (the
//  SwiftUI cover binding is exercised via `RunnerPresenter`, the same object
//  ContentView binds to). Proves:
//   - a workout becoming active presents the cover; ending it dismisses it,
//   - an active workout can never end up dismissed via the sync path,
//   - explicit resume re-presents an active workout but creates NO Session
//     and never presents an empty Runner.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct RunnerPresenterTests {

    // MARK: - Sync (start / finish)

    @Test func startingWorkoutPresentsCover() {
        let p = RunnerPresenter()
        #expect(p.isRunnerCovered == false)
        p.syncPresentation(isRunning: true)
        #expect(p.isRunnerCovered)
    }

    @Test func finishingWorkoutDismissesCover() {
        let p = RunnerPresenter()
        p.syncPresentation(isRunning: true)
        p.syncPresentation(isRunning: false)
        #expect(p.isRunnerCovered == false)
    }

    @Test func activeWorkoutStaysPresentedAcrossSyncs() {
        // No sequence of "still running" syncs can silently hide an active
        // workout — the cover tracks the domain state exactly.
        let p = RunnerPresenter()
        p.syncPresentation(isRunning: true)
        p.syncPresentation(isRunning: true)
        #expect(p.isRunnerCovered)
    }

    // MARK: - Resume

    @Test func resumeRepresentsActiveWorkout() {
        let p = RunnerPresenter()
        // Simulate cold-launch recovery where the cover isn't showing yet.
        #expect(p.isRunnerCovered == false)
        p.resume(isRunning: true)
        #expect(p.isRunnerCovered)
    }

    @Test func resumeWithoutActiveWorkoutIsNoOp() {
        // Never present an empty Runner.
        let p = RunnerPresenter()
        p.resume(isRunning: false)
        #expect(p.isRunnerCovered == false)
    }

    // MARK: - Resume never starts a Session

    @Test func resumeCreatesNoNewSession() throws {
        RunnerPersistence.clear()
        let schema = Schema([Routine.self, Step.self, Session.self, StepResult.self, DayLog.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let routine = Routine(name: "Resume Test")
        context.insert(routine)
        context.insert(Step(routineId: routine.id, order: 0, title: "S0", sets: 2, repsTarget: 10, restSeconds: 0))
        try context.save()

        let defaults = UserDefaults(suiteName: "test.presenter.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.notificationsEnabled = false
        let vm = RunnerViewModel(settings: settings)
        vm.configure(modelContext: context)

        vm.start(routine: routine)
        let sessionsAfterStart = try context.fetch(FetchDescriptor<Session>()).count
        #expect(sessionsAfterStart == 1)
        #expect(vm.isRunning)

        // Resuming presentation must not create another Session.
        let presenter = RunnerPresenter()
        presenter.resume(isRunning: vm.isRunning)
        #expect(presenter.isRunnerCovered)

        let sessionsAfterResume = try context.fetch(FetchDescriptor<Session>()).count
        #expect(sessionsAfterResume == 1)
    }
}
