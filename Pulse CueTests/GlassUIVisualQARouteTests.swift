#if DEBUG
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
            "preview-weekly",
            "history-populated",
            "history-detail",
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
}
#endif
