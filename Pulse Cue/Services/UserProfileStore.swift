//
//  UserProfileStore.swift
//  Pulse Cue
//
//  Lazy fetch / create + one-way migration from SettingsStore so we
//  end up with a single canonical UserProfile record per device.
//  SettingsStore continues to drive the existing SettingsView bindings
//  for now; UserProfile is the storage layer we're consolidating onto.
//

import Foundation
import SwiftData

@MainActor
enum UserProfileStore {

    /// Returns the existing `UserProfile`. On first call, creates one
    /// seeded from `SettingsStore` (so the user's existing profile and
    /// goal values are carried across).
    static func fetchOrCreate(
        modelContext: ModelContext,
        seeding settings: SettingsStore? = nil
    ) -> UserProfile {
        if let existing = current(modelContext: modelContext) {
            return existing
        }
        let profile = UserProfile(
            heightCm: settings?.heightCm ?? 170,
            ageYears: settings?.ageYears ?? 30,
            biologicalSex: settings?.biologicalSex ?? .unspecified,
            activityFactor: settings?.activityFactor ?? .moderate,
            goalWeightKg: settings?.goalWeightKg ?? 65.0,
            weeklyChangeKg: settings?.weeklyChangeKg ?? -0.5
        )
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
}
