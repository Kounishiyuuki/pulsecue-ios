//
//  StepExerciseIdMutationTests.swift
//  Pulse CueTests
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct StepExerciseIdMutationTests {

    private func makeStep(exerciseId: String?) -> Step {
        Step(
            id: UUID(uuidString: "81000000-0000-0000-0000-000000000001")!,
            routineId: UUID(uuidString: "82000000-0000-0000-0000-000000000001")!,
            order: 2,
            title: "チェストプレス",
            sets: 4,
            repsTarget: 8,
            restSeconds: 120,
            note: "胸の張りを保つ",
            isWarmup: false,
            exerciseId: exerciseId
        )
    }

    @Test(arguments: [
        "machine_chest_press",
        "future_exercise_v99"
    ])
    func duplicationPreservesKnownAndUnknownRawIdentity(rawId: String) {
        let source = makeStep(exerciseId: rawId)
        let destinationRoutineId = UUID()

        let duplicate = source.duplicated(
            id: UUID(),
            routineId: destinationRoutineId,
            order: 3
        )

        #expect(duplicate.exerciseId == rawId)
        #expect(duplicate.title == source.title)
        #expect(duplicate.sets == source.sets)
        #expect(duplicate.repsTarget == source.repsTarget)
        #expect(duplicate.restSeconds == source.restSeconds)
        #expect(duplicate.note == source.note)
        #expect(duplicate.isWarmup == source.isWarmup)
        #expect(duplicate.routineId == destinationRoutineId)
        #expect(duplicate.order == 3)
        if rawId == "future_exercise_v99" {
            #expect(duplicate.resolvedExercise == nil)
        }
    }

    @Test
    func duplicationPreservesNilIdentity() {
        let duplicate = makeStep(exerciseId: nil).duplicated()
        #expect(duplicate.exerciseId == nil)
    }

    @Test(arguments: [
        "machine_chest_press",
        "future_exercise_v99"
    ])
    func manualRenameInvalidatesKnownAndUnknownIdentity(rawId: String) {
        let step = makeStep(exerciseId: rawId)

        step.rename(to: "別の種目")

        #expect(step.title == "別の種目")
        #expect(step.exerciseId == nil)
    }

    @Test
    func assigningSameTitlePreservesIdentity() {
        let step = makeStep(exerciseId: "machine_chest_press")

        step.rename(to: "チェストプレス")

        #expect(step.title == "チェストプレス")
        #expect(step.exerciseId == "machine_chest_press")
    }

    @Test
    func nonTitleEditsPreserveIdentity() {
        let step = makeStep(exerciseId: "machine_chest_press")

        step.sets = 5
        step.repsTarget = 6
        step.restSeconds = 150
        step.note = "重量を上げる"
        step.order = 4

        #expect(step.exerciseId == "machine_chest_press")
    }

    @Test
    func migratedNilIdentityCanBeRenamedNormally() {
        let step = makeStep(exerciseId: nil)

        step.rename(to: "移行後の種目名")

        #expect(step.title == "移行後の種目名")
        #expect(step.exerciseId == nil)
    }
}
