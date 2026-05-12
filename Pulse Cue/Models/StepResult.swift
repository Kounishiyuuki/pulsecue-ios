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

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        stepId: UUID,
        setIndex: Int,
        done: Bool,
        actualReps: Int? = nil,
        memo: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.stepId = stepId
        self.setIndex = setIndex
        self.done = done
        self.actualReps = actualReps
        self.memo = memo
    }
}
