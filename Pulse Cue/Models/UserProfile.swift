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
    /// Schema V8. nil = guest; otherwise the server-confirmed internal account
    /// UUID. At most one profile per owner is `UserProfileStore`'s contract,
    /// not the schema's, so multiple rows remain representable by design.
    private(set) var ownerAccountID: UUID?

    // Schema V10. All optional: a migrated row has never been asked, which is
    // different from any answer. Enums are raw strings so an unknown value
    // from a newer build reads as "not set" instead of failing the fetch.
    var trainingGoalRaw: String? = nil
    var experienceLevelRaw: String? = nil
    var trainingDaysPerWeek: Int? = nil
    var preferredSessionMinutes: Int? = nil
    /// When this owner finished the post-sign-in profile onboarding. Lives on
    /// the account's own profile, so it follows the account UUID: signing out
    /// keeps it, deleting the account deletes it, and another account on the
    /// same device has its own.
    var profileOnboardingCompletedAt: Date? = nil
    /// The onboarding step to resume at — the first one not yet saved. Nil
    /// before the first step is saved and again once onboarding completes;
    /// an unknown value resumes at the start rather than skipping anything.
    var profileOnboardingStepRaw: String? = nil

    init(
        id: UUID = UUID(),
        heightCm: Int = 170,
        ageYears: Int = 30,
        biologicalSex: BiologicalSex = .unspecified,
        activityFactor: ActivityFactor = .moderate,
        goalWeightKg: Double = 65.0,
        weeklyChangeKg: Double = -0.5,
        updatedAt: Date = Date(),
        ownerAccountID: UUID? = nil
    ) {
        self.id = id
        self.heightCm = max(0, heightCm)
        self.ageYears = max(0, ageYears)
        self.biologicalSexRaw = biologicalSex.rawValue
        self.activityFactorRaw = activityFactor.rawValue
        self.goalWeightKg = max(0, goalWeightKg)
        self.weeklyChangeKg = weeklyChangeKg
        self.updatedAt = updatedAt
        self.ownerAccountID = ownerAccountID
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

    var trainingGoal: ProfileTrainingGoal? {
        get { trainingGoalRaw.flatMap(ProfileTrainingGoal.init(rawValue:)) }
        set {
            trainingGoalRaw = newValue?.rawValue
            updatedAt = Date()
        }
    }

    var experienceLevel: ExperienceLevel? {
        get { experienceLevelRaw.flatMap(ExperienceLevel.init(rawValue:)) }
        set {
            experienceLevelRaw = newValue?.rawValue
            updatedAt = Date()
        }
    }

    var profileOnboardingStep: ProfileOnboardingStep {
        get { profileOnboardingStepRaw.flatMap(ProfileOnboardingStep.init(rawValue:)) ?? .basics }
        set { profileOnboardingStepRaw = newValue == .basics ? nil : newValue.rawValue }
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

extension UserProfile {
    /// Moves a guest profile into `accountID`. Nil, with nothing changed, if it
    /// already belongs to an account — account → account is never an adoption.
    func adopt(into accountID: UUID) -> HealthOwnerAdoption? {
        guard ownerAccountID == nil else { return nil }
        ownerAccountID = accountID
        return HealthOwnerAdoption(accountID: accountID)
    }

    /// Puts a profile `adopt(into:)` moved back into guest data.
    func undoAdoption(_ adoption: HealthOwnerAdoption) {
        guard ownerAccountID == adoption.accountID else { return }
        ownerAccountID = nil
    }
}

/// The bounds every editor of a profile field offers — Settings and the
/// onboarding — so neither can store a value the other cannot show.
enum ProfileFieldRanges {
    static let ageYears = 10...100
    static let heightCm = 120...220
    static let bodyWeightKg = 30.0...250.0
    static let goalWeightKg = 30.0...150.0
    static let goalWeightStepKg = 0.5
    static let weeklyChangeKg = -1.5...1.5
    static let weeklyChangeStepKg = 0.1
    static let trainingDaysPerWeek = 1...7
    /// Quick Plan's own grid, so a preferred length is always one Quick Plan
    /// can offer.
    static let sessionMinutes = QuickPlanDuration.minMinutes...QuickPlanDuration.maxMinutes
    static let sessionMinutesStep = QuickPlanDuration.stepMinutes
    static let defaultSessionMinutes = QuickPlanDuration.standard.minutes

    static func isValidSessionMinutes(_ minutes: Int) -> Bool {
        sessionMinutes.contains(minutes) && QuickPlanDuration(minutes: minutes).minutes == minutes
    }
}

/// The post-sign-in onboarding's pages, in order.
enum ProfileOnboardingStep: String, CaseIterable {
    case basics, goal, habits, done

    var next: ProfileOnboardingStep? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
        return all[index + 1]
    }

    var previous: ProfileOnboardingStep? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index > 0 else { return nil }
        return all[index - 1]
    }
}

/// What the person trains for, as the profile stores it.
///
/// Not the plan generator's `TrainingGoal`: that one has no `health`, and
/// widening it would change the generator and its picker. `planGoal` is the
/// bridge for when Quick Plan starts reading the profile.
enum ProfileTrainingGoal: String, CaseIterable, Identifiable, Codable {
    case hypertrophy
    case strength
    case fatLoss
    case health
    case consistency

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hypertrophy: return "筋肥大"
        case .strength: return "筋力アップ"
        case .fatLoss: return "減量"
        case .health: return "健康維持"
        case .consistency: return "習慣づくり"
        }
    }

    /// Where the weekly-change control starts when this goal is picked: only
    /// fat loss implies losing weight. The person can still change it.
    var suggestedWeeklyChangeKg: Double {
        switch self {
        case .fatLoss: return -0.5
        case .hypertrophy: return 0.2
        case .strength, .health, .consistency: return 0
        }
    }

    /// The generator goal closest to this one. Health has no exact match;
    /// a light, repeatable plan is what it asks for.
    var planGoal: TrainingGoal {
        switch self {
        case .hypertrophy: return .hypertrophy
        case .strength: return .strength
        case .fatLoss: return .fatLoss
        case .health, .consistency: return .consistency
        }
    }
}
