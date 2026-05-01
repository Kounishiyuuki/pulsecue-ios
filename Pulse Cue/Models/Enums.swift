//
//  Enums.swift
//  Pulse Cue
//
//  Created by Codex.
//

import Foundation

enum SessionStatus: String, Codable, CaseIterable {
    case inProgress
    case completed
    case abandoned
}

enum RunnerPhase: String, Codable, CaseIterable {
    case exercise
    case rest
    case done
}

enum DayLogField: String, Identifiable, CaseIterable {
    case workout
    case nutrition
    case sleep
    case weight

    var id: String { rawValue }
}

enum RunnerAction {
    case complete
    case skip
    case extend
    case back
}
