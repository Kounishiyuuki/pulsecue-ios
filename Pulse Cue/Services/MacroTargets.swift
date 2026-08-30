//
//  MacroTargets.swift
//  Pulse Cue
//
//  The daily macro targets, in one place.
//
//  These were written out three times inside `NutritionView` — once for the
//  summary card and once more for each pending AI estimate card:
//
//      max(60,  Int(Double(targetKcal ?? 2000) * 0.20 / 4))
//      max(150, Int(Double(targetKcal ?? 2000) * 0.50 / 4))
//      max(40,  Int(Double(targetKcal ?? 2000) * 0.30 / 9))
//
//  The protein line was already a duplicate of
//  `ProteinTotals.defaultTargetGrams(forKcalTarget:)`, spelled out again with
//  the constants inlined. Two copies of one formula do not disagree until
//  someone changes one of them, and a macro target that differs between the
//  summary card and the estimate card directly above it is the kind of thing
//  a user notices and nobody can reproduce.
//
//  The numbers are unchanged; only their name and their address are new.
//  Protein still comes from `ProteinTotals`, which owns that rule.
//

import Foundation

enum MacroTargets {

    // MARK: - The split
    //
    //  Protein 20% / carbs 50% / fat 30% of the kcal target, each converted at
    //  its Atwater factor and floored. The floors are not design values: they
    //  are the point below which the target stops scaling, so a very tight cut
    //  still shows a macro figure someone can eat to rather than one that
    //  approaches zero with the calories.

    static let carbShareOfKcal: Double = 0.50
    static let fatShareOfKcal: Double = 0.30

    /// Atwater factors. 4 kcal/g for carbohydrate, 9 for fat.
    static let carbKcalPerGram: Int = 4
    static let fatKcalPerGram: Int = 9

    static let carbFloorGrams: Int = 150
    static let fatFloorGrams: Int = 40

    // MARK: - Targets

    /// Daily protein target (g). Delegated so protein has one rule, not two.
    static func protein(forKcalTarget kcalTarget: Int?) -> Int {
        ProteinTotals.defaultTargetGrams(forKcalTarget: kcalTarget)
    }

    static func carbs(forKcalTarget kcalTarget: Int?) -> Int {
        grams(
            kcalTarget: kcalTarget,
            share: carbShareOfKcal,
            kcalPerGram: carbKcalPerGram,
            floor: carbFloorGrams
        )
    }

    static func fat(forKcalTarget kcalTarget: Int?) -> Int {
        grams(
            kcalTarget: kcalTarget,
            share: fatShareOfKcal,
            kcalPerGram: fatKcalPerGram,
            floor: fatFloorGrams
        )
    }

    /// All three at once, for the panels that show them together.
    struct Daily: Equatable {
        let proteinGrams: Int
        let carbGrams: Int
        let fatGrams: Int
    }

    static func daily(forKcalTarget kcalTarget: Int?) -> Daily {
        Daily(
            proteinGrams: protein(forKcalTarget: kcalTarget),
            carbGrams: carbs(forKcalTarget: kcalTarget),
            fatGrams: fat(forKcalTarget: kcalTarget)
        )
    }

    /// Shares the baseline with the protein rule: without a kcal target the
    /// app still has to show something, and the three macros must agree about
    /// what they are a share *of*.
    private static func grams(
        kcalTarget: Int?,
        share: Double,
        kcalPerGram: Int,
        floor: Int
    ) -> Int {
        let kcal = kcalTarget ?? ProteinTotals.baselineKcalTarget
        let raw = Double(kcal) * share / Double(kcalPerGram)
        return max(floor, Int(raw))
    }
}
