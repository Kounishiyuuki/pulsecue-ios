//
//  Exercise.swift
//  Pulse Cue
//
//  One bundled *movement* definition. This is the identity + planning
//  metadata for a standard exercise — deliberately NOT its prescription
//  (sets / reps / rest stay a planner concern) and NOT its guide text
//  (that lives in `ExerciseGuide`). Pure value type: no SwiftData, no I/O.
//
//  Custom, user-authored machines never appear here — they carry no
//  authoritative movement definition and resolve to `exerciseId == nil`.
//

import Foundation

/// A single standard exercise the app knows how to name and place in a
/// plan. Reuses the existing `BodyPart`, `EquipmentType`,
/// `MovementPattern`, and `MachineDifficulty` types rather than
/// duplicating enums.
struct Exercise: Identifiable, Hashable, Sendable {
    let id: ExerciseID
    /// User-facing Japanese movement name (e.g. "ラットプルダウン").
    let displayName: String
    /// Alternate spellings used only for explicit, exact lookup helpers —
    /// never for fuzzy resolution of custom-machine names. Stored lowercased
    /// and de-duplicated by the initializer.
    let aliases: [String]
    let primaryBodyPart: BodyPart
    let secondaryBodyParts: [BodyPart]
    /// Equipment this movement can be performed on. At least one entry.
    let compatibleEquipment: [ExerciseEquipment]
    let movementPattern: MovementPattern?
    let difficulty: MachineDifficulty?
    let beginnerFriendly: Bool?

    init(
        id: ExerciseID,
        displayName: String,
        aliases: [String] = [],
        primaryBodyPart: BodyPart,
        secondaryBodyParts: [BodyPart] = [],
        compatibleEquipment: [ExerciseEquipment],
        movementPattern: MovementPattern? = nil,
        difficulty: MachineDifficulty? = nil,
        beginnerFriendly: Bool? = nil
    ) {
        self.id = id
        self.displayName = displayName
        // Normalize aliases so validation and (explicit) lookup are stable.
        var seen = Set<String>()
        self.aliases = aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        self.primaryBodyPart = primaryBodyPart
        self.secondaryBodyParts = secondaryBodyParts
        self.compatibleEquipment = compatibleEquipment
        self.movementPattern = movementPattern
        self.difficulty = difficulty
        self.beginnerFriendly = beginnerFriendly
    }

    /// Body parts (primary first) in canonical order, for display.
    var bodyParts: [BodyPart] {
        var ordered = [primaryBodyPart]
        for part in BodyPart.allCases where part != primaryBodyPart && secondaryBodyParts.contains(part) {
            ordered.append(part)
        }
        return ordered
    }

    /// Exact catalog ids this movement can be performed on.
    var compatibleMachineIds: [String] {
        compatibleEquipment.compactMap(\.machineId)
    }

    /// Whether this movement can be performed on the given catalog id.
    func supports(machineId: String) -> Bool {
        compatibleEquipment.contains { equipment in
            switch equipment {
            case let .machine(id): return id == machineId
            case .anyOfType: return false
            }
        }
    }

    /// Whether this movement trains the given part (primary or secondary).
    func trains(_ part: BodyPart) -> Bool {
        primaryBodyPart == part || secondaryBodyParts.contains(part)
    }
}
