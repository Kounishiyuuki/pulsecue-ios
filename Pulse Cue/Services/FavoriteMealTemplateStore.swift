//
//  FavoriteMealTemplateStore.swift
//  Pulse Cue
//
//  User-curated favorite meal templates for one-tap add on Nutrition.
//  Sits next to RecentMealSuggestions but with different semantics:
//
//    - "最近の食事" (RecentMealSuggestions) is derived from MealEntry
//      history. It rotates as the user logs new meals and excludes
//      today's entries.
//    - "よく使う食事" (this store) is explicit. The user picks which
//      meals to pin, and the list survives independent of MealEntry
//      history (so deleting a past meal does not erase its template).
//
//  Persisted as a JSON array in UserDefaults. SwiftData stays untouched
//  so this PR does not require a schema migration. If templates later
//  need cross-device sync or richer queries we can promote them to a
//  SwiftData @Model in a dedicated migration PR.
//
//  Dedup key: `(name, kcal)`. Adding a template with the same name +
//  kcal is a no-op (preserves the original `id` / `createdAt`) so the
//  user can tap "保存" repeatedly without bloating the list.
//
//  Source-of-truth boundaries:
//   - This store does NOT touch DayLog / NutritionLedger / ProteinTotals.
//     Creating today's MealEntry from a template is the caller's job;
//     the caller then runs `NutritionLedger.syncDayLogIntake` exactly
//     like the recent-meal shortcut path.
//   - All inserted MealEntry rows must be `.confirmed` + `.manual`.
//     Pending / AI sources are out of scope for templates.
//

import Foundation
import Combine

/// One pinned meal the user can re-add to today with a tap.
struct FavoriteMealTemplate: Codable, Equatable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var kcal: Int
    var proteinGrams: Int?
    var slotRaw: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        kcal: Int,
        proteinGrams: Int? = nil,
        slot: MealSlot,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kcal = max(0, kcal)
        self.proteinGrams = proteinGrams.map { max(0, $0) }
        self.slotRaw = slot.rawValue
        self.createdAt = createdAt
    }

    var slot: MealSlot { MealSlot(rawValue: slotRaw) ?? .snack }

    /// Stable key used for dedup. Matches the (name, kcal) rule that
    /// `RecentMealSuggestions` already uses so the two surfaces collapse
    /// identical entries the same way.
    var dedupeKey: String { "\(name)|\(kcal)" }
}

/// UserDefaults-backed list of `FavoriteMealTemplate`. Published so
/// SwiftUI can observe insert/delete via `@StateObject` /
/// `@ObservedObject` without manual refresh plumbing.
final class FavoriteMealTemplateStore: ObservableObject {

    /// Default storage key. Versioned so a future schema change (e.g.
    /// adding carb/fat fields) can ship under a new key without
    /// corrupting v1 data.
    static let defaultStorageKey = "favoriteMealTemplates.v1"

    @Published private(set) var templates: [FavoriteMealTemplate]

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = FavoriteMealTemplateStore.defaultStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.templates = Self.load(defaults: defaults, key: storageKey)
    }

    /// Add a template. If a template with the same `(name, kcal)`
    /// already exists, this is a no-op (idempotent — the user tapping
    /// "保存" twice should not produce two entries). Returns true when
    /// the list actually grew.
    @discardableResult
    func add(_ template: FavoriteMealTemplate) -> Bool {
        if templates.contains(where: { $0.dedupeKey == template.dedupeKey }) {
            return false
        }
        templates.append(template)
        persist()
        return true
    }

    /// Remove by `id`. Removing a non-existent id is a safe no-op.
    func remove(_ template: FavoriteMealTemplate) {
        let before = templates.count
        templates.removeAll { $0.id == template.id }
        if templates.count != before {
            persist()
        }
    }

    /// `true` if a template with `(name, kcal)` already exists. Used by
    /// the UI to hide the "保存" button when the meal is already pinned.
    func contains(name: String, kcal: Int) -> Bool {
        templates.contains { $0.name == name && $0.kcal == kcal }
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func load(defaults: UserDefaults, key: String) -> [FavoriteMealTemplate] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([FavoriteMealTemplate].self, from: data)) ?? []
    }
}
