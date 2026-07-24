//
//  ExerciseLibraryTests.swift
//  Pulse CueTests
//
//  Authoring-integrity tests for the bundled Exercise Library. These are
//  the guardrails that turn a data-entry mistake into a failing test
//  rather than a runtime surprise: unique/well-formed ids, valid equipment
//  references, deterministic body-part resolution, and the equipment ↔
//  exercise separation (no custom-machine ids leak into the library).
//

import Foundation
import Testing
@testable import Pulse_Cue

struct ExerciseLibraryTests {

    // MARK: - Identity integrity

    @Test func idsAreUnique() {
        let ids = ExerciseLibrary.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func idsAreLowercaseSnakeCase() {
        for exercise in ExerciseLibrary.all {
            #expect(
                exercise.id.rawValue.range(of: ExerciseID.formatPattern, options: .regularExpression) != nil,
                "invalid id: \(exercise.id.rawValue)"
            )
            #expect(exercise.id.isWellFormed)
        }
    }

    @Test func displayNamesAreNonEmpty() {
        for exercise in ExerciseLibrary.all {
            #expect(!exercise.displayName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @Test func everyExerciseHasAtLeastOneEquipment() {
        for exercise in ExerciseLibrary.all {
            #expect(!exercise.compatibleEquipment.isEmpty, "\(exercise.id) has no equipment")
        }
    }

    // MARK: - Equipment references

    @Test func everyExactEquipmentIdExistsInCatalog() {
        let catalogIds = Set(MachineCatalog.all.map(\.id))
        for exercise in ExerciseLibrary.all {
            for machineId in exercise.compatibleMachineIds {
                #expect(catalogIds.contains(machineId), "\(exercise.id) → unknown equipment \(machineId)")
            }
        }
    }

    @Test func noCustomMachineReferenceLeaksIntoLibrary() {
        for exercise in ExerciseLibrary.all {
            #expect(!exercise.id.rawValue.hasPrefix("custom_"))
            for machineId in exercise.compatibleMachineIds {
                #expect(!machineId.hasPrefix("custom_"))
            }
        }
    }

    // MARK: - Aliases

    @Test func aliasesAreNormalizedAndUnambiguous() {
        var seenAlias: [String: ExerciseID] = [:]
        for exercise in ExerciseLibrary.all {
            for alias in exercise.aliases {
                // Normalized: lowercase, trimmed, non-empty.
                #expect(alias == alias.lowercased())
                #expect(alias == alias.trimmingCharacters(in: .whitespacesAndNewlines))
                #expect(!alias.isEmpty)
                // Unambiguous: an alias never maps to two different exercises.
                if let existing = seenAlias[alias] {
                    #expect(existing == exercise.id, "alias '\(alias)' is ambiguous")
                } else {
                    seenAlias[alias] = exercise.id
                }
            }
        }
    }

    // MARK: - Lookup API

    @Test func lookupAndValidationRoundTrip() {
        for exercise in ExerciseLibrary.all {
            #expect(ExerciseLibrary.isValid(exercise.id))
            #expect(ExerciseLibrary.exercise(for: exercise.id)?.id == exercise.id)
        }
        #expect(!ExerciseLibrary.isValid(ExerciseID("definitely_not_a_real_exercise")))
        #expect(ExerciseLibrary.exercise(for: ExerciseID("definitely_not_a_real_exercise")) == nil)
    }

    @Test func mvpExercisesAllExist() {
        let mvp: [ExerciseID] = [
            "machine_chest_press", "lat_pulldown", "machine_seated_row",
            "machine_shoulder_press", "leg_press", "leg_extension",
            "leg_curl", "machine_arm_curl", "cable_triceps_pushdown",
            "machine_lateral_raise",
        ]
        for id in mvp {
            #expect(ExerciseLibrary.isValid(id), "missing MVP exercise \(id)")
        }
    }

    // MARK: - Deterministic resolution

    @Test func barbellResolvesToDistinctMovementsPerBodyPart() {
        let chest = ExerciseLibrary.resolve(equipmentId: "barbell", bodyParts: [.chest])
        let back = ExerciseLibrary.resolve(equipmentId: "barbell", bodyParts: [.back])
        let legs = ExerciseLibrary.resolve(equipmentId: "barbell", bodyParts: [.legs])
        let shoulders = ExerciseLibrary.resolve(equipmentId: "barbell", bodyParts: [.shoulders])
        let arms = ExerciseLibrary.resolve(equipmentId: "barbell", bodyParts: [.arms])

        #expect(chest?.id == "barbell_bench_press")
        #expect(back?.id == "barbell_row")
        #expect(legs?.id == "barbell_back_squat")
        #expect(shoulders?.id == "barbell_shoulder_press")
        #expect(arms?.id == "barbell_curl")

        let ids = [chest, back, legs, shoulders, arms].compactMap { $0?.id }
        #expect(Set(ids).count == 5)
    }

    @Test func cableResolvesByBodyPart() {
        #expect(ExerciseLibrary.resolve(equipmentId: "cable_machine", bodyParts: [.back])?.id == "cable_row")
        #expect(ExerciseLibrary.resolve(equipmentId: "cable_machine", bodyParts: [.arms])?.id == "cable_triceps_pushdown")
        #expect(ExerciseLibrary.resolve(equipmentId: "cable_machine", bodyParts: [.core])?.id == "cable_crunch")
    }

    @Test func resolutionIsDeterministic() {
        for _ in 0..<20 {
            #expect(ExerciseLibrary.resolve(equipmentId: "dumbbells", bodyParts: [.chest])?.id == "dumbbell_bench_press")
        }
    }

    @Test func resolveReturnsNilForUnknownEquipment() {
        #expect(ExerciseLibrary.resolve(equipmentId: "custom_whatever", bodyParts: [.chest]) == nil)
        #expect(ExerciseLibrary.resolve(equipmentId: "nonexistent_machine", bodyParts: [.chest]) == nil)
    }

    @Test func everyCatalogEquipmentResolvesToAMovement() {
        // Every standard catalog machine should map to at least one library
        // movement, so weekly planning never has to fall back to the raw
        // machine name for known equipment.
        for entry in MachineCatalog.all {
            let ordered = BodyPart.allCases.filter { entry.bodyParts.contains($0) }
            #expect(
                ExerciseLibrary.resolve(equipmentId: entry.id, bodyParts: ordered) != nil,
                "no movement resolves for catalog equipment \(entry.id)"
            )
        }
    }
}
