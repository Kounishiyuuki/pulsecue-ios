//
//  MacroTargetsTests.swift
//  Pulse CueTests
//
//  The macro targets were lifted out of `NutritionView`, where they appeared
//  three times as literal arithmetic. Lifting a formula is the moment it is
//  easiest to change one by accident, so these pin the extracted helper
//  against the expressions it replaced:
//
//      max(60,  Int(Double(kcal ?? 2000) * 0.20 / 4))
//      max(150, Int(Double(kcal ?? 2000) * 0.50 / 4))
//      max(40,  Int(Double(kcal ?? 2000) * 0.30 / 9))
//
//  Written out here on purpose. A test that called `MacroTargets` to work out
//  what `MacroTargets` should return would pass under any change at all.
//

import Foundation
import Testing
@testable import Pulse_Cue

struct MacroTargetsTests {

    /// The arithmetic as `NutritionView` had it, before extraction.
    private func legacyProtein(_ kcal: Int?) -> Int {
        max(60, Int(Double(kcal ?? 2000) * 0.20 / 4))
    }
    private func legacyCarbs(_ kcal: Int?) -> Int {
        max(150, Int(Double(kcal ?? 2000) * 0.50 / 4))
    }
    private func legacyFat(_ kcal: Int?) -> Int {
        max(40, Int(Double(kcal ?? 2000) * 0.30 / 9))
    }

    // MARK: - Identical to what it replaced

    @Test(arguments: [nil, 1_200, 1_500, 1_800, 2_000, 2_400, 3_000, 4_000] as [Int?])
    func theExtractedTargetsMatchTheFormulaTheyReplaced(kcalTarget: Int?) {
        let targets = MacroTargets.daily(forKcalTarget: kcalTarget)

        #expect(targets.proteinGrams == legacyProtein(kcalTarget))
        #expect(targets.carbGrams == legacyCarbs(kcalTarget))
        #expect(targets.fatGrams == legacyFat(kcalTarget))
    }

    // MARK: - The floors

    @Test func theFloorsHoldOnATightTarget() {
        // 800 kcal would give 40 g protein, 100 g carbs, 26 g fat. The floors
        // exist so a very tight cut still shows a figure someone can eat to.
        let targets = MacroTargets.daily(forKcalTarget: 800)

        #expect(targets.proteinGrams == ProteinTotals.defaultTargetFloorGrams)
        #expect(targets.carbGrams == MacroTargets.carbFloorGrams)
        #expect(targets.fatGrams == MacroTargets.fatFloorGrams)
    }

    @Test func theTargetsScaleOnceAboveTheFloors() {
        let low = MacroTargets.daily(forKcalTarget: 2_000)
        let high = MacroTargets.daily(forKcalTarget: 3_000)

        #expect(high.proteinGrams > low.proteinGrams)
        #expect(high.carbGrams > low.carbGrams)
        #expect(high.fatGrams > low.fatGrams)
    }

    // MARK: - One protein rule, not two

    @Test(arguments: [nil, 1_600, 2_000, 2_800] as [Int?])
    func proteinIsTheSameRuleTheDailySummaryUses(kcalTarget: Int?) {
        // The summary card takes its protein target from `ProteinTotals` via
        // `DailyNutritionSummary`, and the estimate card from `MacroTargets`.
        // They sit one above the other on screen, so a divergence would be
        // visible and unexplainable.
        #expect(
            MacroTargets.protein(forKcalTarget: kcalTarget)
                == ProteinTotals.defaultTargetGrams(forKcalTarget: kcalTarget)
        )
    }

    @Test func noTargetFallsBackToTheSharedBaseline() {
        #expect(
            MacroTargets.daily(forKcalTarget: nil)
                == MacroTargets.daily(forKcalTarget: ProteinTotals.baselineKcalTarget)
        )
    }
}
