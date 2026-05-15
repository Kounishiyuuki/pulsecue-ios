//
//  GymMachine.swift
//  Pulse Cue
//
//  A machine the user has confirmed is available at a specific Gym.
//  Joined back to `Gym` via `gymId` (no SwiftData relationship — the
//  rest of the project uses foreign keys, e.g. `Step.routineId`).
//
//  `displayName` is denormalized from the catalog at save time so that
//  a future catalog rename does not silently rewrite the user's data.
//  Dedupe on `(gymId, machineId)` is enforced by `GymRepository` since
//  SwiftData has no compound unique constraint.
//

import Foundation
import SwiftData

@Model
final class GymMachine {
    @Attribute(.unique) var id: UUID
    var gymId: UUID
    /// Canonical machine id from `MachineCatalog` (e.g. `lat_pulldown`).
    var machineId: String
    /// User-facing label snapshotted from the catalog at save time.
    var displayName: String
    /// Currently every persisted row is "available"; the field is kept
    /// for forward-compatibility with the upcoming import-review flow,
    /// where the user may save "seen but skipped" candidates.
    var isAvailable: Bool
    var addedAt: Date

    init(
        id: UUID = UUID(),
        gymId: UUID,
        machineId: String,
        displayName: String,
        isAvailable: Bool = true,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.gymId = gymId
        self.machineId = machineId
        self.displayName = displayName.isEmpty ? machineId : displayName
        self.isAvailable = isAvailable
        self.addedAt = addedAt
    }
}
