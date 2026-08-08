//
//  Routine.swift
//  Pulse Cue
//
//  Created by Codex.
//

import Foundation
import SwiftData

/// Why a `Routine` exists. Only `userSaved` routines appear in the routine
/// library; `workoutGenerated` ones are materialized solely to run a workout
/// (Quick Plan "この内容で開始") and stay out of the list, while remaining a
/// valid persistent target for the Runner / Session / History.
enum RoutineOrigin: String, Codable, CaseIterable, Sendable {
    case userSaved
    case workoutGenerated
}

@Model
final class Routine {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
    /// Added in schema V5. Optional on purpose: a lightweight V4 → V5
    /// migration leaves pre-existing rows with no value, and reading a
    /// non-optional enum keypath in that state fatal-crashes SwiftData
    /// (`Passed nil for a non-optional keypath \Routine.origin`). Never read
    /// this directly — go through `origin`, which maps legacy `nil` to
    /// `.userSaved`.
    var storedOrigin: RoutineOrigin?

    /// Effective origin. Legacy (pre-V5) rows have no stored value and are by
    /// definition library routines, so they read as `.userSaved`.
    var origin: RoutineOrigin {
        get { storedOrigin ?? .userSaved }
        set { storedOrigin = newValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isPinned: Bool = false,
        origin: RoutineOrigin = .userSaved
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        // Newly created routines always state their origin explicitly; only
        // rows written before V5 are allowed to be nil.
        self.storedOrigin = origin
    }
}
