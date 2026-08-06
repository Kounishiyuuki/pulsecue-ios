//
//  RoutineOrderStore.swift
//  Pulse Cue
//
//  Created by Codex.
//

import Foundation
import SwiftUI

struct RoutineOrderStore {
    private let defaults: UserDefaults

    /// Accepts a UserDefaults instance so tests can inject an isolated
    /// suite (`UserDefaults(suiteName:)`) and not collide with the
    /// live app's stored pin/order. Production call sites pass
    /// nothing and get `.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

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

/// Persists the two optional rest layers that sit above the app-wide default.
/// Effective values remain materialized on `Step.restSeconds`; this store only
/// records which value should be inherited by routine-editing UI.
struct RoutineRestPreferenceStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func routineDefault(for routineID: UUID, appDefault: Int) -> Int {
        payload.routineDefaults[routineID.uuidString] ?? Self.clamp(appDefault)
    }

    func setRoutineDefault(_ seconds: Int, for routineID: UUID) {
        update { value in
            value.routineDefaults[routineID.uuidString] = Self.clamp(seconds)
            value.knownRoutineIDs.insert(routineID.uuidString)
        }
    }

    func clearRoutineDefault(for routineID: UUID) {
        update { value in
            value.routineDefaults.removeValue(forKey: routineID.uuidString)
            value.knownRoutineIDs.insert(routineID.uuidString)
        }
    }

    /// Imports a pre-preference routine exactly once, preserving the effective
    /// rest values already materialized on its steps. The most frequent value
    /// becomes the routine default; ties follow the existing step order.
    func prepareRoutine(
        _ routineID: UUID,
        existingStepRests: [(id: UUID, seconds: Int)],
        appDefault _: Int
    ) {
        update { value in
            let routineKey = routineID.uuidString
            guard !value.knownRoutineIDs.contains(routineKey) else { return }

            value.knownRoutineIDs.insert(routineKey)
            let steps = existingStepRests.map { (id: $0.id, seconds: Self.clamp($0.seconds)) }
            value.routineStepIDs[routineKey] = steps.map { $0.id.uuidString }
            guard !steps.isEmpty else {
                // No legacy values exist to preserve. Marking the routine as
                // known makes this an explicit inheritance of the app default.
                value.routineDefaults.removeValue(forKey: routineKey)
                return
            }

            var counts: [Int: Int] = [:]
            for step in steps {
                counts[step.seconds, default: 0] += 1
            }
            let highestCount = counts.values.max() ?? 0
            let routineDefault = steps.first { counts[$0.seconds] == highestCount }!.seconds
            value.routineDefaults[routineKey] = routineDefault

            for step in steps {
                value.stepOverrides.removeValue(forKey: step.id.uuidString)
            }
            for step in steps where step.seconds != routineDefault {
                value.stepOverrides[step.id.uuidString] = step.seconds
            }
        }
    }

    func stepOverride(for stepID: UUID) -> Int? {
        payload.stepOverrides[stepID.uuidString]
    }

    func setStepOverride(_ seconds: Int, for stepID: UUID, routineID: UUID? = nil) {
        update { value in
            value.stepOverrides[stepID.uuidString] = Self.clamp(seconds)
            if let routineID {
                var ids = value.routineStepIDs[routineID.uuidString, default: []]
                if !ids.contains(stepID.uuidString) {
                    ids.append(stepID.uuidString)
                }
                value.routineStepIDs[routineID.uuidString] = ids
                value.knownRoutineIDs.insert(routineID.uuidString)
            }
        }
    }

    func clearStepOverride(for stepID: UUID) {
        update { value in
            value.stepOverrides.removeValue(forKey: stepID.uuidString)
            for routineID in Array(value.routineStepIDs.keys) {
                value.routineStepIDs[routineID]?.removeAll { $0 == stepID.uuidString }
            }
        }
    }

    /// Copies rest metadata while allowing duplicated steps to receive fresh IDs.
    func copyMetadata(
        from sourceRoutineID: UUID,
        to destinationRoutineID: UUID,
        stepIDMapping: [UUID: UUID]
    ) {
        update { value in
            let sourceKey = sourceRoutineID.uuidString
            let destinationKey = destinationRoutineID.uuidString
            if value.knownRoutineIDs.contains(sourceKey) {
                value.knownRoutineIDs.insert(destinationKey)
            }
            if let routineDefault = value.routineDefaults[sourceRoutineID.uuidString] {
                value.routineDefaults[destinationRoutineID.uuidString] = routineDefault
            }

            let destinationStepIDs = stepIDMapping.values.map(\.uuidString)
            for (sourceStepID, destinationStepID) in stepIDMapping {
                if let override = value.stepOverrides[sourceStepID.uuidString] {
                    value.stepOverrides[destinationStepID.uuidString] = override
                }
            }
            if !destinationStepIDs.isEmpty {
                value.routineStepIDs[destinationRoutineID.uuidString] = destinationStepIDs
            }
        }
    }

    func removeMetadata(forRoutine routineID: UUID, stepIDs: [UUID] = []) {
        update { value in
            value.routineDefaults.removeValue(forKey: routineID.uuidString)
            value.knownRoutineIDs.remove(routineID.uuidString)
            let recordedIDs = value.routineStepIDs.removeValue(forKey: routineID.uuidString) ?? []
            let idsToRemove = Set(recordedIDs + stepIDs.map(\.uuidString))
            for stepID in idsToRemove {
                value.stepOverrides.removeValue(forKey: stepID)
            }
        }
    }

    func removeMetadata(forSteps stepIDs: [UUID]) {
        for stepID in stepIDs {
            clearStepOverride(for: stepID)
        }
    }

    private var payload: Payload {
        guard let data = defaults.data(forKey: Keys.preferences),
              let decoded = try? JSONDecoder().decode(Payload.self, from: data) else {
            return Payload()
        }
        return decoded
    }

    private func update(_ mutation: (inout Payload) -> Void) {
        var value = payload
        mutation(&value)
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Keys.preferences)
    }

    private static func clamp(_ seconds: Int) -> Int {
        min(max(seconds, 0), 600)
    }

    private struct Payload: Codable {
        var routineDefaults: [String: Int] = [:]
        var stepOverrides: [String: Int] = [:]
        var routineStepIDs: [String: [String]] = [:]
        var knownRoutineIDs: Set<String> = []

        private enum CodingKeys: String, CodingKey {
            case routineDefaults
            case stepOverrides
            case routineStepIDs
            case knownRoutineIDs
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            routineDefaults = try container.decodeIfPresent([String: Int].self, forKey: .routineDefaults) ?? [:]
            stepOverrides = try container.decodeIfPresent([String: Int].self, forKey: .stepOverrides) ?? [:]
            routineStepIDs = try container.decodeIfPresent([String: [String]].self, forKey: .routineStepIDs) ?? [:]
            if let decodedKnownIDs = try container.decodeIfPresent(Set<String>.self, forKey: .knownRoutineIDs) {
                knownRoutineIDs = decodedKnownIDs
            } else {
                // Older payloads with metadata are already configured and
                // must not be overwritten by the one-time legacy import.
                knownRoutineIDs = Set(routineDefaults.keys).union(routineStepIDs.keys)
            }
        }
    }

    private enum Keys {
        static let preferences = "routine.rest.preferences"
    }
}
