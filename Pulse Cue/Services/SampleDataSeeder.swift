//
//  SampleDataSeeder.swift
//  Pulse Cue
//
//  Created by Codex.
//

import Foundation
import SwiftData

struct SampleDataSeeder {
    static let isEnabled = true
    private static let seededKey = "sample.seeded"

    static func seedIfNeeded(modelContext: ModelContext) {
        guard isEnabled else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: seededKey) else { return }

        let fetch = FetchDescriptor<Routine>()
        if let count = try? modelContext.fetchCount(fetch), count > 0 {
            defaults.set(true, forKey: seededKey)
            return
        }

        let push = Routine(name: "プッシュ（サンプル）", isPinned: true)
        modelContext.insert(push)
        let pushSteps: [Step] = [
            Step(routineId: push.id, order: 0, title: "ベンチプレス", sets: 3, repsTarget: 8, restSeconds: 90),
            Step(routineId: push.id, order: 1, title: "インクラインダンベルプレス", sets: 3, repsTarget: 10, restSeconds: 90),
            Step(routineId: push.id, order: 2, title: "ショルダープレス", sets: 3, repsTarget: 10, restSeconds: 75),
            Step(routineId: push.id, order: 3, title: "トライセプスプレスダウン", sets: 3, repsTarget: 12, restSeconds: 60)
        ]
        pushSteps.forEach { modelContext.insert($0) }

        let pull = Routine(name: "プル（サンプル）")
        modelContext.insert(pull)
        let pullSteps: [Step] = [
            Step(routineId: pull.id, order: 0, title: "デッドリフト", sets: 3, repsTarget: 5, restSeconds: 120),
            Step(routineId: pull.id, order: 1, title: "ラットプルダウン", sets: 3, repsTarget: 10, restSeconds: 75),
            Step(routineId: pull.id, order: 2, title: "シーテッドロウ", sets: 3, repsTarget: 10, restSeconds: 75),
            Step(routineId: pull.id, order: 3, title: "バーベルカール", sets: 3, repsTarget: 12, restSeconds: 60)
        ]
        pullSteps.forEach { modelContext.insert($0) }

        defaults.set(true, forKey: seededKey)
    }
}
