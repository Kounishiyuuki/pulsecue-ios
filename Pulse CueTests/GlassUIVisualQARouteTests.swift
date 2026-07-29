#if DEBUG
import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct GlassUIVisualQARouteTests {
    private let argument = "-pulsecue-debug-glass-ui-route"

    @Test func routeIsAbsentWithoutExactArgumentAndValue() {
        #expect(PulseCueUITestSupport.requestedGlassUIRoute([]) == nil)
        #expect(PulseCueUITestSupport.requestedGlassUIRoute([argument]) == nil)
        #expect(PulseCueUITestSupport.requestedGlassUIRoute(["preview-single"]) == nil)
    }

    @Test func everyRepresentativeRouteParsesDeterministically() {
        #expect(Set(GlassUIVisualQARoute.allCases.map(\.rawValue)) == [
            "mygym-active",
            "machine-selection",
            "planner",
            "preview-single",
            "preview-weekly-before-generation",
            "preview-weekly",
            "history-populated",
            "history-detail",
            "runner-active",
            "runner-rest",
            "exercise-library",
            "form-guide",
            "form-guide-instructions-expanded",
            "onboarding",
            "login",
        ])
        for route in GlassUIVisualQARoute.allCases {
            let args = ["Pulse Cue", argument, route.rawValue]
            #expect(PulseCueUITestSupport.requestedGlassUIRoute(args) == route)
            #expect(PulseCueUITestSupport.requestedGlassUIRoute(args) == route)
        }
    }

    @Test func unknownAndEmptyValuesDoNotForkStartup() {
        #expect(PulseCueUITestSupport.requestedGlassUIRoute([argument, ""]) == nil)
        #expect(PulseCueUITestSupport.requestedGlassUIRoute([argument, "unknown"]) == nil)
    }

    @Test func isolatedRouteWinsWithoutCustomMachineOnboardingWrite() {
        let combined = [
            "-pulsecue-ui-test-custom-machine-flow",
            argument,
            GlassUIVisualQARoute.myGymActive.rawValue,
        ]
        #expect(PulseCueUITestSupport.requestedGlassUIRoute(combined) == .myGymActive)
        #expect(!PulseCueUITestSupport.shouldCompleteCustomMachineOnboarding(combined))
        #expect(PulseCueUITestSupport.shouldCompleteCustomMachineOnboarding([
            "-pulsecue-ui-test-custom-machine-flow",
        ]))
    }

    @Test func fixtureUsesRealCatalogEntriesIncludingChestEquipment() {
        let entries = GlassUIVisualQAFixture.machineIDs.compactMap(MachineCatalog.entry(for:))
        #expect(entries.count == GlassUIVisualQAFixture.machineIDs.count)
        #expect(entries.contains { $0.bodyParts.contains(.chest) })
    }

    @Test func historyFixtureHasStableConnectedRecords() throws {
        let schema = Schema(versionedSchema: PulseCueSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        try GlassUIVisualQAFixture.seed(into: context)

        let routines = try context.fetch(FetchDescriptor<Routine>())
        let steps = try context.fetch(FetchDescriptor<Step>())
        let sessions = try context.fetch(FetchDescriptor<Session>())
        let results = try context.fetch(FetchDescriptor<StepResult>())

        #expect(routines.count == 1)
        #expect(steps.count == 3)
        #expect(sessions.count == 3)
        #expect(results.count == 24)
        #expect(sessions.contains { $0.id == GlassUIVisualQAFixture.featuredSessionID })

        let routineIDs = Set(routines.map(\.id))
        let sessionIDs = Set(sessions.map(\.id))
        let stepIDs = Set(steps.map(\.id))
        #expect(steps.allSatisfy { routineIDs.contains($0.routineId) })
        #expect(sessions.allSatisfy { routineIDs.contains($0.routineId) })
        #expect(results.allSatisfy {
            sessionIDs.contains($0.sessionId) && stepIDs.contains($0.stepId)
        })
    }

    @Test func weeklyPreviewFixtureIsGeneratedAndNonEmpty() {
        let candidate = GlassUIVisualQAFixture.weeklyCandidate
        #expect(candidate.daysPerWeek == 3)
        #expect(candidate.sessions.count == 3)
        #expect(!candidate.isEmpty)
    }

    /// Drives a RunnerViewModel exactly like the DEBUG screenshot host so the
    /// runner-active / runner-rest routes are deterministic from the fixture.
    /// Uses only the existing public Runner API (no state-machine change).
    @Test func screenshotRunnerRoutesAreDeterministicFromFixture() throws {
        let schema = Schema(versionedSchema: PulseCueSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        try GlassUIVisualQAFixture.seed(into: context)

        let routineID = GlassUIVisualQAFixture.routineID
        let routine = try #require(
            context.fetch(FetchDescriptor<Routine>(
                predicate: #Predicate { $0.id == routineID }
            )).first
        )

        RunnerPersistence.clear()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.screenshot.runner.\(UUID().uuidString)")!)
        settings.notificationsEnabled = false
        let vm = RunnerViewModel(settings: settings)
        vm.configure(modelContext: context)

        // ACTIVE (exercise phase) — first step, first set, static.
        vm.start(routine: routine)
        #expect(vm.phase == .exercise)
        #expect(vm.isRunning)
        #expect(vm.currentStep?.title == "チェストプレス")
        #expect(vm.currentSetIndex == 0)

        // REST — one Complete enters the rest hero.
        vm.handle(action: .complete)
        #expect(vm.phase == .rest)
        #expect(vm.isRunning)
    }
}
#endif
