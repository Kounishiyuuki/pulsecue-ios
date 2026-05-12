//
//  SettingsStore.swift
//  Pulse Cue
//
//  Created by Codex.
//
//  Persisted user preferences. Stored in UserDefaults via @Published
//  didSet, so any UI binding writes through automatically. The store
//  intentionally has no SwiftData dependency: Routines / DayLogs are
//  per-record, this is global per-device.
//

import Foundation
import Combine
import UIKit

// MARK: - Profile enums

enum BiologicalSex: String, CaseIterable, Identifiable, Codable {
    case male
    case female
    case unspecified

    var id: String { rawValue }

    var label: String {
        switch self {
        case .male: return "男性"
        case .female: return "女性"
        case .unspecified: return "指定なし"
        }
    }

    /// Mifflin-St Jeor offset.
    var mifflinOffset: Double {
        switch self {
        case .male: return 5
        case .female: return -161
        case .unspecified: return -78   // simple average of M / F
        }
    }
}

enum ActivityFactor: String, CaseIterable, Identifiable, Codable {
    case sedentary
    case light
    case moderate
    case active
    case veryActive

    var id: String { rawValue }

    /// Standard PAL (physical activity level) multipliers.
    var pal: Double {
        switch self {
        case .sedentary: return 1.20
        case .light: return 1.375
        case .moderate: return 1.55
        case .active: return 1.725
        case .veryActive: return 1.90
        }
    }

    var label: String {
        switch self {
        case .sedentary: return "ほぼ運動なし (1.20)"
        case .light: return "軽い運動 (1.375)"
        case .moderate: return "標準 (1.55)"
        case .active: return "活発 (1.725)"
        case .veryActive: return "非常に活発 (1.90)"
        }
    }

    var shortLabel: String {
        switch self {
        case .sedentary: return "ほぼ運動なし"
        case .light: return "軽い運動"
        case .moderate: return "標準"
        case .active: return "活発"
        case .veryActive: return "非常に活発"
        }
    }
}

/// How much information the user is willing to send to AI services
/// **once** AI is enabled. Stored even while AI is disabled so the
/// preference is ready when the feature ships.
enum AITransmissionScope: String, CaseIterable, Identifiable, Codable {
    case minimum
    case standard
    case extended

    var id: String { rawValue }

    var label: String {
        switch self {
        case .minimum: return "最小"
        case .standard: return "標準"
        case .extended: return "拡張"
        }
    }

    var detail: String {
        switch self {
        case .minimum:   return "直近 1 日の集計のみ送信"
        case .standard:  return "直近 7 日の集計を送信（既定）"
        case .extended:  return "直近 30 日の集計とメモを送信"
        }
    }
}

// MARK: - SettingsStore

@MainActor
final class SettingsStore: ObservableObject {

