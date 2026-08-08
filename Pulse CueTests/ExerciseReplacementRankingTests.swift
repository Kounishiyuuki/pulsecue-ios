//
//  ExerciseReplacementRankingTests.swift
//  Pulse CueTests
//
//  Unit tests for the pure replacement-candidate ranking on
//  `WorkoutPlanGenerator.alternatives`: same-body-part pool, available-only,
//  original excluded, workout-duplicate excluded, movement-pattern priority,
//  determinism, custom-machine inclusion, and the no-alternative case. All
//  fixtures are in-memory value types; no SwiftData / catalog mutation.
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct ExerciseReplacementRankingTests {

    /// Standard equipment straight from the bundled catalog entry.
    private static func standard(_ id: String, available: Bool = true) -> AvailableEquipment {
        AvailableEquipment(entry: MachineCatalog.entry(for: id)!, isAvailable: available)
    }

    /// Every standard chest machine, all available.
    private static func chestEquipment() -> [AvailableEquipment] {
        ["bench_press", "chest_press", "pec_deck", "incline_chest_press",
         "cable_machine", "dumbbells", "smith_machine"].map { standard($0) }
    }

    private func alternatives(
        to machineId: String,
        parts: Set<BodyPart> = [.chest],
        equipment: [AvailableEquipment],
        excluding: Set<String> = []
    ) -> [GeneratedExercise] {
        WorkoutPlanGenerator.alternatives(
            toMachineId: machineId,
            bodyParts: parts,
            usableEquipment: equipment,
            excludingMachineIds: excluding
        )
    }

    // MARK: - Filters

    @Test
    func originalMachineIsNeverSuggested() {
        let result = alternatives(to: "bench_press", equipment: Self.chestEquipment())
        #expect(!result.contains { $0.machineId == "bench_press" })
        #expect(!result.isEmpty)
    }

    @Test
    func unavailableEquipmentIsExcluded() {
        var equipment = Self.chestEquipment()
        // Mark chest_press unavailable.
        equipment = equipment.map { $0.id == "chest_press" ? AvailableEquipment(entry: MachineCatalog.entry(for: "chest_press")!, isAvailable: false) : $0 }
        let result = alternatives(to: "bench_press", equipment: equipment)
        #expect(!result.contains { $0.machineId == "chest_press" })
    }

    @Test
    func candidatesAllTrainRequestedBodyPart() {
        let result = alternatives(to: "bench_press", equipment: Self.chestEquipment())
        for candidate in result {
            let entry = MachineCatalog.entry(for: candidate.machineId)
            #expect(entry?.bodyParts.contains(.chest) == true)
        }
    }

    @Test
    func workoutDuplicatesAreExcluded() {
        let result = alternatives(
            to: "bench_press",
            equipment: Self.chestEquipment(),
            excluding: ["chest_press", "pec_deck"]
        )
        #expect(!result.contains { $0.machineId == "chest_press" })
        #expect(!result.contains { $0.machineId == "pec_deck" })
    }

    // MARK: - Ranking

    @Test
    func sameMovementPatternRanksAboveDifferent() {
        // bench_press is a push; chest_press is also push, cable_machine is pull.
        let result = alternatives(to: "bench_press", equipment: Self.chestEquipment())
        let ids = result.map(\.machineId)
        guard let pushIndex = ids.firstIndex(of: "chest_press"),
              let pullIndex = ids.firstIndex(of: "cable_machine") else {
            Issue.record("expected both chest_press and cable_machine in candidates: \(ids)")
            return
        }
        #expect(pushIndex < pullIndex)
    }

    @Test
    func rankingIsDeterministic() {
        let a = alternatives(to: "bench_press", equipment: Self.chestEquipment())
        let b = alternatives(to: "bench_press", equipment: Self.chestEquipment())
        #expect(a == b)
    }

    @Test
    func resultIsCappedToFiveCandidates() {
        let result = alternatives(to: "bench_press", equipment: Self.chestEquipment())
        #expect(result.count <= 5)
    }

    // MARK: - Custom machines

    @Test
    func customMachineAppearsAsAlternative() {
        let custom = AvailableEquipment(
            id: "custom_press",
            displayName: "自作チェストマシン",
            bodyParts: [.chest],
            source: .custom,
            isAvailable: true
        )
        // Only bench_press (original) + the custom machine → custom is the
        // sole alternative and must be offered (not a dead end).
        let result = alternatives(
            to: "bench_press",
            equipment: [Self.standard("bench_press"), custom]
        )
        #expect(result.contains { $0.machineId == "custom_press" })
    }

    // MARK: - No alternative

    @Test
    func noAlternativeYieldsEmptyResult() {
        // Only the original machine is available → nothing to swap to.
        let result = alternatives(to: "bench_press", equipment: [Self.standard("bench_press")])
        #expect(result.isEmpty)
    }
}
