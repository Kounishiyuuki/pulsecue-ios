//
//  RunnerPersistence.swift
//  Pulse Cue
//
//  Created by Codex.
//

import Foundation

struct RunnerPersistentState: Codable {
    var sessionId: UUID
    var routineId: UUID
    var phase: RunnerPhase
    var stepIndex: Int
    var setIndex: Int
    var restDeadline: Date?
    var lastUpdatedAt: Date
}

struct RunnerPersistence {
    private static let key = "runner.persistent.state"

    static func save(_ state: RunnerPersistentState) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> RunnerPersistentState? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(RunnerPersistentState.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
