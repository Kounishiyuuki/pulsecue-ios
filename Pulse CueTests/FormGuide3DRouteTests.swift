//
//  FormGuide3DRouteTests.swift
//  Pulse CueTests
//
//  Pure launch-mode selection tests for the DEBUG-only deterministic Form
//  Guide route. These prove the route logic is pure (returns values, no
//  side effects), handles unknown ids safely, and that its predicate — the
//  single fork the app uses under `#if DEBUG` — is correct. The route's
//  in-memory container / seeder-bypass / no-onboarding-write behavior is
//  driven entirely by `isFormGuideDebugRoute`, tested here, plus the
//  compile-time `#if DEBUG` gating in `Pulse_CueApp`.
//

import Foundation
import Testing
@testable import Pulse_Cue

struct FormGuide3DRouteTests {

    private let arg = "-pulsecue-ui-test-form-guide-3d"
    private let idArg = "-pulsecue-ui-test-exercise-id"
    private let progArg = "-pulsecue-ui-test-progress"

    @Test func routeAbsentWithoutArgument() {
        #expect(PulseCueUITestSupport.requestedFormGuideExerciseId([]) == nil)
        #expect(!PulseCueUITestSupport.isFormGuideDebugRoute([]))
        #expect(PulseCueUITestSupport.requestedFormGuideProgress([]) == nil)
    }

    @Test func routeDefaultsToChestPress() {
        #expect(PulseCueUITestSupport.requestedFormGuideExerciseId([arg]) == "machine_chest_press")
        #expect(PulseCueUITestSupport.isFormGuideDebugRoute([arg]))
    }

    @Test func routeSelectsExplicitExerciseId() {
        let args = [arg, idArg, "leg_press"]
        #expect(PulseCueUITestSupport.requestedFormGuideExerciseId(args) == "leg_press")
    }

    @Test func unknownIdPassesThroughAndResolvesSafely() {
        let args = [arg, idArg, "bogus_exercise_x"]
        let id = PulseCueUITestSupport.requestedFormGuideExerciseId(args)
        #expect(id == "bogus_exercise_x")
        // Safe: an unknown id simply has no exercise/guide — no crash, the
        // guide screen shows its unavailable state.
        let typed = ExerciseID(rawValue: id!)
        #expect(ExerciseLibrary.exercise(for: typed) == nil)
        #expect(FormGuideLibrary.guide(for: typed) == nil)
    }

    @Test func progressParsedAndClamped() {
        #expect(PulseCueUITestSupport.requestedFormGuideProgress([arg, progArg, "0.5"]) == 0.5)
        #expect(PulseCueUITestSupport.requestedFormGuideProgress([arg, progArg, "2.0"]) == 1.0)
        #expect(PulseCueUITestSupport.requestedFormGuideProgress([arg, progArg, "-1"]) == 0.0)
        // Progress requires the route argument.
        #expect(PulseCueUITestSupport.requestedFormGuideProgress([progArg, "0.5"]) == nil)
    }

    @Test func launchModeSelectionIsPureAndRepeatable() {
        let args = [arg, idArg, "lat_pulldown"]
        // Calling repeatedly yields the same result and does not depend on or
        // mutate any external state.
        for _ in 0..<5 {
            #expect(PulseCueUITestSupport.requestedFormGuideExerciseId(args) == "lat_pulldown")
        }
    }
}
