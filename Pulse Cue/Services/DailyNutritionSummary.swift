//
//  DailyNutritionSummary.swift
//  Pulse Cue
//
//  One day's intake, computed once.
//
//  Home and the Nutrition tab used to answer the same three questions
//  separately and could disagree about all of them on the same day:
//
//    consumed — Home read `DayLog.intakeCalories`; Nutrition summed confirmed
//      meals directly. Those agree only while meals exist, because
//      `NutritionLedger` maintains the field then. On a day logged with the
//      quick calorie input and no meals, Home showed the number and Nutrition
//      showed zero — the input still saved, just nowhere the user was looking.
//
//    target — Home applied the manual `HealthTargets` override and fell back
//      to the profile figure; Nutrition used the profile figure only. So a
//      manual target moved one screen and not the other.
//
//    remaining — derived from the two above, so it inherited both.
//
//  Copying one screen's formula into the other would have fixed the symptom
//  and left the cause: two implementations of one rule. This is the rule.
//
//  Both callers pass in what they already have. Nothing here reads the store,
//  and none of the policies below are new — they are the ones the app already
//  had, in one place instead of two.
//

import Foundation

struct DailyNutritionSummary: Equatable {
    /// Confirmed intake for the day. `nil` when nothing is recorded at all.
    let consumedKcal: Int?
    /// The day's intake target. `nil` when neither an override nor a profile
    /// figure exists — in which case there is genuinely no target, and no
    /// screen may invent one.
    let targetKcal: Int?
    let proteinGrams: Int
    let proteinTargetGrams: Int

    /// What is left of the target.
    ///
    /// `nil` without a target. Negative when the day is over it: going over
    /// is the answer a user most needs, and clamping at zero would report
    /// 「残り 0」 to someone 300 kcal past their target.
    var remainingKcal: Int? {
        guard let targetKcal else { return nil }
        return targetKcal - (consumedKcal ?? 0)
    }

    /// Builds the day's summary from stored state.
    ///
    /// - Parameters:
    ///   - dayLog: today's `DayLog`, if one exists.
    ///   - confirmedMeals: today's `.confirmed` meals. Pending and
    ///     AI-estimated rows are the caller's job to exclude, because that
    ///     rule already lives in the meal query and in `ProteinTotals`.
    ///   - manualTargetKcal: the resolved `HealthTargets` override.
    ///   - profileTargetKcal: the profile-calculated target.
    static func make(
        dayLog: DayLog?,
        confirmedMeals: [MealEntry],
        manualTargetKcal: Int?,
        profileTargetKcal: Int?
    ) -> DailyNutritionSummary {
        let target = GoalCalculator.effectiveIntakeTarget(
            manualTarget: manualTargetKcal,
            profileTarget: profileTargetKcal
        )
        let protein = ProteinTotals.daily(meals: confirmedMeals, kcalTarget: target)

        return DailyNutritionSummary(
            consumedKcal: consumed(dayLog: dayLog, confirmedMeals: confirmedMeals),
            targetKcal: target,
            proteinGrams: protein.confirmedGrams,
            proteinTargetGrams: protein.targetGrams
        )
    }

    /// The day's intake, following the ownership rule `NutritionLedger`
    /// already enforces when it writes.
    ///
    /// Meals own the number whenever any exist — that is what the ledger
    /// maintains, and reading the meals directly here means the two cannot
    /// fall out of step even if a write is missed. With no meals at all the
    /// stored `DayLog` value stands, which is the quick calorie input and the
    /// only record of that day.
    ///
    /// A day holding only *pending* meals falls through to the stored value,
    /// which `NutritionLedger` has already cleared for exactly that case — so
    /// an unconfirmed estimate reads as "not recorded" rather than as intake,
    /// on both screens.
    private static func consumed(
        dayLog: DayLog?,
        confirmedMeals: [MealEntry]
    ) -> Int? {
        if !confirmedMeals.isEmpty {
            return confirmedMeals.reduce(0) { $0 + $1.kcal }
        }
        return dayLog?.intakeCalories
    }
}
