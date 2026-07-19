//
//  WorkoutPlanGeneratorTests.swift
//  Pulse CueTests
//
//  Unit tests for the pure v0 plan generator. Each scenario uses a
//  freshly-built in-memory Gym + Machine fixture to avoid touching
//  on-disk SwiftData state.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct WorkoutPlanGeneratorTests {

    private static func makeContext() throws -> ModelContext {
        let schema = Schema([Routine.self, Step.self, Gym.self, GymMachine.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private static func makeGym(_ name: String = "Test Gym", in context: ModelContext) -> Gym {
        let gym = Gym(name: name, isActive: true)
        context.insert(gym)
        return gym
    }

    private static func machine(_ id: String, on gym: Gym) -> GymMachine {
        GymMachine(
            gymId: gym.id,
            machineId: id,
            displayName: MachineCatalog.entry(for: id)?.displayName ?? id
        )
    }

    @Test
    func emptyMachinesYieldsEmptyPlanWithWarning() throws {
        let context = try Self.makeContext()
        let gym = Self.makeGym(in: context)
        let plan = WorkoutPlanGenerator.generate(
            bodyPart: .chest,
            gym: gym,
            availableMachines: []
        )
        #expect(plan.isEmpty)
        #expect(plan.warnings.count == 1)
    }

    @Test
    func chestWithAllMachinesYieldsClampedNonEmptyPlan() throws {
        let context = try Self.makeContext()
        let gym = Self.makeGym(in: context)
        let available = [
            "bench_press", "chest_press", "dumbbells",
            "pec_deck", "cable_machine", "smith_machine",
        ].map { Self.machine($0, on: gym) }

        let plan = WorkoutPlanGenerator.generate(
            bodyPart: .chest,
            gym: gym,
            availableMachines: available
        )

        #expect(!plan.isEmpty)
        #expect(plan.exercises.count <= WorkoutPlanGenerator.maxExercises)
        // No warning when the plan is full-sized.
        #expect(plan.warnings.isEmpty)
        // Bench press is the priority entry for chest.
        #expect(plan.exercises.first?.machineId == "bench_press")
    }

    @Test
    func bodyPartWithNoMatchingMachinesYieldsWarning() throws {
        let context = try Self.makeContext()
        let gym = Self.makeGym(in: context)
        // Treadmill alone does not train back.
        let available = [Self.machine("treadmill", on: gym)]
        let plan = WorkoutPlanGenerator.generate(
            bodyPart: .back,
            gym: gym,
            availableMachines: available
        )
        #expect(plan.isEmpty)
        #expect(plan.warnings.count == 1)
    }

    @Test
    func sparseMatchYieldsShortPlanWithWarning() throws {
        let context = try Self.makeContext()
        let gym = Self.makeGym(in: context)
        // Only one back-machine present → plan exists but is short.
        let available = [Self.machine("lat_pulldown", on: gym)]
        let plan = WorkoutPlanGenerator.generate(
            bodyPart: .back,
            gym: gym,
            availableMachines: available
        )
        #expect(plan.exercises.count == 1)
        #expect(plan.warnings.count == 1)
        #expect(plan.exercises.first?.machineId == "lat_pulldown")
    }

    @Test
    func defaultTitleIncludesBodyPartAndGymName() throws {
        let context = try Self.makeContext()
        let gym = Self.makeGym("Athletic Plus", in: context)
        let plan = WorkoutPlanGenerator.generate(
            bodyPart: .legs,
            gym: gym,
            availableMachines: [Self.machine("leg_press", on: gym)]
        )
        #expect(plan.defaultTitle.contains("脚"))
        #expect(plan.defaultTitle.contains("Athletic Plus"))
    }

    // MARK: - Catalog / template integrity

    @Test
    func everyTemplateMachineIdExistsInCatalog() {
        let catalogIds = Set(MachineCatalog.all.map(\.id))
        let unknown = WorkoutPlanGenerator.allTemplateMachineIds.subtracting(catalogIds)
        #expect(unknown.isEmpty, "templates reference ids missing from the catalog: \(unknown.sorted())")
    }

    /// The 12 machines added in the 1.0 catalog expansion, with the primary
    /// body part their single-workout template lives under.
    private static let newMachinePrimaryBodyPart: [(id: String, part: BodyPart)] = [
        ("abdominal_machine", .core),
        ("arm_curl_machine", .arms),
        ("assisted_pull_up", .back),
        ("barbell", .chest),
        ("calf_raise", .legs),
        ("hack_squat", .legs),
        ("hip_abduction", .legs),
        ("incline_chest_press", .chest),
        ("lateral_raise_machine", .shoulders),
        ("rear_delt_fly", .shoulders),
        ("rowing_machine", .fullBody),
        ("triceps_extension_machine", .arms),
    ]

    @Test
    func everyNewMachineHasASingleWorkoutTemplate() {
        let templated = WorkoutPlanGenerator.allTemplateMachineIds
        for new in Self.newMachinePrimaryBodyPart {
            #expect(templated.contains(new.id), "new machine \(new.id) has no single-workout template")
        }
    }

    @Test
    func eachNewMachineAloneProducesItInSingleWorkoutPlan() throws {
        // A machine that is selectable in My Gym must be usable by the
        // single-workout planner: owning only that machine yields a plan
        // that contains it.
        let context = try Self.makeContext()
        let gym = Self.makeGym(in: context)
        for new in Self.newMachinePrimaryBodyPart {
            let plan = WorkoutPlanGenerator.generate(
                bodyPart: new.part,
                gym: gym,
                availableMachines: [Self.machine(new.id, on: gym)]
            )
            #expect(plan.exercises.contains { $0.machineId == new.id },
                    "\(new.id) did not appear in a \(new.part.rawValue) plan")
        }
    }
}
