//
//  ExercisePlannerIntegrationTests.swift
//  Pulse CueTests
//
//  Verifies that both planners now carry stable exercise identity while
//  preserving their existing behavior, and — importantly — that custom
//  machines never auto-resolve to a known exercise. Uses pure
//  `AvailableEquipment` values for custom cases so no string-similarity or
//  SwiftData path can accidentally infer an identity.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct ExercisePlannerIntegrationTests {

    private static func makeGym() throws -> Gym {
        let schema = Schema([Routine.self, Step.self, Gym.self, GymMachine.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let gym = Gym(name: "テストジム", isActive: true)
        context.insert(gym)
        return gym
    }

    private static func standard(_ id: String, available: Bool = true) -> AvailableEquipment {
        AvailableEquipment(entry: MachineCatalog.entry(for: id)!, isAvailable: available)
    }

    /// A pure custom equipment value — no SwiftData, no catalog entry.
    private static func custom(
        _ name: String,
        bodyParts: Set<BodyPart>,
        available: Bool = true
    ) -> AvailableEquipment {
        AvailableEquipment(
            id: "custom_\(UUID().uuidString.lowercased())",
            displayName: name,
            bodyParts: bodyParts,
            equipmentType: .machine,
            source: .custom,
            beginnerFriendly: nil,
            isAvailable: available,
            catalogEntry: nil,
            customMachineId: UUID()
        )
    }

    // MARK: - Single planner

    @Test func everyCuratedTemplateCarriesAValidLibraryId() {
        for ref in WorkoutPlanGenerator.allTemplateExerciseRefs {
            #expect(ExerciseLibrary.isValid(ref.exerciseId), "template \(ref.exerciseName) → invalid id \(ref.exerciseId)")
            // The authored template name must match the library display name
            // so the guide/identity and the saved title stay consistent.
            #expect(
                ExerciseLibrary.exercise(for: ref.exerciseId)?.displayName == ref.exerciseName,
                "name mismatch for \(ref.exerciseId): template=\(ref.exerciseName)"
            )
        }
    }

    @Test func standardExerciseCarriesIdAndKeepsPrescription() throws {
        let gym = try Self.makeGym()
        let plan = WorkoutPlanGenerator.generate(
            bodyPart: .chest,
            gym: gym,
            availableEquipment: [Self.standard("chest_press")]
        )
        let chestPress = try #require(plan.exercises.first { $0.exerciseName == "チェストプレス" })
        #expect(chestPress.exerciseId == "machine_chest_press")
        // Prescription unchanged from the original curated template.
        #expect(chestPress.sets == 3)
        #expect(chestPress.reps == 10)
        #expect(chestPress.restSeconds == 90)
        #expect(chestPress.cue == "肘は無理に伸ばし切らず胸の張りを保つ")
    }

    @Test func customFallbackHasNilExerciseIdInSinglePlanner() throws {
        let gym = try Self.makeGym()
        let plan = WorkoutPlanGenerator.generate(
            bodyPart: .legs,
            gym: gym,
            availableEquipment: [Self.custom("旧型レッグマシン", bodyParts: [.legs])]
        )
        let customEx = try #require(plan.exercises.first { $0.exerciseName == "旧型レッグマシン" })
        #expect(customEx.exerciseId == nil)
    }

    @Test func customNameEqualToKnownExerciseNeverResolves() throws {
        let gym = try Self.makeGym()
        // A custom machine literally named like a standard movement must NOT
        // pick up that movement's stable id — no name inference, ever.
        let plan = WorkoutPlanGenerator.generate(
            bodyPart: .legs,
            gym: gym,
            availableEquipment: [Self.custom("レッグプレス", bodyParts: [.legs])]
        )
        let customEx = try #require(plan.exercises.first { $0.exerciseName == "レッグプレス" })
        #expect(customEx.exerciseId == nil)
    }

    @Test func unavailableCustomExcludedFromSinglePlanner() throws {
        let gym = try Self.makeGym()
        let plan = WorkoutPlanGenerator.generate(
            bodyPart: .legs,
            gym: gym,
            availableEquipment: [Self.custom("使わないマシン", bodyParts: [.legs], available: false)]
        )
        #expect(!plan.exercises.contains { $0.exerciseName == "使わないマシン" })
    }

    // MARK: - Weekly planner

    private static func weekly(_ equipment: [AvailableEquipment], focus: BodyPart) -> WeeklyTrainingPlanCandidate {
        let request = TrainingPlanGenerationRequest(
            daysPerWeek: 1,
            targetBodyParts: [focus],
            preferredSplit: .fullBody
        )
        return RuleBasedWeeklyPlanGenerator.generate(request: request, equipment: equipment)
    }

    private static func allCandidates(_ plan: WeeklyTrainingPlanCandidate) -> [RoutineStepCandidate] {
        plan.sessions.flatMap(\.exercises)
    }

    @Test func weeklyResolvesRealMovementNotMachineName() {
        let plan = Self.weekly([Self.standard("cable_machine")], focus: .back)
        let names = Self.allCandidates(plan).map(\.exerciseName)
        // The known machine yields a real movement name, not "ケーブルマシン".
        #expect(names.contains("ケーブルロー"))
        #expect(!names.contains("ケーブルマシン"))
        let cable = Self.allCandidates(plan).first { $0.exerciseName == "ケーブルロー" }
        #expect(cable?.exerciseId == "cable_row")
    }

    @Test func weeklyMultiPurposeEquipmentResolvesByBodyPart() {
        let legs = Self.allCandidates(Self.weekly([Self.standard("barbell")], focus: .legs))
        let chest = Self.allCandidates(Self.weekly([Self.standard("barbell")], focus: .chest))
        #expect(legs.first?.exerciseId == "barbell_back_squat")
        #expect(chest.first?.exerciseId == "barbell_bench_press")
    }

    @Test func weeklyCustomFallbackStaysNilAndKeepsName() {
        let plan = Self.weekly([Self.custom("自作プレス機", bodyParts: [.chest])], focus: .chest)
        let candidate = Self.allCandidates(plan).first { $0.exerciseName == "自作プレス機" }
        #expect(candidate != nil)
        #expect(candidate?.exerciseId == nil)
    }

    @Test func weeklyCustomNameWithAliasNeverResolves() {
        // Even an English alias spelling must not resolve a custom machine.
        let plan = Self.weekly([Self.custom("lat pulldown", bodyParts: [.back])], focus: .back)
        let candidate = Self.allCandidates(plan).first { $0.exerciseName == "lat pulldown" }
        #expect(candidate != nil)
        #expect(candidate?.exerciseId == nil)
    }

    @Test func weeklyWithNoEquipmentProducesNoExercises() {
        let plan = Self.weekly([], focus: .chest)
        #expect(Self.allCandidates(plan).isEmpty)
    }

    // MARK: - Persistence boundary

    @Test func generationPersistsNothing() throws {
        let schema = Schema([Routine.self, Step.self, Gym.self, GymMachine.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let gym = Gym(name: "テストジム", isActive: true)
        context.insert(gym)
        try context.save()

        _ = WorkoutPlanGenerator.generate(
            bodyPart: .chest,
            gym: gym,
            availableEquipment: [Self.standard("chest_press")]
        )
        _ = Self.weekly([Self.standard("cable_machine")], focus: .back)

        let routines = try context.fetch(FetchDescriptor<Routine>())
        let steps = try context.fetch(FetchDescriptor<Step>())
        #expect(routines.isEmpty)
        #expect(steps.isEmpty)
    }
}
