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

/// UserDefaults-backed list of `FavoriteMealTemplate`, one list per
/// `HealthDataScope`. Published so SwiftUI can observe insert/delete via
/// `@StateObject` / `@ObservedObject` without manual refresh plumbing.
///
/// The store holds one scope's list at a time and answers only for that
/// scope: `templates(in:)` returns `[]` for any other scope, and writes for a
/// scope that is not the loaded one are dropped. Switching account A → B on
/// the same instance therefore cannot show or modify A's list under B in the
/// render before `use(_:)` reloads it.
final class FavoriteMealTemplateStore: ObservableObject {

    /// Base storage key. Versioned so a future schema change (e.g. adding
    /// carb/fat fields) can ship under a new key without corrupting v1 data.
    /// The bare key is the pre-account, device-global list; each scope stores
    /// under `HealthScopedDefaults.key(_:for:)`.
    static let defaultStorageKey = "favoriteMealTemplates.v1"

    @Published private var loaded: HealthScopedValue<[FavoriteMealTemplate]>

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = FavoriteMealTemplateStore.defaultStorageKey,
        scope: HealthDataScope = .undetermined
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.loaded = HealthScopedValue(
            scope: scope,
            value: Self.load(defaults: defaults, key: storageKey, scope: scope)
        )
    }

    /// Loads `scope`'s list. Called when the current scope changes.
    func use(_ scope: HealthDataScope) {
        guard loaded.scope != scope else { return }
        loaded = HealthScopedValue(
            scope: scope,
            value: Self.load(defaults: defaults, key: storageKey, scope: scope)
        )
    }

    /// `scope`'s templates, or `[]` when the store holds another scope's.
    func templates(in scope: HealthDataScope) -> [FavoriteMealTemplate] {
        loaded.value(in: scope) ?? []
    }

    /// Add a template. If a template with the same `(name, kcal)`
    /// already exists, this is a no-op (idempotent — the user tapping
    /// "保存" twice should not produce two entries). Returns true when
    /// the list actually grew.
    @discardableResult
    func add(_ template: FavoriteMealTemplate, in scope: HealthDataScope) -> Bool {
        guard var templates = writable(scope),
              !templates.contains(where: { $0.dedupeKey == template.dedupeKey }) else {
            return false
        }
        templates.append(template)
        persist(templates, in: scope)
        return true
    }

    /// Remove by `id`. Removing a non-existent id is a safe no-op.
    func remove(_ template: FavoriteMealTemplate, in scope: HealthDataScope) {
        guard var templates = writable(scope) else { return }
        let before = templates.count
        templates.removeAll { $0.id == template.id }
        if templates.count != before {
            persist(templates, in: scope)
        }
    }

    /// `true` if a template with `(name, kcal)` already exists. Used by
    /// the UI to hide the "保存" button when the meal is already pinned.
    func contains(name: String, kcal: Int, in scope: HealthDataScope) -> Bool {
        templates(in: scope).contains { $0.name == name && $0.kcal == kcal }
    }

    // MARK: - Persistence

    /// The loaded list, if `scope` is the loaded scope and has a key.
    private func writable(_ scope: HealthDataScope) -> [FavoriteMealTemplate]? {
        guard HealthScopedDefaults.key(storageKey, for: scope) != nil else { return nil }
        return loaded.value(in: scope)
    }

    private func persist(_ templates: [FavoriteMealTemplate], in scope: HealthDataScope) {
        loaded = HealthScopedValue(scope: scope, value: templates)
        guard let key = HealthScopedDefaults.key(storageKey, for: scope),
              let data = try? JSONEncoder().encode(templates) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load(
        defaults: UserDefaults,
        key: String,
        scope: HealthDataScope
    ) -> [FavoriteMealTemplate] {
        guard let data = HealthScopedDefaults.data(key, for: scope, in: defaults) else { return [] }
        return (try? JSONDecoder().decode([FavoriteMealTemplate].self, from: data)) ?? []
    }
}
