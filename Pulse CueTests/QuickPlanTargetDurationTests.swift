//
//  QuickPlanTargetDurationTests.swift
//  Pulse CueTests
//
//  Quick Plan's 30 / 45 / 60 / 90 used to pick a fixed exercise count, so
//  every bucket landed at roughly 60% of the time the user asked for
//  (measured: 30→21分, 45→27分, 60→34分). Sizing now runs on
//  `WorkoutDurationEstimator`, the same judge the preview displays.
//
//  These lock the contract: never overshoot the ceiling, reach the floor
//  whenever the gym has the equipment for it, and degrade to a constrained
//  best effort when it does not.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct QuickPlanTargetDurationTests {

    // MARK: - Fixtures

    private static func makeGym() throws -> (Gym, ModelContext) {
        let schema = Schema(versionedSchema: PulseCueSchemaV5.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let gym = Gym(name: "Target Gym", officialUrl: nil, isActive: true)
        context.insert(gym)
        return (gym, context)
    }

    private static func equipment(_ ids: [String], on gym: Gym) -> [AvailableEquipment] {
        ids.map {
            AvailableEquipment(machine: GymMachine(
                gymId: gym.id, machineId: $0, displayName: $0, isAvailable: true
            ))
        }
    }

    /// Everything in the catalog, so candidate supply is never the limiting
    /// factor for the "well equipped" expectations.
    private static func fullyEquipped(on gym: Gym) -> [AvailableEquipment] {
        equipment(MachineCatalog.all.map(\.id), on: gym)
    }

    private static let allParts: [BodyPart] = [.chest, .back, .legs, .shoulders, .arms]

    private static func request(
        _ parts: [BodyPart],
        _ duration: QuickPlanDuration,
        _ intensity: QuickPlanIntensity = .standard
    ) -> QuickPlanRequest {
        QuickPlanRequest(bodyParts: parts, duration: duration, intensity: intensity)
    }

    private static func minutes(_ plan: GeneratedPlan) -> Int {
        WorkoutDurationEstimator.minutes(forPlan: plan.exercises)
    }

    // MARK: - The target is honoured

    @Test
    func everyTargetLandsInRangeWhenTheGymIsWellEquipped() throws {
        let (gym, _) = try Self.makeGym()
        let equipment = Self.fullyEquipped(on: gym)

        for duration in QuickPlanDuration.allCases {
            let plan = WorkoutPlanGenerator.generate(
                request: Self.request(Self.allParts, duration),
                gym: gym, availableEquipment: equipment
            )
            let actual = Self.minutes(plan)
            #expect(
                actual >= duration.lowerBoundMinutes && actual <= duration.upperBoundMinutes,
                "target \(duration.minutes) produced \(actual) (allowed \(duration.lowerBoundMinutes)...\(duration.upperBoundMinutes))"
            )
        }
    }

    /// The ceiling is absolute: a plan may never run well past the time the
    /// user chose, whatever the intensity or the equipment.
    @Test
    func aPlanNeverOvershootsItsTarget() throws {
        let (gym, _) = try Self.makeGym()
        let equipment = Self.fullyEquipped(on: gym)

        for duration in QuickPlanDuration.allCases {
            for intensity in QuickPlanIntensity.allCases {
                let plan = WorkoutPlanGenerator.generate(
                    request: Self.request(Self.allParts, duration, intensity),
                    gym: gym, availableEquipment: equipment
                )
                let actual = Self.minutes(plan)
                #expect(
                    actual <= duration.upperBoundMinutes,
                    "target \(duration.minutes)/\(intensity.rawValue) produced \(actual)"
                )
            }
        }
    }

    /// Longer request ⇒ never a shorter plan.
    @Test
    func longerTargetsProduceLongerPlans() throws {
        let (gym, _) = try Self.makeGym()
        let equipment = Self.fullyEquipped(on: gym)
        let durations = QuickPlanDuration.allCases.sorted { $0.minutes < $1.minutes }

        var previous = 0
        for duration in durations {
            let plan = WorkoutPlanGenerator.generate(
                request: Self.request(Self.allParts, duration),
                gym: gym, availableEquipment: equipment
            )
            let actual = Self.minutes(plan)
            #expect(actual >= previous, "\(duration.minutes) gave \(actual) after \(previous)")
            previous = actual
        }
    }

    /// The regression this PR exists for: a fixed count left every bucket far
    /// short of the requested time.
    @Test
    func targetsAreNoLongerSystematicallyShort() throws {
        let (gym, _) = try Self.makeGym()
        let equipment = Self.fullyEquipped(on: gym)
        // Previously: 30→21, 45→27, 60→34.
        for (duration, oldShortfall) in [
            (QuickPlanDuration.compact, 21),
            (QuickPlanDuration.standard, 27),
            (QuickPlanDuration.standardPlus, 34),
        ] {
            let plan = WorkoutPlanGenerator.generate(
                request: Self.request(Self.allParts, duration),
                gym: gym, availableEquipment: equipment
            )
            #expect(Self.minutes(plan) > oldShortfall)
        }
    }

    // MARK: - Constraints are preserved

    @Test
    func sizingNeverBreaksEquipmentOrDuplicationRules() throws {
        let (gym, _) = try Self.makeGym()
        let ids = ["bench_press", "chest_press", "pec_deck", "lat_pulldown", "seated_row"]
        let plan = WorkoutPlanGenerator.generate(
            request: Self.request([.chest, .back], .extended),
            gym: gym, availableEquipment: Self.equipment(ids, on: gym)
        )
        let used = plan.exercises.map(\.machineId)
        #expect(used.allSatisfy(ids.contains), "plan used equipment the gym does not have")
        #expect(Set(used).count == used.count, "the same machine appeared twice")
        #expect(Set(plan.exercises.map(\.exerciseName)).count == plan.exercises.count)
    }

    @Test
    func intensityStillShapesThePrescription() throws {
        let (gym, _) = try Self.makeGym()
        let equipment = Self.fullyEquipped(on: gym)
        let light = WorkoutPlanGenerator.generate(
            request: Self.request(Self.allParts, .standardPlus, .light),
            gym: gym, availableEquipment: equipment
        )
        let hard = WorkoutPlanGenerator.generate(
            request: Self.request(Self.allParts, .standardPlus, .hard),
            gym: gym, availableEquipment: equipment
        )
        // A harder session packs more work per exercise, so filling the same
        // window takes fewer of them.
        #expect(hard.exercises.count < light.exercises.count)
        #expect(Self.minutes(hard) <= QuickPlanDuration.standardPlus.upperBoundMinutes)
        #expect(Self.minutes(light) <= QuickPlanDuration.standardPlus.upperBoundMinutes)
    }

    // MARK: - Best effort when candidates run out

    @Test
    func aSparseGymReturnsItsBestEffortAndWarns() throws {
        let (gym, _) = try Self.makeGym()
        let plan = WorkoutPlanGenerator.generate(
            request: Self.request([.chest], .extended),
            gym: gym, availableEquipment: Self.equipment(["chest_press"], on: gym)
        )
        #expect(plan.exercises.count == 1)
        #expect(plan.exercises.first?.machineId == "chest_press")
        #expect(Self.minutes(plan) < QuickPlanDuration.extended.lowerBoundMinutes)
        #expect(!plan.warnings.isEmpty, "a short plan must say why")
    }

    @Test
    func anEmptyGymStillProducesNoPlanAndWarns() throws {
        let (gym, _) = try Self.makeGym()
        let plan = WorkoutPlanGenerator.generate(
            request: Self.request([.chest], .standardPlus),
            gym: gym, availableEquipment: []
        )
        #expect(plan.exercises.isEmpty)
        #expect(!plan.warnings.isEmpty)
    }

    /// A well-equipped gym that reaches its target must not carry the
    /// "not enough machines" warning.
    @Test
    func aFilledTargetDoesNotWarn() throws {
        let (gym, _) = try Self.makeGym()
        let plan = WorkoutPlanGenerator.generate(
            request: Self.request(Self.allParts, .standardPlus),
            gym: gym, availableEquipment: Self.fullyEquipped(on: gym)
        )
        #expect(plan.warnings.isEmpty, "\(plan.warnings)")
    }

    // MARK: - Sizing helper

    @Test
    func sizingTerminatesAndIsBounded() {
        // Degenerate inputs must not loop or over-read.
        #expect(WorkoutPlanGenerator.exerciseCount(fitting: .compact, from: []) == 0)

        let one = [GeneratedExercise(
            machineId: "m", exerciseName: "e", sets: 10, reps: 20, restSeconds: 300, cue: ""
        )]
        // Even a single exercise that blows past the ceiling is still returned.
        #expect(WorkoutPlanGenerator.exerciseCount(fitting: .compact, from: one) == 1)
    }

    @Test
    func generationStaysDeterministic() throws {
        let (gym, _) = try Self.makeGym()
        let equipment = Self.fullyEquipped(on: gym)
        let first = WorkoutPlanGenerator.generate(
            request: Self.request(Self.allParts, .standardPlus),
            gym: gym, availableEquipment: equipment
        )
        let second = WorkoutPlanGenerator.generate(
            request: Self.request(Self.allParts, .standardPlus),
            gym: gym, availableEquipment: equipment
        )
        #expect(first.exercises == second.exercises)
    }

    // MARK: - Duration-based movements count for their real length

    @Test
    func aDurationBasedExerciseConsumesItsRealTime() throws {
        let (gym, _) = try Self.makeGym()
        // Treadmill is a 10-minute warm-up (PR #163), not 10 reps.
        let withCardio = WorkoutPlanGenerator.generate(
            request: Self.request([.fullBody, .legs], .compact),
            gym: gym, availableEquipment: Self.fullyEquipped(on: gym)
        )
        #expect(Self.minutes(withCardio) <= QuickPlanDuration.compact.upperBoundMinutes)

        if let treadmill = withCardio.exercises.first(where: { $0.exerciseId?.rawValue == "treadmill_warmup" }) {
            let solo = WorkoutDurationEstimator.minutes(forPlan: [treadmill])
            #expect(solo >= 10, "treadmill counted as \(solo) minutes")
        }
    }

    // MARK: - No side effects on the other generators

    @Test
    func theSingleBodyPartGeneratorIsUnaffected() throws {
        let (gym, _) = try Self.makeGym()
        let plan = WorkoutPlanGenerator.generate(
            bodyPart: .chest, gym: gym, availableEquipment: Self.fullyEquipped(on: gym)
        )
        // It has no duration request at all, so it is not bound by any target.
        #expect(!plan.exercises.isEmpty)
        #expect(Set(plan.exercises.map(\.machineId)).count == plan.exercises.count)
    }
}
