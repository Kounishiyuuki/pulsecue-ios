//
//  RunnerFormGuideTests.swift
//  Pulse CueTests
//
//  Proves the Runner (and Form Guide) gating relies ONLY on the persisted
//  `Step.exerciseId` → library resolution, never on titles, and that
//  resolving a guide is a pure read that mutates no Step state. The Runner
//  「フォームを見る」button uses exactly `Step.hasResolvableGuide` +
//  `Step.typedExerciseId`, which are exercised here.
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct RunnerFormGuideTests {

    private func step(exerciseId: String?, title: String = "種目") -> Step {
        Step(routineId: UUID(), order: 0, title: title, sets: 3, repsTarget: 10,
             restSeconds: 60, exerciseId: exerciseId)
    }

    @Test func knownIdWithGuideExposesGuide() {
        let s = step(exerciseId: "machine_chest_press")
        #expect(s.resolvedExercise?.id == "machine_chest_press")
        #expect(s.resolvedGuide != nil)
        #expect(s.hasResolvableGuide)
        #expect(s.typedExerciseId == "machine_chest_press")
    }

    @Test func knownIdWithoutGuideHasNoGuideAction() {
        // barbell_bench_press is a real exercise with no MVP guide.
        let s = step(exerciseId: "barbell_bench_press")
        #expect(s.resolvedExercise != nil)
        #expect(s.resolvedGuide == nil)
        #expect(!s.hasResolvableGuide)
    }

    @Test func nilIdHasNoGuideAction() {
        let s = step(exerciseId: nil, title: "レッグプレス")
        #expect(s.resolvedExercise == nil)
        #expect(!s.hasResolvableGuide)
        #expect(s.typedExerciseId == nil)
    }

    @Test func unknownRawIdHasNoGuideAction() {
        let s = step(exerciseId: "future_unknown_v9")
        #expect(s.resolvedExercise == nil)
        #expect(!s.hasResolvableGuide)
        // Raw value is still readable (forward-compatible), just unresolved.
        #expect(s.exerciseId == "future_unknown_v9")
    }

    @Test func titleNeverInfersAGuide() {
        // A custom-style step titled exactly like a guided exercise, but with
        // no persisted id, must NOT resolve a guide.
        let s = step(exerciseId: nil, title: "チェストプレス")
        #expect(!s.hasResolvableGuide)
    }

    @Test func resolvingGuideDoesNotMutateStep() {
        let s = step(exerciseId: "machine_chest_press", title: "チェストプレス")
        _ = s.resolvedExercise
        _ = s.resolvedGuide
        _ = s.hasResolvableGuide
        // Observational: nothing changed.
        #expect(s.title == "チェストプレス")
        #expect(s.exerciseId == "machine_chest_press")
        #expect(s.sets == 3)
        #expect(s.repsTarget == 10)
        #expect(s.restSeconds == 60)
    }
}
