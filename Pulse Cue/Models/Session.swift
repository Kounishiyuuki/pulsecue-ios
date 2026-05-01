//
//  Session.swift
//  Pulse Cue
//
//  Created by Codex.
//

import Foundation
import SwiftData

@Model
final class Session {
    @Attribute(.unique) var id: UUID
    var routineId: UUID
    var dayDate: Date
    var startedAt: Date
    var endedAt: Date?
    var status: SessionStatus
    var totalSeconds: Int

    init(
        id: UUID = UUID(),
        routineId: UUID,
        dayDate: Date,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        status: SessionStatus = .inProgress,
        totalSeconds: Int = 0
    ) {
        self.id = id
        self.routineId = routineId
        self.dayDate = dayDate
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.totalSeconds = totalSeconds
    }
}
