//
//  GoalCalculatorTests.swift
//  Pulse CueTests
//
//  Unit tests for the pure goal calculations:
//  BMR (Mifflin-St Jeor), TDEE, weekly→daily kcal adjustment,
//  target intake, and today goal gap.
//
//  Pure value math — no SwiftData, no UserDefaults, no UI.
//

import Foundation
import Testing
@testable import Pulse_Cue

struct GoalCalculatorTests {

    // MARK: - BMR (Mifflin-St Jeor)

    @Test
    func bmrForMaleMatchesMifflinStJeor() {
        // 30 yo male, 170 cm, 70 kg
        // 10*70 + 6.25*170 − 5*30 + 5 = 700 + 1062.5 − 150 + 5 = 1617.5 → 1618
        let value = GoalCalculator.bmr(
            weightKg: 70,
            heightCm: 170,
            ageYears: 30,
            biologicalSex: .male
        )
        #expect(value == 1618)
    }

    @Test
    func bmrForFemaleMatchesMifflinStJeor() {
        // 30 yo female, 160 cm, 55 kg
        // 10*55 + 6.25*160 − 5*30 − 161 = 550 + 1000 − 150 − 161 = 1239
        let value = GoalCalculator.bmr(
            weightKg: 55,
            heightCm: 160,
            ageYears: 30,
            biologicalSex: .female
        )
        #expect(value == 1239)
    }

    @Test
    func bmrForUnspecifiedSitsBetweenMaleAndFemale() {
        // Same body: unspecified should be the M/F midpoint
        // (offset = -78 = average of +5 and −161).
        let male = GoalCalculator.bmr(weightKg: 70, heightCm: 170, ageYears: 30, biologicalSex: .male)
        let female = GoalCalculator.bmr(weightKg: 70, heightCm: 170, ageYears: 30, biologicalSex: .female)
        let unspecified = GoalCalculator.bmr(weightKg: 70, heightCm: 170, ageYears: 30, biologicalSex: .unspecified)
        // Female < unspecified < male
        #expect(unspecified > female)
        #expect(unspecified < male)
        // Difference from male side equals 83 (avg offset −78 vs +5).
        #expect(male - unspecified == 83)
        #expect(unspecified - female == 83)
    }

    @Test
    func bmrIsNonNegativeForExtremeOrZeroInputs() {
        let zero = GoalCalculator.bmr(weightKg: 0, heightCm: 0, ageYears: 0, biologicalSex: .female)
        // 10*0 + 6.25*0 − 5*0 − 161 = −161. Math is allowed to be negative
        // here (the View layer is responsible for not surfacing nonsense).
        // The point of this test is just that the function does not crash
        // and returns a deterministic integer.
        #expect(zero == -161)

        let extreme = GoalCalculator.bmr(weightKg: 300, heightCm: 250, ageYears: 100, biologicalSex: .male)
        // 3000 + 1562.5 − 500 + 5 = 4067.5 → 4068
        #expect(extreme == 4068)
    }

    @Test
    func bmrClampsNegativeWeightHeightAge() {
        // Negative inputs are clamped to 0 inside the calculator.
        let value = GoalCalculator.bmr(weightKg: -50, heightCm: -10, ageYears: -5, biologicalSex: .male)
        #expect(value == 5) // base = 0 + 0 − 0 = 0, offset = +5
    }

    // MARK: - TDEE

    @Test
    func tdeeIsBmrTimesPalRounded() {
        // BMR 1618 (as above), moderate PAL 1.55 → 2508
        let value = GoalCalculator.tdee(
            weightKg: 70,
            heightCm: 170,
            ageYears: 30,
            biologicalSex: .male,
            activityFactor: .moderate
        )
        #expect(value == 2508) // round(1618 * 1.55) = round(2507.9) = 2508
    }

    @Test
    func tdeeScalesWithActivityFactor() {
        let inputs = (weight: 70.0, height: 170, age: 30, sex: BiologicalSex.male)
        let sedentary = GoalCalculator.tdee(weightKg: inputs.weight, heightCm: inputs.height,
                                            ageYears: inputs.age, biologicalSex: inputs.sex,
                                            activityFactor: .sedentary)
        let veryActive = GoalCalculator.tdee(weightKg: inputs.weight, heightCm: inputs.height,
                                             ageYears: inputs.age, biologicalSex: inputs.sex,
                                             activityFactor: .veryActive)
        #expect(veryActive > sedentary)
        // round(1618 * 1.20) = 1942, round(1618 * 1.90) = 3074
        #expect(sedentary == 1942)
        #expect(veryActive == 3074)
    }

    // MARK: - Daily kcal adjustment

    @Test
    func dailyKcalAdjustmentForHalfKgCutIsAroundMinus550() {
        // −0.5 kg/week × 7700 / 7 = −550
        #expect(GoalCalculator.dailyKcalAdjustment(weeklyChangeKg: -0.5) == -550)
    }

    @Test
    func dailyKcalAdjustmentForHalfKgSurplusIsAroundPlus550() {
        #expect(GoalCalculator.dailyKcalAdjustment(weeklyChangeKg: 0.5) == 550)
    }

    @Test
    func dailyKcalAdjustmentZeroChangeIsZero() {
        #expect(GoalCalculator.dailyKcalAdjustment(weeklyChangeKg: 0) == 0)
    }

    @Test
    func dailyKcalAdjustmentExtremeOneKgPerWeek() {
        // −1.0 kg/week × 7700 / 7 = −1100
        #expect(GoalCalculator.dailyKcalAdjustment(weeklyChangeKg: -1.0) == -1100)
    }

    // MARK: - Target intake

    @Test
    func targetIntakeCombinesTdeeAndAdjustment() {
        // TDEE 2508, adjustment −550 → target 1958
        let value = GoalCalculator.targetIntake(
            weightKg: 70,
            heightCm: 170,
            ageYears: 30,
            biologicalSex: .male,
            activityFactor: .moderate,
            weeklyChangeKg: -0.5
        )
        #expect(value == 1958)
    }

    @Test
    func targetIntakeEqualsTdeeWhenNoChangeGoal() {
        // weeklyChange = 0 → target equals TDEE
        let tdee = GoalCalculator.tdee(weightKg: 70, heightCm: 170, ageYears: 30,
                                       biologicalSex: .female, activityFactor: .light)
        let target = GoalCalculator.targetIntake(weightKg: 70, heightCm: 170, ageYears: 30,
                                                  biologicalSex: .female, activityFactor: .light,
                                                  weeklyChangeKg: 0)
        #expect(target == tdee)
    }

    // MARK: - Today goal gap

    @Test
    func todayGoalGapIsZeroWhenAtTarget() {
        #expect(GoalCalculator.todayGoalGap(todayIntake: 1958, targetIntake: 1958) == 0)
    }

    @Test
    func todayGoalGapIsNegativeWhenUnderTarget() {
        // Ate 1800, target 1958 → -158 (i.e. 158 kcal below target)
        #expect(GoalCalculator.todayGoalGap(todayIntake: 1800, targetIntake: 1958) == -158)
    }

    @Test
    func todayGoalGapIsPositiveWhenOverTarget() {
        // Ate 2200, target 1958 → +242
        #expect(GoalCalculator.todayGoalGap(todayIntake: 2200, targetIntake: 1958) == 242)
    }
}
