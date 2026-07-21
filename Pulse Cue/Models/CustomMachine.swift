//
//  CustomMachine.swift
//  Pulse Cue
//
//  A gym machine the user created by hand, for one specific Gym, when the
//  bundled `MachineCatalog` has no matching entry. Joined back to `Gym`
//  via `gymId` (no SwiftData relationship — the rest of the project uses
//  foreign keys, e.g. `GymMachine.gymId`, `Step.routineId`).
//
//  This is deliberately a *separate* model from `GymMachine`:
//    - `GymMachine` references a bundled standard-catalog machine by its
//      canonical `machineId` string.
//    - `CustomMachine` carries user-authored data (name, body parts) and
//      has no catalog id.
//  Keeping them apart means standard selections need no schema change and
//  can never end up in an invalid "half custom" state.
//
//  `bodyParts` is stored as `[String]` of `BodyPart.rawValue` (not a
//  transformable `[BodyPart]`) so a future `BodyPart` change, or a
//  corrupted/unknown persisted value, can be read back without a decode
//  crash — `resolvedBodyParts` filters unknown raw values out.
//
//  Introduced in schema V3 as a purely additive new entity; no existing
//  model changes, so V2 → V3 is a lightweight migration.
//

import Foundation
import SwiftData

@Model
final class CustomMachine {
    @Attribute(.unique) var id: UUID
    /// Logical foreign key to `Gym.id`. Manual cascade on gym deletion,
    /// consistent with `GymMachine`.
    var gymId: UUID
    var displayName: String
    /// `BodyPart.rawValue` values, deduped and stored in a deterministic
    /// order (see `normalizedBodyPartValues`). Read via `resolvedBodyParts`.
    var bodyParts: [String]
    /// `EquipmentType.rawValue` where the user picked one; `nil` otherwise.
    /// Read via `resolvedEquipmentType`, which ignores unknown raw values.
    var equipmentType: String?
    var notes: String?
    /// Kept for parity with `GymMachine.isAvailable`; every persisted row
    /// is currently "available".
    var isAvailable: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        gymId: UUID,
        displayName: String,
        bodyParts: [String] = [],
        equipmentType: String? = nil,
        notes: String? = nil,
        isAvailable: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.gymId = gymId
        self.displayName = displayName
        self.bodyParts = bodyParts
        self.equipmentType = equipmentType
        self.notes = notes
        self.isAvailable = isAvailable
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Derived (non-persistent)

    /// Valid `BodyPart` values, unknown raw values dropped. Never crashes
    /// on corrupted/future data.
    var resolvedBodyParts: [BodyPart] {
        bodyParts.compactMap(BodyPart.init(rawValue:))
    }

    /// `EquipmentType` if the stored raw value is still valid, else `nil`.
    var resolvedEquipmentType: EquipmentType? {
        equipmentType.flatMap(EquipmentType.init(rawValue:))
    }

    /// Stable string id for planner/reference use. Derived from the UUID,
    /// never persisted. Prefixed `custom_` and lowercased so it can never
    /// collide with a bundled lowercase snake_case catalog id, and it does
    /// not change when the display name or metadata is edited.
    var referenceId: String {
        "custom_\(id.uuidString.lowercased())"
    }

    // MARK: - Normalization helpers

    /// Dedupes and orders body parts deterministically (by `BodyPart`
    /// declaration order), returning their raw values for persistence.
    static func normalizedBodyPartValues(from parts: [BodyPart]) -> [String] {
        let present = Set(parts)
        return BodyPart.allCases
            .filter { present.contains($0) }
            .map(\.rawValue)
    }

    /// Trims whitespace and normalizes an empty note to `nil`.
    static func normalizedNotes(_ notes: String?) -> String? {
        guard let notes else { return nil }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
