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
//  One profile per owner — guest, account A, account B — is this type's
//  contract, not the schema's. Every read goes through `select(from:scope:)`,
//  so a store that already holds two rows for one owner (an older build, a
//  race) still resolves to the same row on every screen: newest `updatedAt`,
//  then lowest `id`. The extra row is left alone — deleting it would be a
//  guess about which one the person meant to keep.
//

import Foundation
import SwiftData

@MainActor
enum UserProfileStore {

    /// The scope's profile, inserted if it has none. Nil while the scope is
    /// undetermined.
    ///
    /// Only a guest profile is seeded from the legacy `SettingsStore` keys:
    /// they were written on this device before accounts existed, which is
    /// what guest data means. An account's first profile starts from the
    /// defaults rather than inheriting whoever used the device before — that
    /// handover is adoption's job, and it asks first.
    ///
    /// The legacy keys are not deleted; SettingsStore no longer reads
    /// them, but they remain as a safety net for downgrade scenarios.
    @discardableResult
    static func fetchOrCreateProfile(
        for scope: HealthDataScope,
        modelContext: ModelContext,
        legacyDefaults: UserDefaults = .standard
    ) -> UserProfile? {
        guard scope.canCreateHealthData else { return nil }
        if let existing = profile(for: scope, modelContext: modelContext) {
            return existing
        }
        let profile: UserProfile
        if case let .account(id) = scope {
            profile = UserProfile(ownerAccountID: id)
        } else {
            profile = makeProfile(fromLegacy: legacyDefaults)
        }
        modelContext.insert(profile)
        return profile
    }

    /// The scope's profile if one is stored. Never inserts.
    static func profile(for scope: HealthDataScope, modelContext: ModelContext) -> UserProfile? {
        let descriptor: FetchDescriptor<UserProfile>
        switch scope {
        case .undetermined:
            return nil
        case .guest:
            descriptor = FetchDescriptor<UserProfile>(
                predicate: #Predicate<UserProfile> { $0.ownerAccountID == nil }
            )
        case let .account(id):
            descriptor = FetchDescriptor<UserProfile>(
                predicate: #Predicate<UserProfile> { $0.ownerAccountID == id }
            )
        }
        return select(from: (try? modelContext.fetch(descriptor)) ?? [], scope: scope)
    }

    /// The one profile `scope` resolves to among `profiles` — which may be
    /// every profile on the device, as a view's `@Query` returns them.
    nonisolated static func select(from profiles: [UserProfile], scope: HealthDataScope) -> UserProfile? {
        scope.visible(profiles).min { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
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
