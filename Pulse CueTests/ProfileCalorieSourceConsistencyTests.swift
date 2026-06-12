//
//  ProfileCalorieSourceConsistencyTests.swift
//  Pulse CueTests
//
//  Documents and pins the source-of-truth contract for calorie targets:
//
//   - `UserProfile` (SwiftData) is the single source for body metrics +
//     goal and drives BMR / TDEE / target-intake via `GoalCalculator`.
//   - Nutrition shows `UserProfile.targetIntake(...)`; Today shows the
//     manual `HealthTargets.intakeCalories` override when set, else falls
//     back to the same `UserProfile.targetIntake(...)` (PR #100).
//   - The manual override only changes which value Today *displays*; it
//     never changes the underlying profile-calculated formula.
//   - `SettingsStore` (UserDefaults) holds app preferences only — it is
//     not exercised here because it carries no calorie/profile values.
//
//  Pure value math + an unmanaged `UserProfile` instance (no ModelContext,
//  no persistence). `@MainActor` because the app target uses MainActor
//  default isolation.
//

import Foundation
import Testing
@testable import Pulse_Cue

@Suite
@MainActor
struct ProfileCalorieSourceConsistencyTests {

    private func makeProfile(
        heightCm: Int = 170,
        ageYears: Int = 30,
        biologicalSex: BiologicalSex = .male,
        activityFactor: ActivityFactor = .moderate,
        goalWeightKg: Double = 65,
        weeklyChangeKg: Double = -0.5
    ) -> UserProfile {
        UserProfile(
            heightCm: heightCm,
            ageYears: ageYears,
            biologicalSex: biologicalSex,
            activityFactor: activityFactor,
            goalWeightKg: goalWeightKg,
            weeklyChangeKg: weeklyChangeKg
        )
    }

    // MARK: - UserProfile is the source for the calorie target

    @Test
    func targetIntakeMatchesGoalCalculatorFromProfileValues() {
        let profile = makeProfile()
        let weight = 70.0
        let expected = GoalCalculator.targetIntake(
            weightKg: weight,
            heightCm: 170,
            ageYears: 30,
            biologicalSex: .male,
            activityFactor: .moderate,
            weeklyChangeKg: -0.5
        )
        // The profile derives its target purely from its own fields.
        #expect(profile.targetIntake(currentWeightKg: weight) == expected)
    }

    @Test
    func changingProfileActivityChangesTarget() {
        let sedentary = makeProfile(activityFactor: .sedentary).targetIntake(currentWeightKg: 70)
        let active = makeProfile(activityFactor: .active).targetIntake(currentWeightKg: 70)
        let sed = try! #require(sedentary)
        let act = try! #require(active)
        // Higher activity → higher TDEE → higher target. Profile drives it.
        #expect(act > sed)
    }

    @Test
    func missingMeasuredWeightFallsBackToGoalWeight() {
        let profile = makeProfile(goalWeightKg: 60)
        let viaNil = profile.targetIntake(currentWeightKg: nil)
        let viaGoalWeight = GoalCalculator.targetIntake(
            weightKg: 60,
            heightCm: 170,
            ageYears: 30,
            biologicalSex: .male,
            activityFactor: .moderate,
            weeklyChangeKg: -0.5
        )
        // Graceful: no measured weight → goal weight is used.
        #expect(viaNil == viaGoalWeight)
    }

    // MARK: - Today fallback vs Nutrition (PR #100 contract)

    @Test
    func todayFallsBackToProfileTargetWhenNoManualOverride() {
        let profile = makeProfile()
        let profileTarget = profile.targetIntake(currentWeightKg: 70)
        // With no manual override, Today shows the same value Nutrition does.
        #expect(
            GoalCalculator.effectiveIntakeTarget(manualTarget: nil, profileTarget: profileTarget)
            == profileTarget
        )
    }

    @Test
    func manualOverrideWinsForTodayButLeavesProfileTargetUnchanged() {
        let profile = makeProfile()
        let profileTarget = profile.targetIntake(currentWeightKg: 70)
        // Manual HealthTargets value wins for Today's displayed target...
        #expect(
            GoalCalculator.effectiveIntakeTarget(manualTarget: 1800, profileTarget: profileTarget)
            == 1800
        )
        // ...but the underlying profile-calculated target is untouched: the
        // override is a display layer, not a formula change.
        #expect(profile.targetIntake(currentWeightKg: 70) == profileTarget)
    }

    @Test
    func noProfileAndNoManualTargetIsGraceful() {
        // Neither source available → no target (Today shows nothing).
        #expect(GoalCalculator.effectiveIntakeTarget(manualTarget: nil, profileTarget: nil) == nil)
    }
}
