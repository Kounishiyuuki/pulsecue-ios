//
//  RecentMealSuggestions.swift
//  Pulse Cue
//
//  Pure helper that ranks past `MealEntry` rows for one-tap re-entry
//  on Nutrition. No SwiftData / SwiftUI access — the input is the
//  caller's already-fetched `MealEntry` array so tests can pin
//  ordering / dedup rules without spinning up a ModelContext.
//
//  Source-of-truth rules (locked by tests):
//   - Suggest only `.confirmed && .manual` meals. Pending / AI rows
//     must never bubble up here — re-entering an unconfirmed estimate
//     would violate the "estimate → confirm → finalize" boundary that
//     PR #33 codified.
//   - Exclude any meal whose `dayDate` matches today's local start of
//     day. Today's meals are already shown in the "今日の食事一覧"
//     section above; surfacing them again as suggestions would just
//     create duplicates if tapped.
//   - Dedupe by (name, kcal). When the user has eaten 鶏むね 200g /
//     300 kcal three times this month, we want one suggestion, not
//     three. The most recent occurrence wins so its slot / PFC carry
//     over.
//   - Sort by `createdAt` descending. Most recent first.
//   - Respect a caller-supplied limit (default 8). Keeps the row
//     light enough to scroll horizontally on the Nutrition card.
//

import Foundation

enum RecentMealSuggestions {

    /// Default surface area on Nutrition.
    static let defaultLimit: Int = 8

    /// Snapshot of a past meal, stripped down to the fields we re-use
    /// when creating today's entry from a tap. Excludes `note` and
    /// `id` — those are entry-local.
    struct Suggestion: Equatable, Identifiable {
        let name: String
        let kcal: Int
        let slot: MealSlot
        let proteinGrams: Int?
        let carbGrams: Int?
        let fatGrams: Int?
        /// Most recent `createdAt` we observed for this (name, kcal)
        /// combination. Surfaced for tests; not displayed in the UI.
        let lastUsedAt: Date

        /// Stable identifier driven by the dedup key. Lets SwiftUI
        /// `ForEach` and animations behave well without forcing a UUID.
        var id: String { "\(name)|\(kcal)" }
    }

    /// Compute up to `limit` suggestions from `meals`. Pure — does
    /// not mutate any input. Today is anchored by `today` (caller
    /// passes `Date()` in production; tests pin a fixed instant).
    static func suggest(
        from meals: [MealEntry],
        today: Date,
        limit: Int = defaultLimit,
        calendar: Calendar = .current,
    ) -> [Suggestion] {
        let todayStart = calendar.startOfDay(for: today)
        let safeLimit = max(0, limit)
        guard safeLimit > 0 else { return [] }

        // 1. Filter to candidates: confirmed + manual + not today.
        let candidates = meals.filter { meal in
            meal.status == .confirmed
                && meal.source == .manual
                && calendar.startOfDay(for: meal.dayDate) != todayStart
        }

        // 2. Sort newest first so the dedup loop keeps the most recent
        //    occurrence (its slot / PFC become the canonical copy).
        let sorted = candidates.sorted { lhs, rhs in
            lhs.createdAt > rhs.createdAt
        }

        // 3. Dedup by (name, kcal). First occurrence wins after sort.
        var seen = Set<String>()
        var out: [Suggestion] = []
        out.reserveCapacity(safeLimit)
        for meal in sorted {
            let key = "\(meal.name)|\(meal.kcal)"
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(
                Suggestion(
                    name: meal.name,
                    kcal: meal.kcal,
                    slot: meal.slot,
                    proteinGrams: meal.proteinGrams,
                    carbGrams: meal.carbGrams,
                    fatGrams: meal.fatGrams,
                    lastUsedAt: meal.createdAt,
                )
            )
            if out.count >= safeLimit { break }
        }
        return out
    }
}
