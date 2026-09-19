//
//  StepResult.swift
//  Pulse Cue
//
//  Created by Codex.
//

import Foundation
import SwiftData

@Model
final class StepResult {
    @Attribute(.unique) var id: UUID
    var sessionId: UUID
    var stepId: UUID
    var setIndex: Int
    var done: Bool
    var actualReps: Int?
    var memo: String?
    /// Sync owner, mirroring `Session.ownerAccountID` for the parent session.
    ///
    /// The truth lives on the session; it is duplicated here because the
    /// server's `step_results` row carries `user_id` of its own (composite key
    /// `(user_id, id)`, composite FK `(user_id, session_id)`), and because
    /// there is no SwiftData relationship to traverse — `sessionId` is a plain
    /// UUID. `AccountScopedSyncStore` is the only writer, and it never leaves
    /// a result owned by an account other than its session's.
    var ownerAccountID: UUID?

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        stepId: UUID,
        setIndex: Int,
        done: Bool,
        actualReps: Int? = nil,
        memo: String? = nil,
        ownerAccountID: UUID? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.stepId = stepId
        self.setIndex = setIndex
        self.done = done
        self.actualReps = actualReps
        self.memo = memo
        self.ownerAccountID = ownerAccountID
    }
}