    // App-side toggles (existing)
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }
    @Published var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
    }
    @Published var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: Keys.hapticsEnabled) }
    }
    @Published var keepScreenOn: Bool {
        didSet {
            defaults.set(keepScreenOn, forKey: Keys.keepScreenOn)
            ScreenWakeManager.apply(keepScreenOn)
        }
    }

    // Personal data (new)
    @Published var heightCm: Int {
        didSet { defaults.set(heightCm, forKey: Keys.heightCm) }
    }
    @Published var ageYears: Int {
        didSet { defaults.set(ageYears, forKey: Keys.ageYears) }
    }
    @Published var biologicalSex: BiologicalSex {
        didSet { defaults.set(biologicalSex.rawValue, forKey: Keys.biologicalSex) }
    }
    @Published var activityFactor: ActivityFactor {
        didSet { defaults.set(activityFactor.rawValue, forKey: Keys.activityFactor) }
    }

    // Goals (new)
    @Published var goalWeightKg: Double {
        didSet { defaults.set(goalWeightKg, forKey: Keys.goalWeightKg) }
    }
    @Published var weeklyChangeKg: Double {
        didSet { defaults.set(weeklyChangeKg, forKey: Keys.weeklyChangeKg) }
    }

    // Integrations / AI (new)
    @Published var aiTransmissionScope: AITransmissionScope {
        didSet { defaults.set(aiTransmissionScope.rawValue, forKey: Keys.aiTransmissionScope) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        self.notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        self.soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        self.hapticsEnabled = defaults.object(forKey: Keys.hapticsEnabled) as? Bool ?? true
        self.keepScreenOn = defaults.bool(forKey: Keys.keepScreenOn)

        self.heightCm = (defaults.object(forKey: Keys.heightCm) as? Int) ?? 170
        self.ageYears = (defaults.object(forKey: Keys.ageYears) as? Int) ?? 30

        if let raw = defaults.string(forKey: Keys.biologicalSex),
           let value = BiologicalSex(rawValue: raw) {
            self.biologicalSex = value
        } else {
            self.biologicalSex = .unspecified
        }

        if let raw = defaults.string(forKey: Keys.activityFactor),
           let value = ActivityFactor(rawValue: raw) {
            self.activityFactor = value
        } else {
            self.activityFactor = .moderate
        }

        self.goalWeightKg = (defaults.object(forKey: Keys.goalWeightKg) as? Double) ?? 65.0
        self.weeklyChangeKg = (defaults.object(forKey: Keys.weeklyChangeKg) as? Double) ?? -0.5

        if let raw = defaults.string(forKey: Keys.aiTransmissionScope),
           let value = AITransmissionScope(rawValue: raw) {
            self.aiTransmissionScope = value
        } else {
            self.aiTransmissionScope = .standard
        }

        ScreenWakeManager.apply(keepScreenOn)
    }

    // MARK: Derived metrics
    //
    // All four accessors are thin pass-throughs to `GoalCalculator` so
    // SettingsStore and `UserProfile` share the same math. The legacy
    // signature is preserved so SettingsView keeps working without
    // changes.

    /// Mifflin-St Jeor BMR using the supplied current weight (kg).
    /// Returns nil if `currentWeightKg` is nil and no goal weight is
    /// available either.
    func bmr(currentWeightKg: Double?) -> Int? {
        guard let weight = effectiveWeight(currentWeightKg: currentWeightKg) else { return nil }
        return GoalCalculator.bmr(
            weightKg: weight,
            heightCm: heightCm,
            ageYears: ageYears,
            biologicalSex: biologicalSex
        )
    }

    /// TDEE = BMR × PAL.
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

    /// Daily kcal adjustment implied by the weekly weight-change goal
    /// (1 kg of body fat ≈ 7700 kcal).
    var dailyKcalAdjustment: Int {
        GoalCalculator.dailyKcalAdjustment(weeklyChangeKg: weeklyChangeKg)
    }

    /// Target daily intake = TDEE + daily adjustment (negative for cut).
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

    /// Today's intake − target. Negative = under target.
    /// Returns nil when target cannot be computed.
    func todayGoalGap(todayIntake: Int, currentWeightKg: Double?) -> Int? {
        guard let target = targetIntake(currentWeightKg: currentWeightKg) else { return nil }
        return GoalCalculator.todayGoalGap(todayIntake: todayIntake, targetIntake: target)
    }

    private func effectiveWeight(currentWeightKg: Double?) -> Double? {
        if let measured = currentWeightKg, measured > 0 { return measured }
        return goalWeightKg > 0 ? goalWeightKg : nil
    }

    private enum Keys {
        // Existing
        static let notificationsEnabled = "settings.notificationsEnabled"
        static let soundEnabled = "settings.soundEnabled"
        static let hapticsEnabled = "settings.hapticsEnabled"
        static let keepScreenOn = "settings.keepScreenOn"
        // Profile
        static let heightCm = "settings.heightCm"
        static let ageYears = "settings.ageYears"
        static let biologicalSex = "settings.biologicalSex"
        static let activityFactor = "settings.activityFactor"
        // Goals
        static let goalWeightKg = "settings.goalWeightKg"
        static let weeklyChangeKg = "settings.weeklyChangeKg"
        // AI
        static let aiTransmissionScope = "settings.aiTransmissionScope"
    }
}
