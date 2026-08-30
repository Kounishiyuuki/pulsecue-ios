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

/// Who owns today's intake figure.
///
/// The invariant, and it is one rule rather than two:
///
///   **Any `MealEntry` for the day — pending included — makes the meal ledger
///   authoritative for that day. Only *confirmed* entries count towards
///   consumed calories. The manual `DayLog` value is a fallback only when the
///   day holds no meal entries at all.**
///
/// Ownership and the number are separate questions, and conflating them is
/// what went wrong before: this type keyed ownership off *confirmed* meals
/// while `NutritionLedger` keys its writes off *any* meal. On a pending-only
/// day the two disagreed — the UI offered manual calorie entry, and the next
/// ledger write (a confirm, or a delete) cleared what the user had typed.
/// Nothing errored; the number just disappeared.
///
/// So ownership follows the ledger, because the ledger is what writes.
enum NutritionIntakeSource: Equatable {
    /// A meal entry exists for the day, of any status.
    case meals
    /// No meal entries; the quick calorie input owns the day.
    case manualDayLog
    /// No meals and nothing typed in.
    case none
}

/// Where the day's calorie target came from.
///
/// Only so the UI can name it truthfully: a manually set target described as
/// 「計算目標」 tells the user the app worked it out when they typed it in.
enum NutritionTargetSource: Equatable {
    case manualOverride
    case profileDerived
    case unset
}

struct DailyNutritionSummary: Equatable {
    /// Confirmed intake for the day. `nil` when nothing is recorded at all.
    let consumedKcal: Int?
    /// The day's intake target. `nil` when neither an override nor a profile
    /// figure exists — in which case there is genuinely no target, and no
    /// screen may invent one.
    let targetKcal: Int?
    let proteinGrams: Int
    let proteinTargetGrams: Int
    /// Who owns `consumedKcal`. See `NutritionIntakeSource`.
    let intakeSource: NutritionIntakeSource
    let targetSource: NutritionTargetSource

    /// Whether a manual calorie entry would survive.
    ///
    /// False once any meal exists for the day. Such a value is not merely
    /// ignored by the display — `NutritionLedger` overwrites or clears it on
    /// the next confirm or delete, so offering the field is offering to lose
    /// what the user types.
    var acceptsManualIntakeEntry: Bool {
        intakeSource != .meals
    }

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
    ///   - mealsForDay: **every** meal entry for the day, whatever its
    ///     status. Not just the confirmed ones: pending rows decide ownership
    ///     even though they do not count as intake, and having callers filter
    ///     first is how the two rules drifted apart in the first place.
    ///   - manualTargetKcal: the resolved `HealthTargets` override.
    ///   - profileTargetKcal: the profile-calculated target.
    static func make(
        dayLog: DayLog?,
        mealsForDay: [MealEntry],
        manualTargetKcal: Int?,
        profileTargetKcal: Int?
    ) -> DailyNutritionSummary {
        let confirmedMeals = mealsForDay.filter { $0.status == .confirmed }
        let target = GoalCalculator.effectiveIntakeTarget(
            manualTarget: manualTargetKcal,
            profileTarget: profileTargetKcal
        )
        let protein = ProteinTotals.daily(meals: confirmedMeals, kcalTarget: target)
        let consumedValue = consumed(
            dayLog: dayLog,
            mealsForDay: mealsForDay,
            confirmedMeals: confirmedMeals
        )

        return DailyNutritionSummary(
            consumedKcal: consumedValue,
            targetKcal: target,
            proteinGrams: protein.confirmedGrams,
            proteinTargetGrams: protein.targetGrams,
            intakeSource: intakeSource(
                mealsForDay: mealsForDay,
                consumed: consumedValue
            ),
            targetSource: targetSource(
                manual: manualTargetKcal,
                resolved: target
            )
        )
    }

    /// The same summary, assembled the way a screen assembles it.
    ///
    /// `make` takes the two target figures already resolved. Both screens were
    /// resolving them identically and separately — the manual override out of
    /// `HealthTargetResolver`, the fallback out of the profile at the latest
    /// weigh-in — which put the *priority chain* in two places even though the
    /// arithmetic that consumes it was in one. That is the same shape of drift
    /// this type was created to end, one level up.
    ///
    /// Nothing is fetched here. Callers pass what their queries already hold,
    /// so using this costs no extra reads.
    ///
    /// - Parameters:
    ///   - currentWeightKg: the latest weigh-in from
    ///     `LatestBodyWeightResolver`. Never a figure taken from a screen's
    ///     display window — see `BodyWeightTruthTests`.
    static func forDay(
        _ date: Date,
        dayLog: DayLog?,
        mealsForDay: [MealEntry],
        profile: UserProfile?,
        currentWeightKg: Double?,
        targetSettings: HealthTargetSettings
    ) -> DailyNutritionSummary {
        make(
            dayLog: dayLog,
            mealsForDay: mealsForDay,
            manualTargetKcal: HealthTargetResolver.resolveAll(
                date: date,
                settings: targetSettings
            ).intakeCalories,
            profileTargetKcal: profile?.targetIntake(currentWeightKg: currentWeightKg)
        )
    }

    /// Ownership, keyed off the same predicate `NutritionLedger` writes by.
    private static func intakeSource(
        mealsForDay: [MealEntry],
        consumed: Int?
    ) -> NutritionIntakeSource {
        if !mealsForDay.isEmpty { return .meals }
        return consumed == nil ? .none : .manualDayLog
    }

    private static func targetSource(
        manual: Int?,
        resolved: Int?
    ) -> NutritionTargetSource {
        guard resolved != nil else { return .unset }
        // `GoalCalculator` prefers the override, so a resolved target with an
        // override present came from it.
        return manual != nil ? .manualOverride : .profileDerived
    }

    /// The day's confirmed intake.
    ///
    /// Once any meal exists the answer comes from the confirmed ones, and
    /// from nowhere else — including when that total is zero. A pending-only
    /// day is genuinely at zero confirmed intake, and falling back to the
    /// stored `DayLog` value there would show an estimate's worth of calories
    /// the user never confirmed, or a manual figure the ledger has already
    /// wiped.
    ///
    /// With no meals at all the stored value stands: that is the quick
    /// calorie input, and it is the only record of the day.
    private static func consumed(
        dayLog: DayLog?,
        mealsForDay: [MealEntry],
        confirmedMeals: [MealEntry]
    ) -> Int? {
        guard mealsForDay.isEmpty else {
            return confirmedMeals.reduce(0) { $0 + $1.kcal }
        }
        return dayLog?.intakeCalories
    }
}
