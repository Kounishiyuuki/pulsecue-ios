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
//  Source-of-truth note (see ProfileCalorieSourceConsistencyTests):
//   - `SettingsStore` holds **app preferences only** — notifications,
//     sound, haptics, keep-screen-on, and the AI transmission scope.
//     It is NOT a source of body metrics, goals, or calorie targets.
//   - Body metrics + goal (height / age / sex / activity / goal weight /
//     weekly change) live in `UserProfile` (SwiftData), which drives all
//     BMR / TDEE / target-intake calculations via `GoalCalculator`.
//     `UserProfileStore` seeds `UserProfile` once from the legacy
//     `settings.*` UserDefaults keys; after that `UserProfile` is
//     authoritative and `SettingsStore` no longer reads those keys.
//   - The `BiologicalSex` / `ActivityFactor` enums are *defined* in this
//     file for historical reasons, but the profile *values* are stored on
//     `UserProfile`, not here.
//   - Manual daily targets (Today's per-day / weekday / date overrides)
//     live in `HealthTargets` / `HealthTargetStore`; they are an explicit
//     override layer on top of the profile-calculated target, not a
//     competing profile source.
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

    // Integrations / AI preference (kept as an app-side toggle even
    // while AI is disabled, so the choice is ready when the feature
    // ships).
    @Published var aiTransmissionScope: AITransmissionScope {
        didSet { defaults.set(aiTransmissionScope.rawValue, forKey: Keys.aiTransmissionScope) }
    }

    // First-launch onboarding completion flag. This is the ONLY thing the
    // onboarding flow persists — no credential, token, or session state.
    // Defaults to `false`, so a fresh install (or cleared UserDefaults)
    // shows the onboarding once; after the user starts as a guest it stays
    // `true`. Reusing the same loopback/Required-Reason UserDefaults scope
    // declared in `PrivacyInfo.xcprivacy` (CA92.1).
    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        self.notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        self.soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        self.hapticsEnabled = defaults.object(forKey: Keys.hapticsEnabled) as? Bool ?? true
        self.keepScreenOn = defaults.bool(forKey: Keys.keepScreenOn)

        if let raw = defaults.string(forKey: Keys.aiTransmissionScope),
           let value = AITransmissionScope(rawValue: raw) {
            self.aiTransmissionScope = value
        } else {
            self.aiTransmissionScope = .standard
        }

        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)

        ScreenWakeManager.apply(keepScreenOn)
    }

    /// Marks the first-launch onboarding as completed (guest entry). Idempotent.
    func completeOnboarding() {
        hasCompletedOnboarding = true
    }

    private enum Keys {
        static let notificationsEnabled = "settings.notificationsEnabled"
        static let soundEnabled = "settings.soundEnabled"
        static let hapticsEnabled = "settings.hapticsEnabled"
        static let keepScreenOn = "settings.keepScreenOn"
        static let aiTransmissionScope = "settings.aiTransmissionScope"
        static let hasCompletedOnboarding = "settings.hasCompletedOnboarding"
    }
}
