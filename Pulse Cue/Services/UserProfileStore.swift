//
//  UserProfileStore.swift
//  Pulse Cue
//
//  Single-source-of-truth helper for the `UserProfile` SwiftData
//  record. The first call after install reads the user's previous
//  profile values from UserDefaults (legacy SettingsStore storage)
//  and seeds the new `UserProfile` from them. After that, all reads
//  and writes flow through SwiftData via `@Query` + `@Bindable`.
//

import Foundation
import SwiftData

@MainActor
enum UserProfileStore {

    /// Returns the existing `UserProfile`. On first call, creates one
    /// seeded from the legacy `SettingsStore` UserDefaults keys (so a
    /// user upgrading from a pre-binding build keeps their height /
    /// age / sex / activity / goal weight / weekly rate).
    ///
    /// The legacy keys are not deleted; SettingsStore no longer reads
    /// them, but they remain as a safety net for downgrade scenarios.
    @discardableResult
    static func fetchOrCreate(
        modelContext: ModelContext,
        legacyDefaults: UserDefaults = .standard
    ) -> UserProfile {
        if let existing = current(modelContext: modelContext) {
            return existing
        }
        let profile = makeProfile(fromLegacy: legacyDefaults)
        modelContext.insert(profile)
        return profile
    }

    /// Returns the current `UserProfile` if one is already stored.
    /// Never inserts a new row.
    static func current(modelContext: ModelContext) -> UserProfile? {
        var descriptor = FetchDescriptor<UserProfile>(
            sortBy: [SortDescriptor(\UserProfile.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: - Migration from legacy UserDefaults

    private static func makeProfile(fromLegacy defaults: UserDefaults) -> UserProfile {
        let height = (defaults.object(forKey: LegacyKeys.heightCm) as? Int) ?? 170
        let age = (defaults.object(forKey: LegacyKeys.ageYears) as? Int) ?? 30

        let sex: BiologicalSex
        if let raw = defaults.string(forKey: LegacyKeys.biologicalSex),
           let value = BiologicalSex(rawValue: raw) {
            sex = value
        } else {
            sex = .unspecified
        }

        let activity: ActivityFactor
        if let raw = defaults.string(forKey: LegacyKeys.activityFactor),
           let value = ActivityFactor(rawValue: raw) {
            activity = value
        } else {
            activity = .moderate
        }

        let goalWeight = (defaults.object(forKey: LegacyKeys.goalWeightKg) as? Double) ?? 65.0
        let weeklyChange = (defaults.object(forKey: LegacyKeys.weeklyChangeKg) as? Double) ?? -0.5

        return UserProfile(
            heightCm: height,
            ageYears: age,
            biologicalSex: sex,
            activityFactor: activity,
            goalWeightKg: goalWeight,
            weeklyChangeKg: weeklyChange
        )
    }

    /// The UserDefaults keys SettingsStore used to write before the
    /// SwiftData migration. Held here for the one-shot read on
    /// `fetchOrCreate`. Do not introduce new writes against these.
    private enum LegacyKeys {
        static let heightCm = "settings.heightCm"
        static let ageYears = "settings.ageYears"
        static let biologicalSex = "settings.biologicalSex"
        static let activityFactor = "settings.activityFactor"
        static let goalWeightKg = "settings.goalWeightKg"
        static let weeklyChangeKg = "settings.weeklyChangeKg"
    }
}
