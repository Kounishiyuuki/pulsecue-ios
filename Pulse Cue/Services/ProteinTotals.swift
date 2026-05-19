//
//  ProteinTotals.swift
//  Pulse Cue
//
//  Pure helper for protein-gram totals on Nutrition. Mirrors the
//  source-of-truth rule that PR #33's `NutritionLedger` codified for
//  kcal:
//
//    The day's *confirmed* protein total is the sum of
//    `MealEntry.proteinGrams` over `MealEntry.status == .confirmed`
//    rows. Pending rows — manual drafts *and* AI estimates — never
//    contribute. This matches the "estimate → confirm → finalize"
//    privacy / safety boundary documented in
//    Docs/ai-privacy-and-safety.md.
//
//  Why a standalone helper (vs. inlining in NutritionView):
//   - Lets us unit-test the rule independently of SwiftUI / SwiftData.
//   - Gives a single place to evolve the protein target heuristic
//     later (today: 20% of kcal target, floor 60 g).
//   - Keeps `NutritionLedger` focused on kcal + DayLog ownership;
//     protein has no DayLog field (yet), so it doesn't belong there.
//
//  Not persisted: protein totals are derived at read time. Adding a
//  `DayLog.proteinGrams` mirror would require a SwiftData schema bump
//  and is intentionally deferred.
//

import Foundation

enum ProteinTotals {

    /// Floor for the default protein target (g/day). Below this value
    /// the macro target stops scaling with kcal — even cuts shouldn't
    /// drop below ~60 g/day for an average adult.
    static let defaultTargetFloorGrams: Int = 60

    /// Share of kcal allocated to protein when deriving a fallback
    /// target. 20% matches the existing macro panel split used by
    /// NutritionView (carbs 50% / fat 30% / protein 20%).
    static let defaultProteinShareOfKcal: Double = 0.20

    /// Baseline kcal target used when the user hasn't set one. Keeps
    /// the protein target reasonable for a new install.
    static let baselineKcalTarget: Int = 2000

    /// 1 g protein = 4 kcal. Standard Atwater factor; matches the
    /// AI macro row math elsewhere in the app.
    static let kcalPerGram: Int = 4

    /// Sum of `proteinGrams` over **confirmed** meals only.
    ///
    /// `.pending` rows are excluded by design: AI estimates and
    /// half-typed manual drafts must not slip into the day's total.
    /// Nil `proteinGrams` values contribute 0 (i.e. a confirmed
    /// row that didn't capture protein leaves the macro at 0, not nil).
    static func confirmedSum(from meals: [MealEntry]) -> Int {
        meals
            .filter { $0.status == .confirmed }
            .reduce(0) { acc, meal in acc + (meal.proteinGrams ?? 0) }
    }

    /// Default daily protein target (g/day) derived from the user's
    /// kcal target. Floored at `defaultTargetFloorGrams` so a tight
    /// cut still surfaces a sensible minimum.
    static func defaultTargetGrams(forKcalTarget kcalTarget: Int?) -> Int {
        let kcal = kcalTarget ?? baselineKcalTarget
        let raw = Double(kcal) * defaultProteinShareOfKcal / Double(kcalPerGram)
        return max(defaultTargetFloorGrams, Int(raw))
    }

    /// Convenience for callers that already have a `Date`-windowed
    /// list of meals: returns both the confirmed grams and the
    /// derived target so the macro panel can render in one pass.
    struct DailyProtein: Equatable {
        let confirmedGrams: Int
        let targetGrams: Int
    }

    static func daily(meals: [MealEntry], kcalTarget: Int?) -> DailyProtein {
        DailyProtein(
            confirmedGrams: confirmedSum(from: meals),
            targetGrams: defaultTargetGrams(forKcalTarget: kcalTarget)
        )
    }
}
