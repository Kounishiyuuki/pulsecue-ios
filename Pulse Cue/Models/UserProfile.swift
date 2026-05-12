//
//  UserProfile.swift
//  Pulse Cue
//
//  Single SwiftData record holding the user's profile and weight-loss
//  goals. The model intentionally mirrors the fields previously held
//  only in SettingsStore (UserDefaults) so we have a path toward
//  cross-device sync (CloudKit) while keeping the legacy
//  UserDefaults-backed Settings UI working in the meantime.
//
//  Enums are stored as raw strings for safe SwiftData light-weight
//  migrations.
//

import Foundation
import SwiftData

@Model
final class UserProfile {
    @Attribute(.unique) var id: UUID
    var heightCm: Int
    var ageYears: Int
    var biologicalSexRaw: String
    var activityFactorRaw: String
    var goalWeightKg: Double
    var weeklyChangeKg: Double
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        heightCm: Int = 170,
        ageYears: Int = 30,
        biologicalSex: BiologicalSex = .unspecified,
        activityFactor: ActivityFactor = .moderate,
        goalWeightKg: Double = 65.0,
        weeklyChangeKg: Double = -0.5,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.heightCm = max(0, heightCm)
        self.ageYears = max(0, ageYears)
        self.biologicalSexRaw = biologicalSex.rawValue
        self.activityFactorRaw = activityFactor.rawValue
        self.goalWeightKg = max(0, goalWeightKg)
        self.weeklyChangeKg = weeklyChangeKg
        self.updatedAt = updatedAt
    }

    var biologicalSex: BiologicalSex {
        get { BiologicalSex(rawValue: biologicalSexRaw) ?? .unspecified }
        set {
            biologicalSexRaw = newValue.rawValue
            updatedAt = Date()
        }
    }

    var activityFactor: ActivityFactor {
        get { ActivityFactor(rawValue: activityFactorRaw) ?? .moderate }
        set {
            activityFactorRaw = newValue.rawValue
            updatedAt = Date()
        }
    }

    // MARK: - Derived metrics

    /// BMR via Mifflin-St Jeor. Falls back to `goalWeightKg` when the
    /// caller doesn't know the user's current measured weight.
    func bmr(currentWeightKg: Double?) -> Int? {
        guard let weight = effectiveWeight(currentWeightKg: currentWeightKg) else { return nil }
        return GoalCalculator.bmr(
            weightKg: weight,
            heightCm: heightCm,
            ageYears: ageYears,
            biologicalSex: biologicalSex
        )
    }

    func tdee(currentWeightKg: Double?) -> Int? {
        guard let weight = effectiveWeight(currentWeightKg: currentWeightKg) else { return nil }
        return GoalCalculator.tdee(
            weightKg: weight,
            heightCm: heightCm,
            ageYears: ageYears,
            biologicalSex: biologicalSex,
            activityFactor: activityFactor
        )
    }

    func targetIntake(currentWeightKg: Double?) -> Int? {
        guard let weight = effectiveWeight(currentWeightKg: currentWeightKg) else { return nil }
        return GoalCalculator.targetIntake(
            weightKg: weight,
            heightCm: heightCm,
            ageYears: ageYears,
            biologicalSex: biologicalSex,
            activityFactor: activityFactor,
            weeklyChangeKg: weeklyChangeKg
        )
    }

    /// Difference between today's intake and the calculated target.
    /// Negative = under target, positive = over.
    func todayGoalGap(todayIntake: Int, currentWeightKg: Double?) -> Int? {
        guard let target = targetIntake(currentWeightKg: currentWeightKg) else { return nil }
        return GoalCalculator.todayGoalGap(todayIntake: todayIntake, targetIntake: target)
    }

    private func effectiveWeight(currentWeightKg: Double?) -> Double? {
        if let measured = currentWeightKg, measured > 0 { return measured }
        return goalWeightKg > 0 ? goalWeightKg : nil
    }
}
