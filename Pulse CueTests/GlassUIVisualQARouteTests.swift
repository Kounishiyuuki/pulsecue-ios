#if DEBUG
import Testing
@testable import Pulse_Cue

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
}
#endif
