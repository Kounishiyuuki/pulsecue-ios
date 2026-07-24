//
//  Step.swift
//  Pulse Cue
//
//  Created by Codex.
//

import Foundation
import SwiftData

@Model
final class Step {
    @Attribute(.unique) var id: UUID
    var routineId: UUID
    var order: Int
    var title: String
    var sets: Int
    var repsTarget: Int
    var restSeconds: Int
    var note: String
    var isWarmup: Bool
    /// Optional stable Exercise Library identity (schema V4+). Stored as a
    /// plain `ExerciseID.rawValue` string — NOT a relationship, enum, or
    /// transformable — so persisted data survives library type changes and
    /// unknown/deprecated ids stay readable. `nil` for pre-V4 rows, manual
    /// steps, and custom/unresolved exercises. It is enhancement metadata:
    /// `title` remains the universal display/runtime value, so a `nil` (or
    /// unresolvable) id never blocks a workout. Never inferred from `title`.
    var exerciseId: String?

    init(
        id: UUID = UUID(),
        routineId: UUID,
        order: Int,
        title: String,
        sets: Int,
        repsTarget: Int,
        restSeconds: Int,
        note: String = "",
        isWarmup: Bool = false,
        exerciseId: String? = nil
    ) {
        self.id = id
        self.routineId = routineId
        self.order = order
        self.title = title.isEmpty ? "無題" : title
        self.sets = Step.clampSets(sets)
        self.repsTarget = max(1, repsTarget)
        self.restSeconds = Step.clampRest(restSeconds)
        self.note = note
        self.isWarmup = isWarmup
        self.exerciseId = exerciseId
    }

    static func clampRest(_ value: Int) -> Int {
        min(max(value, 0), 600)
    }

    static func clampSets(_ value: Int) -> Int {
        min(max(value, 1), 20)
    }
}
