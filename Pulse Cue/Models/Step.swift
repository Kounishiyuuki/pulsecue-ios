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

    init(
        id: UUID = UUID(),
        routineId: UUID,
        order: Int,
        title: String,
        sets: Int,
        repsTarget: Int,
        restSeconds: Int,
        note: String = "",
        isWarmup: Bool = false
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
    }

    static func clampRest(_ value: Int) -> Int {
        min(max(value, 0), 600)
    }

    static func clampSets(_ value: Int) -> Int {
        min(max(value, 1), 20)
    }
}
