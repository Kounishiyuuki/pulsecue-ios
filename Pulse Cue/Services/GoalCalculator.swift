//
//  GoalCalculator.swift
//  Pulse Cue
//
//  Pure, value-only calculations for energy expenditure and daily
//  intake targets. The functions are intentionally free of SwiftData,
//  UserDefaults, and SwiftUI so they can be unit-tested in isolation
//  and called from both SettingsStore (legacy UserDefaults-backed
//  profile) and the new UserProfile (SwiftData @Model).
//
//  All numbers are rounded to integer kcal, which is the precision
//  the rest of the app surfaces in DayLog / NutritionView / Today.
//

import Foundation

enum GoalCalculator {

    /// Mifflin–St Jeor basal metabolic rate (kcal/day).
    /// - Male:        10·weight + 6.25·height − 5·age + 5
    /// - Female:      10·weight + 6.25·height − 5·age − 161
    /// - Unspecified: average of male / female offsets (−78)
    static func bmr(
        weightKg: Double,
        heightCm: Int,
        ageYears: Int,
        biologicalSex: BiologicalSex
    ) -> Int {
        let weight = max(0, weightKg)
        let height = max(0, Double(heightCm))
        let age = max(0, Double(ageYears))
        let base = 10.0 * weight + 6.25 * height - 5.0 * age
        return Int((base + biologicalSex.mifflinOffset).rounded())
    }

    /// Total Daily Energy Expenditure = BMR × PAL.
    static func tdee(
        weightKg: Double,
        heightCm: Int,
        ageYears: Int,
        biologicalSex: BiologicalSex,
        activityFactor: ActivityFactor
    ) -> Int {
        let bmrValue = bmr(
            weightKg: weightKg,
            heightCm: heightCm,
            ageYears: ageYears,
            biologicalSex: biologicalSex
        )
        return Int((Double(bmrValue) * activityFactor.pal).rounded())
    }

    /// Daily kcal delta implied by a weekly weight-change target.
    /// Uses the textbook approximation 1 kg ≈ 7700 kcal.
    /// Negative for a cut, positive for a surplus.
    static func dailyKcalAdjustment(weeklyChangeKg: Double) -> Int {
        Int((weeklyChangeKg * 7700.0 / 7.0).rounded())
    }

    /// Target daily intake = TDEE + adjustment.
    /// For a -0.5 kg/week cut on a 2,500 kcal TDEE this is ~1,950 kcal.
    static func targetIntake(
        weightKg: Double,
        heightCm: Int,
        ageYears: Int,
        biologicalSex: BiologicalSex,
        activityFactor: ActivityFactor,
        weeklyChangeKg: Double
    ) -> Int {
        let tdeeValue = tdee(
            weightKg: weightKg,
            heightCm: heightCm,
            ageYears: ageYears,
            biologicalSex: biologicalSex,
            activityFactor: activityFactor
        )
        return tdeeValue + dailyKcalAdjustment(weeklyChangeKg: weeklyChangeKg)
    }

    /// Difference between actually-consumed intake and the target.
    /// Negative = under target (i.e. on track for a cut).
    /// Positive = over target.
    static func todayGoalGap(todayIntake: Int, targetIntake: Int) -> Int {
        todayIntake - targetIntake
    }
}
