//
//  WorkoutIntelligenceQuickPlanTests.swift
//  Pulse CueTests
//
//  Unit tests for the Quick Plan path of the pure workout plan generator:
//  multi-body-part coverage, duration → exercise count, intensity → per
//  strength-exercise sets/rest, determinism, machine dedup, available-only
//  filtering, custom-machine compatibility, and empty states. All fixtures
//  are in-memory; no on-disk SwiftData state is touched.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct WorkoutIntelligenceQuickPlanTests {

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

    private static func equipment(_ id: String, on gym: Gym) -> AvailableEquipment {
        AvailableEquipment(machine: GymMachine(
            gymId: gym.id,
            machineId: id,
            displayName: MachineCatalog.entry(for: id)?.displayName ?? id
        ))
    }

    /// A broad chest+back+arms set so Quick Plan has room to fill any duration.
    private static func richEquipment(on gym: Gym) -> [AvailableEquipment] {
        [
            "bench_press", "chest_press", "pec_deck", "incline_chest_press",
            "lat_pulldown", "seated_row", "cable_machine", "back_extension",
            "dumbbells", "arm_curl_machine", "triceps_extension_machine",
        ].map { equipment($0, on: gym) }
    }

    private static func request(
        _ parts: [BodyPart],
        _ duration: QuickPlanDuration = .standardPlus,
        _ intensity: QuickPlanIntensity = .standard
    ) -> QuickPlanRequest {
        QuickPlanRequest(bodyParts: parts, duration: duration, intensity: intensity)
    }

    // MARK: - Coverage / body parts

    @Test
    func quickPlanCoversSelectedBodyParts() throws {
        let context = try Self.makeContext()
        let gym = Self.makeGym(in: context)
        let plan = WorkoutPlanGenerator.generate(
            request: Self.request([.chest, .back], .extended),
            gym: gym,
            availableEquipment: Self.richEquipment(on: gym)
        )
        #expect(!plan.isEmpty)
        #expect(plan.bodyParts == [.chest, .back])
        // Round-robin means both parts are represented near the top.
        let topMachines = plan.exercises.prefix(2).map(\.machineId)
        #expect(topMachines.contains("bench_press"))   // chest priority #1
        #expect(topMachines.contains("lat_pulldown"))  // back priority #1
    }

    // MARK: - Available-only filtering

    @Test
    func unavailableEquipmentNeverEntersQuickPlan() throws {
        let context = try Self.makeContext()
        let gym = Self.makeGym(in: context)
        // bench_press marked unavailable; chest_press available.
        let benchUnavailable = AvailableEquipment(
            entry: MachineCatalog.entry(for: "bench_press")!,
            isAvailable: false
        )
        let equipment = [benchUnavailable, Self.equipment("chest_press", on: gym)]
        let plan = WorkoutPlanGenerator.generate(
            request: Self.request([.chest], .standardPlus),
            gym: gym,
            availableEquipment: equipment
        )
        #expect(!plan.exercises.contains { $0.machineId == "bench_press" })
        #expect(plan.exercises.contains { $0.machineId == "chest_press" })
    }

    // MARK: - Active gym

    @Test
    func quickPlanReflectsActiveGymIdentity() throws {
        let context = try Self.makeContext()
        let gym = Self.makeGym("Downtown", in: context)
        let plan = WorkoutPlanGenerator.generate(
            request: Self.request([.legs]),
            gym: gym,
            availableEquipment: [Self.equipment("leg_press", on: gym)]
        )
        #expect(plan.gymId == gym.id)
        #expect(plan.gymName == "Downtown")
        #expect(plan.defaultTitle.contains("Downtown"))
    }

    // MARK: - Duration

    /// Duration is a time goal, not an exercise count: the plan is sized so
    /// its estimate approaches the chosen minutes without passing the
    /// ceiling. A longer request therefore still yields a longer plan, but
    /// the count itself is an outcome rather than the contract.
    @Test
    func durationControlsPlanLength() throws {
        let context = try Self.makeContext()
        let gym = Self.makeGym(in: context)
        let equipment = Self.richEquipment(on: gym)
        let compact = WorkoutPlanGenerator.generate(
            request: Self.request([.chest, .back], .compact),
            gym: gym, availableEquipment: equipment
        )
        let extended = WorkoutPlanGenerator.generate(
            request: Self.request([.chest, .back], .extended),
            gym: gym, availableEquipment: equipment
        )
        let compactMinutes = WorkoutDurationEstimator.minutes(forPlan: compact.exercises)
        let extendedMinutes = WorkoutDurationEstimator.minutes(forPlan: extended.exercises)

        #expect(compactMinutes <= QuickPlanDuration.compact.upperBoundMinutes)
        #expect(extendedMinutes <= QuickPlanDuration.extended.upperBoundMinutes)
        #expect(extendedMinutes > compactMinutes)
        #expect(extended.exercises.count > compact.exercises.count)
    }

    // MARK: - Determinism

    @Test
    func quickPlanIsDeterministic() throws {
        let context = try Self.makeContext()
        let gym = Self.makeGym(in: context)
        let equipment = Self.richEquipment(on: gym)
        let a = WorkoutPlanGenerator.generate(
            request: Self.request([.chest, .arms], .standardPlus, .hard),
            gym: gym, availableEquipment: equipment
        )
        let b = WorkoutPlanGenerator.generate(
            request: Self.request([.chest, .arms], .standardPlus, .hard),
            gym: gym, availableEquipment: equipment
        )
        #expect(a == b)
    }

    // MARK: - Dedup across parts

    @Test
    func sharedMachineAppearsOnceAcrossParts() throws {
        let context = try Self.makeContext()
        let gym = Self.makeGym(in: context)
        // chest and arms both reference bench_press / cable_machine / dumbbells.
        let equipment = ["bench_press", "cable_machine", "dumbbells", "pec_deck", "arm_curl_machine"]
            .map { Self.equipment($0, on: gym) }
        let plan = WorkoutPlanGenerator.generate(
            request: Self.request([.chest, .arms], .extended),
            gym: gym, availableEquipment: equipment
        )
        let ids = plan.exercises.map(\.machineId)
        #expect(Set(ids).count == ids.count) // no machine used twice
    }

    // MARK: - Empty state

    @Test
    func emptyEquipmentYieldsEmptyQuickPlanWithWarning() throws {
        let context = try Self.makeContext()
        let gym = Self.makeGym(in: context)
        let plan = WorkoutPlanGenerator.generate(
            request: Self.request([.chest, .back]),
            gym: gym, availableEquipment: []
        )
        #expect(plan.isEmpty)
        #expect(!plan.warnings.isEmpty)
    }

    // MARK: - Custom equipment

    @Test
    func customMachineEntersQuickPlan() throws {
        let context = try Self.makeContext()
        let gym = Self.makeGym(in: context)
        let custom = AvailableEquipment(
            id: "custom_test",
            displayName: "自作チェストマシン",
            bodyParts: [.chest],
            source: .custom,
            isAvailable: true
        )
        let plan = WorkoutPlanGenerator.generate(
            request: Self.request([.chest], .compact),
            gym: gym, availableEquipment: [custom]
        )
        #expect(plan.exercises.contains { $0.machineId == "custom_test" })
    }

    // MARK: - Intensity

    @Test
    func hardIntensityAddsSetAndRestToStrengthExercise() throws {
        let context = try Self.makeContext()
        let gym = Self.makeGym(in: context)
        let equipment = [Self.equipment("bench_press", on: gym)]
        let standard = WorkoutPlanGenerator.generate(
            request: Self.request([.chest], .compact, .standard),
            gym: gym, availableEquipment: equipment
        ).exercises.first { $0.machineId == "bench_press" }!
        let hard = WorkoutPlanGenerator.generate(
            request: Self.request([.chest], .compact, .hard),
            gym: gym, availableEquipment: equipment
        ).exercises.first { $0.machineId == "bench_press" }!
        #expect(hard.sets == standard.sets + 1)
        #expect(hard.restSeconds == standard.restSeconds + 15)
        #expect(hard.reps == standard.reps) // reps never rewritten
    }

    @Test
    func lightIntensityRemovesSetAndRestButClampsFloors() throws {
        let context = try Self.makeContext()
        let gym = Self.makeGym(in: context)
        let equipment = [Self.equipment("bench_press", on: gym)]
        let light = WorkoutPlanGenerator.generate(
            request: Self.request([.chest], .compact, .light),
            gym: gym, availableEquipment: equipment
        ).exercises.first { $0.machineId == "bench_press" }!
        // bench_press standard = 4 sets / 120s rest → light = 3 / 105.
        #expect(light.sets == 3)
        #expect(light.restSeconds == 105)
        #expect(light.sets >= 1)
        #expect(light.restSeconds >= 30)
    }

    @Test
    func intensityLeavesCardioWarmupUntouched() throws {
        let context = try Self.makeContext()
        let gym = Self.makeGym(in: context)
        // fullBody template includes treadmill warm-up (rest 0, 1 set).
        let equipment = [Self.equipment("treadmill", on: gym)]
        let hard = WorkoutPlanGenerator.generate(
            request: Self.request([.fullBody], .compact, .hard),
            gym: gym, availableEquipment: equipment
        ).exercises.first { $0.machineId == "treadmill" }
        #expect(hard != nil)
        #expect(hard?.sets == 1)          // not bumped to 2
        #expect(hard?.restSeconds == 0)   // still no rest
    }
}
