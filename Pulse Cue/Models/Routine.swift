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
    /// Added in schema V5. Existing routines migrate to `.userSaved` so the
    /// library is unchanged; a non-optional default keeps the migration
    /// lightweight.
    var origin: RoutineOrigin

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
        self.origin = origin
    }
}
