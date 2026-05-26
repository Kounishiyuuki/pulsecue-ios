//
//  MachineCatalogQuery.swift
//  Pulse Cue
//
//  Pure local search/filter helpers over `MachineCatalog`. Used by the
//  upcoming machine catalog UI and by the rule-based plan generator so
//  both sides agree on query semantics. Intentionally:
//
//   - has no SwiftData or `@Model` dependency,
//   - performs no I/O — no networking, no persistence, no AI,
//   - is a thin wrapper over `MachineCatalog.all` so callers stay simple.
//
//  See `Docs/gym-machine-catalog-and-plan-foundation.md` §4–§7 for the
//  fields these queries are designed to surface.
//

import Foundation

/// A composable, all-optional query against `MachineCatalog`. Default
/// instances (`MachineCatalogQuery()`) match every entry — callers fill
/// in only the fields they care about and combine the rest with AND.
struct MachineCatalogQuery: Equatable, Sendable {
    /// Case-insensitive substring matched against `displayName`, `id`,
    /// and `tags`. Trimmed; empty or whitespace-only text is ignored.
    var searchText: String = ""
    /// If non-empty, an entry must train at least one of these parts
    /// (matched against `bodyParts ∪ secondaryMuscles`).
    var bodyParts: [BodyPart] = []
    var category: MachineCategory? = nil
    var equipmentType: EquipmentType? = nil
    var movementPattern: MovementPattern? = nil
    var difficulty: MachineDifficulty? = nil
    /// When true, only entries with `beginnerFriendly == true` pass.
    var beginnerFriendlyOnly: Bool = false
    /// If non-empty, an entry must contain *all* of these tags
    /// (case-insensitive). Empty/whitespace tags are ignored.
    var tags: [String] = []

    init(
        searchText: String = "",
        bodyParts: [BodyPart] = [],
        category: MachineCategory? = nil,
        equipmentType: EquipmentType? = nil,
        movementPattern: MovementPattern? = nil,
        difficulty: MachineDifficulty? = nil,
        beginnerFriendlyOnly: Bool = false,
        tags: [String] = []
    ) {
        self.searchText = searchText
        self.bodyParts = bodyParts
        self.category = category
        self.equipmentType = equipmentType
        self.movementPattern = movementPattern
        self.difficulty = difficulty
        self.beginnerFriendlyOnly = beginnerFriendlyOnly
        self.tags = tags
    }

    /// True when no filter is set — the query matches every entry.
    var isEmpty: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && bodyParts.isEmpty
            && category == nil
            && equipmentType == nil
            && movementPattern == nil
            && difficulty == nil
            && beginnerFriendlyOnly == false
            && tags.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

extension MachineCatalogEntry {
    /// Whether this entry satisfies every active clause of `query`.
    /// Optional scalar filters (`category`, `equipmentType`, etc.) only
    /// match when the entry has a non-nil value equal to the requested
    /// one — entries with no metadata fall out as soon as such a filter
    /// is set, which is the intended UI behavior.
    func matches(_ query: MachineCatalogQuery) -> Bool {
        if query.isEmpty { return true }

        let trimmedSearch = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            let needle = trimmedSearch.lowercased()
            let haystack = [displayName.lowercased(), id.lowercased()] + tags.map { $0.lowercased() }
            guard haystack.contains(where: { $0.contains(needle) }) else { return false }
        }

        if !query.bodyParts.isEmpty {
            let combined = bodyParts.union(secondaryMuscles)
            guard query.bodyParts.contains(where: { combined.contains($0) }) else { return false }
        }

        if let wanted = query.category {
            guard category == wanted else { return false }
        }
        if let wanted = query.equipmentType {
            guard equipmentType == wanted else { return false }
        }
        if let wanted = query.movementPattern {
            guard movementPattern == wanted else { return false }
        }
        if let wanted = query.difficulty {
            guard difficulty == wanted else { return false }
        }
        if query.beginnerFriendlyOnly {
            guard beginnerFriendly == true else { return false }
        }

        let requiredTags = query.tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        if !requiredTags.isEmpty {
            let entryTags = Set(tags.map { $0.lowercased() })
            guard requiredTags.allSatisfy(entryTags.contains) else { return false }
        }

        return true
    }
}

extension MachineCatalog {
    /// Returns the catalog entries that satisfy `query`, preserving the
    /// canonical (`id`-sorted) order from `MachineCatalog.all` so the UI
    /// gets stable results across calls.
    static func filteredEntries(matching query: MachineCatalogQuery) -> [MachineCatalogEntry] {
        all.filter { $0.matches(query) }
    }
}
