//
//  RoutineOrderStore.swift
//  Pulse Cue
//
//  Created by Codex.
//

import Foundation
import SwiftUI

struct RoutineOrderStore {
    private let defaults = UserDefaults.standard

    func ordered(routines: [Routine], pinned: Bool) -> [Routine] {
        let order = pinned ? pinnedOrder : regularOrder
        let map = Dictionary(uniqueKeysWithValues: routines.map { ($0.id, $0) })
        var result: [Routine] = []
        for id in order {
            if let routine = map[id] {
                result.append(routine)
            }
        }
        let remaining = routines.filter { routine in
            !order.contains(routine.id)
        }.sorted { $0.updatedAt > $1.updatedAt }
        result.append(contentsOf: remaining)
        return result
    }

    mutating func move(routines: [Routine], fromOffsets: IndexSet, toOffset: Int, pinned: Bool) {
        var ids = pinned ? pinnedOrder : regularOrder
        let routineIds = routines.map { $0.id }
        ids = routineIds
        ids.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save(ids: ids, pinned: pinned)
    }

    mutating func setPinned(_ routineId: UUID, pinned: Bool) {
        var pinnedIds = pinnedOrder
        var regularIds = regularOrder

        pinnedIds.removeAll { $0 == routineId }
        regularIds.removeAll { $0 == routineId }

        if pinned {
            pinnedIds.insert(routineId, at: 0)
        } else {
            regularIds.insert(routineId, at: 0)
        }

        save(ids: pinnedIds, pinned: true)
        save(ids: regularIds, pinned: false)
    }

    private var pinnedOrder: [UUID] {
        readIds(forKey: Keys.pinned)
    }

    private var regularOrder: [UUID] {
        readIds(forKey: Keys.regular)
    }

    private func readIds(forKey key: String) -> [UUID] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let decoder = JSONDecoder()
        return (try? decoder.decode([UUID].self, from: data)) ?? []
    }

    private func save(ids: [UUID], pinned: Bool) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(ids) else { return }
        defaults.set(data, forKey: pinned ? Keys.pinned : Keys.regular)
    }

    private enum Keys {
        static let pinned = "routine.order.pinned"
        static let regular = "routine.order.regular"
    }
}
