//
//  StepExerciseIdSaveBoundaryTests.swift
//  Pulse CueTests
//
//  Proves the explicit-save boundary for the new persisted `Step.exerciseId`:
//  planners/factory produce the field only when a routine is explicitly
//  built, known standard exercises persist their stable id, custom/unresolved
//  persist nil, and an invalid transient id is dropped rather than persisted
//  as a bogus known reference. In-memory containers are fine here — on-disk
//  migration correctness is proven separately in StepExerciseIdMigrationTests.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct StepExerciseIdSaveBoundaryTests {

    private static func makeContext() throws -> ModelContext {
        let schema = Schema([Routine.self, Step.self, Gym.self, GymMachine.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private static func makeGym(in context: ModelContext) -> Gym {
        let gym = Gym(name: "テストジム", isActive: true)
        context.insert(gym)
        return gym
    }

    private static func standard(_ id: String) -> AvailableEquipment {
        AvailableEquipment(entry: MachineCatalog.entry(for: id)!)
    }

    private static func custom(_ name: String, bodyParts: Set<BodyPart>) -> AvailableEquipment {
        AvailableEquipment(
            id: "custom_\(UUID().uuidString.lowercased())", displayName: name,
            bodyParts: bodyParts, equipmentType: .machine, source: .custom,
            beginnerFriendly: nil, isAvailable: true, catalogEntry: nil, customMachineId: UUID()
        )
    }

    // MARK: - Factory purity (no persistence until explicit insert)

    @Test func factoryProducesValuesWithoutInserting() throws {
        let context = try Self.makeContext()
        let gym = Self.makeGym(in: context)
        let plan = WorkoutPlanGenerator.generate(
            bodyPart: .chest, gym: gym, availableEquipment: [Self.standard("chest_press")]
        )
        // Build the routine graph but DO NOT insert it.
        _ = RoutineFactory.makeRoutine(from: plan)
        let steps = try context.fetch(FetchDescriptor<Step>())
        let routines = try context.fetch(FetchDescriptor<Routine>())
        #expect(steps.isEmpty)
        #expect(routines.isEmpty)
    }

    // MARK: - Single planner save propagation

    private static func savedSteps(from plan: GeneratedPlan, in context: ModelContext) throws -> [Step] {
        let output = RoutineFactory.makeRoutine(from: plan)
        context.insert(output.routine)
        output.steps.forEach(context.insert)
        try context.save()
        return try context.fetch(FetchDescriptor<Step>(sortBy: [SortDescriptor(\.order)]))
    }

    @Test func singleKnownExercisesPersistTheirIds() throws {
        let context = try Self.makeContext()
        let gym = Self.makeGym(in: context)

        let chest = WorkoutPlanGenerator.generate(
            bodyPart: .chest, gym: gym, availableEquipment: [Self.standard("chest_press")]
        )
        let steps = try Self.savedSteps(from: chest, in: context)
        let chestStep = try #require(steps.first { $0.title == "チェストプレス" })
        #expect(chestStep.exerciseId == "machine_chest_press")
        #expect(chestStep.resolvedExercise?.id == "machine_chest_press")
    }

    @Test func singleLegPressPersistsId() throws {
        let context = try Self.makeContext()
        let gym = Self.makeGym(in: context)
        let plan = WorkoutPlanGenerator.generate(
            bodyPart: .legs, gym: gym, availableEquipment: [Self.standard("leg_press")]
        )
        let steps = try Self.savedSteps(from: plan, in: context)
        #expect(steps.first { $0.title == "レッグプレス" }?.exerciseId == "leg_press")
    }

    @Test func singleBarbellLegsPersistsSquatIdNotGenericBarbell() throws {
        let context = try Self.makeContext()
        let gym = Self.makeGym(in: context)
        let plan = WorkoutPlanGenerator.generate(
            bodyPart: .legs, gym: gym, availableEquipment: [Self.standard("barbell")]
        )
        let steps = try Self.savedSteps(from: plan, in: context)
        let squat = try #require(steps.first { $0.exerciseId == "barbell_back_squat" })
        #expect(squat.title == "バーベルスクワット")
        #expect(squat.resolvedExercise?.primaryBodyPart == .legs)
    }

    @Test func singleCustomPersistsNil() throws {
        let context = try Self.makeContext()
        let gym = Self.makeGym(in: context)
        let plan = WorkoutPlanGenerator.generate(
            bodyPart: .legs, gym: gym, availableEquipment: [Self.custom("自作脚マシン", bodyParts: [.legs])]
        )
        let steps = try Self.savedSteps(from: plan, in: context)
        let customStep = try #require(steps.first { $0.title == "自作脚マシン" })
        #expect(customStep.exerciseId == nil)
    }

    @Test func mixedRoutineKeepsKnownIdAndCustomNil() throws {
        let context = try Self.makeContext()
        let gym = Self.makeGym(in: context)
        let plan = WorkoutPlanGenerator.generate(
            bodyPart: .legs, gym: gym,
            availableEquipment: [Self.standard("leg_press"), Self.custom("自作脚マシン", bodyParts: [.legs])]
        )
        let steps = try Self.savedSteps(from: plan, in: context)
        #expect(steps.first { $0.title == "レッグプレス" }?.exerciseId == "leg_press")
        #expect(steps.first { $0.title == "自作脚マシン" }?.exerciseId == nil)
    }

    // MARK: - Invalid transient id is not persisted as a known reference

    @Test func invalidTransientIdPersistsNil() throws {
        let context = try Self.makeContext()
        // A generated exercise carrying a bogus id must NOT persist it.
        let bogus = GeneratedExercise(
            machineId: "chest_press", exerciseName: "チェストプレス",
            sets: 3, reps: 10, restSeconds: 90, cue: "",
            exerciseId: ExerciseID("not_a_real_library_id")
        )
        let plan = GeneratedPlan(
            bodyPart: .chest, gymId: UUID(), gymName: "G", exercises: [bogus], warnings: []
        )
        let steps = try Self.savedSteps(from: plan, in: context)
        #expect(steps.first?.title == "チェストプレス")   // title unchanged
        #expect(steps.first?.exerciseId == nil)          // bogus id dropped
    }

    // MARK: - Weekly planner save propagation

    private static func weeklySteps(
        _ equipment: [AvailableEquipment], focus: BodyPart, in context: ModelContext
    ) throws -> [Step] {
        let request = TrainingPlanGenerationRequest(
            daysPerWeek: 1, targetBodyParts: [focus], preferredSplit: .fullBody
        )
        let candidate = RuleBasedWeeklyPlanGenerator.generate(request: request, equipment: equipment)
        let outputs = RoutineFactory.makeRoutines(from: candidate)
        for output in outputs {
            context.insert(output.routine)
            output.steps.forEach(context.insert)
        }
        try context.save()
        return try context.fetch(FetchDescriptor<Step>())
    }

    @Test func weeklyKnownMovementPersistsId() throws {
        let context = try Self.makeContext()
        let steps = try Self.weeklySteps([Self.standard("cable_machine")], focus: .back, in: context)
        let cable = try #require(steps.first { $0.title == "ケーブルロー" })
        #expect(cable.exerciseId == "cable_row")
    }

    @Test func weeklyBarbellLegsPersistsSquatId() throws {
        let context = try Self.makeContext()
        let steps = try Self.weeklySteps([Self.standard("barbell")], focus: .legs, in: context)
        // barbell used for legs → persisted Step identifies the squat, not
        // generic barbell.
        let squat = try #require(steps.first { $0.exerciseId == "barbell_back_squat" })
        #expect(squat.title == "バーベルスクワット")
    }

    @Test func weeklyCustomFallbackPersistsNil() throws {
        let context = try Self.makeContext()
        let steps = try Self.weeklySteps([Self.custom("自作胸マシン", bodyParts: [.chest])], focus: .chest, in: context)
        let customStep = try #require(steps.first { $0.title == "自作胸マシン" })
        #expect(customStep.exerciseId == nil)
    }
}
