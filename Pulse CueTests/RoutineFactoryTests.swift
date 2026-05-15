//
//  RoutineFactoryTests.swift
//  Pulse CueTests
//
//  Verifies the adapter from `GeneratedPlan` to existing `Routine` /
//  `Step` records is faithful: step order matches plan order, the
//  foreign-key linkage uses the new routine's id, and `Step.init`
//  clamping rules are not bypassed.
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct RoutineFactoryTests {

    private static func makePlan(exerciseCount: Int = 3, restSeconds: Int = 90) -> GeneratedPlan {
        GeneratedPlan(
            bodyPart: .chest,
            gymId: UUID(),
            gymName: "Test Gym",
            exercises: (0..<exerciseCount).map { i in
                GeneratedExercise(
                    machineId: "bench_press",
                    exerciseName: "種目\(i)",
                    sets: 3,
                    reps: 10,
                    restSeconds: restSeconds,
                    cue: "キュー\(i)"
                )
            },
            warnings: []
        )
    }

    @Test
    func stepsAreOrderedToMatchPlan() {
        let plan = Self.makePlan(exerciseCount: 4)
        let output = RoutineFactory.makeRoutine(from: plan)
        #expect(output.steps.count == 4)
        let orders = output.steps.map(\.order)
        #expect(orders == [0, 1, 2, 3])
        // Step titles should appear in plan order.
        let titles = output.steps.map(\.title)
        #expect(titles == ["種目0", "種目1", "種目2", "種目3"])
    }

    @Test
    func stepsReferenceTheGeneratedRoutineId() {
        let plan = Self.makePlan()
        let output = RoutineFactory.makeRoutine(from: plan)
        for step in output.steps {
            #expect(step.routineId == output.routine.id)
        }
    }

    @Test
    func routineNameUsesPlanDefaultTitle() {
        let plan = Self.makePlan()
        let output = RoutineFactory.makeRoutine(from: plan)
        #expect(output.routine.name == plan.defaultTitle)
    }

    @Test
    func restSecondsAreClampedByStepInit() {
        // 9999 is far above Step.clampRest's 600 ceiling.
        let plan = Self.makePlan(exerciseCount: 1, restSeconds: 9999)
        let output = RoutineFactory.makeRoutine(from: plan)
        #expect(output.steps.first?.restSeconds == 600)
    }

    @Test
    func cuesAreCopiedIntoStepNote() {
        let plan = Self.makePlan(exerciseCount: 2)
        let output = RoutineFactory.makeRoutine(from: plan)
        #expect(output.steps[0].note == "キュー0")
        #expect(output.steps[1].note == "キュー1")
    }
}
