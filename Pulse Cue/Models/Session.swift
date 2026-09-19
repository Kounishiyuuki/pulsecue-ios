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
    /// Which server account this session's *sync* belongs to, or nil for
    /// guest data no account has adopted yet.
    ///
    /// The value is the account UUID the server issues (`GET /v1/me` →
    /// `user.id`), never an Apple/Google subject. It governs sync ownership,
    /// not visibility: local history is displayed exactly as before. See
    /// `AccountScopedSyncStore`.
    var ownerAccountID: UUID?

    init(
        id: UUID = UUID(),
        routineId: UUID,
        dayDate: Date,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        status: SessionStatus = .inProgress,
        totalSeconds: Int = 0,
        ownerAccountID: UUID? = nil
    ) {
        self.id = id
        self.routineId = routineId
        self.dayDate = dayDate
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.totalSeconds = totalSeconds
        self.ownerAccountID = ownerAccountID
    }
}
