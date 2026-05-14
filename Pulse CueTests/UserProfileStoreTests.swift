//
//  UserProfileStoreTests.swift
//  Pulse CueTests
//
//  Boundary tests for the SwiftData `UserProfile` model and its
//  `UserProfileStore` fetch-or-create helper. Covers:
//   - fetchOrCreate creates a profile when none exists
//   - fetchOrCreate returns the same profile on subsequent calls
//   - default values are safe (no nil / no negative)
//   - profile mutations flow into BMR / TDEE / target intake
//   - SettingsStore preferences are independent from UserProfile
//   - legacy UserDefaults values seed the first UserProfile
//
//  Uses an in-memory SwiftData ModelContainer + an isolated
//  UserDefaults suite per test to avoid cross-test contamination.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct UserProfileStoreTests {

    private static func makeContext() throws -> ModelContext {
        let schema = Schema([
            Routine.self,
            Step.self,
            Session.self,
            StepResult.self,
            DayLog.self,
            MealEntry.self,
            UserProfile.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private static func makeIsolatedDefaults() -> UserDefaults {
        let suite = "test.profile.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    // MARK: - fetchOrCreate

    @Test
    func fetchOrCreateCreatesProfileWhenMissing() throws {
        let context = try Self.makeContext()
        let defaults = Self.makeIsolatedDefaults()

        #expect(UserProfileStore.current(modelContext: context) == nil)

        let profile = UserProfileStore.fetchOrCreate(modelContext: context, legacyDefaults: defaults)
        let all = try context.fetch(FetchDescriptor<UserProfile>())
        #expect(all.count == 1)
        #expect(all.first?.id == profile.id)
    }

    @Test
    func fetchOrCreateReturnsExistingProfileWithoutCreatingDuplicates() throws {
        let context = try Self.makeContext()
        let defaults = Self.makeIsolatedDefaults()

        let first = UserProfileStore.fetchOrCreate(modelContext: context, legacyDefaults: defaults)
        let second = UserProfileStore.fetchOrCreate(modelContext: context, legacyDefaults: defaults)
        let third = UserProfileStore.fetchOrCreate(modelContext: context, legacyDefaults: defaults)

        #expect(first === second)
        #expect(second === third)
        let all = try context.fetch(FetchDescriptor<UserProfile>())
        #expect(all.count == 1)
    }

    // MARK: - Defaults

    @Test
    func profileDefaultsAreSafeWhenNoLegacyValues() throws {
        let context = try Self.makeContext()
        let defaults = Self.makeIsolatedDefaults() // empty

        let profile = UserProfileStore.fetchOrCreate(modelContext: context, legacyDefaults: defaults)

        #expect(profile.heightCm == 170)
        #expect(profile.ageYears == 30)
        #expect(profile.biologicalSex == .unspecified)
        #expect(profile.activityFactor == .moderate)
        #expect(profile.goalWeightKg == 65.0)
        #expect(profile.weeklyChangeKg == -0.5)
        // Init still clamps negatives — sanity check.
        #expect(profile.heightCm >= 0)
        #expect(profile.ageYears >= 0)
        #expect(profile.goalWeightKg >= 0)
    }

    // MARK: - Profile mutations propagate to calculations

    @Test
    func updatingProfileValuesChangesGoalCalculations() throws {
        let context = try Self.makeContext()
        let defaults = Self.makeIsolatedDefaults()

        let profile = UserProfileStore.fetchOrCreate(modelContext: context, legacyDefaults: defaults)
        let baselineBMR = try #require(profile.bmr(currentWeightKg: 70))
        let baselineTDEE = try #require(profile.tdee(currentWeightKg: 70))

        // Switch to .male and a higher activity tier; both should
        // increase BMR and TDEE.
        profile.biologicalSex = .male
        profile.activityFactor = .veryActive

        let newBMR = try #require(profile.bmr(currentWeightKg: 70))
        let newTDEE = try #require(profile.tdee(currentWeightKg: 70))
        #expect(newBMR > baselineBMR)
        #expect(newTDEE > baselineTDEE)

        // Capture target with the new TDEE but original weekly rate,
        // then bump the deficit and verify it drops below that target.
        let targetBeforeDeficitBump = try #require(profile.targetIntake(currentWeightKg: 70))
        profile.weeklyChangeKg = -1.0
        let newTarget = try #require(profile.targetIntake(currentWeightKg: 70))
        #expect(newTarget < targetBeforeDeficitBump)

        // Goal gap is the signed difference from the new target.
        #expect(profile.todayGoalGap(todayIntake: 1500, currentWeightKg: 70) == 1500 - newTarget)
    }

    @Test
    func mutatingProfileUpdatesUpdatedAt() throws {
        let context = try Self.makeContext()
        let defaults = Self.makeIsolatedDefaults()

        let profile = UserProfileStore.fetchOrCreate(modelContext: context, legacyDefaults: defaults)
        let originalTimestamp = profile.updatedAt

        // The enum setters bump updatedAt explicitly.
        profile.biologicalSex = .male
        #expect(profile.updatedAt > originalTimestamp)
    }

    // MARK: - Settings independence

    @Test
    func settingsPreferencesAreIndependentFromUserProfile() throws {
        let context = try Self.makeContext()
        let defaults = Self.makeIsolatedDefaults()
        let settings = SettingsStore(defaults: defaults)

        let profile = UserProfileStore.fetchOrCreate(modelContext: context, legacyDefaults: defaults)
        let snapshotHeight = profile.heightCm
        let snapshotAge = profile.ageYears
        let snapshotSex = profile.biologicalSex

        // Flipping app-side preferences must not touch profile fields.
        settings.notificationsEnabled.toggle()
        settings.soundEnabled.toggle()
        settings.hapticsEnabled.toggle()
        settings.keepScreenOn.toggle()
        settings.aiTransmissionScope = .extended

        #expect(profile.heightCm == snapshotHeight)
        #expect(profile.ageYears == snapshotAge)
        #expect(profile.biologicalSex == snapshotSex)
    }

    // MARK: - Legacy UserDefaults migration

    @Test
    func fetchOrCreateSeedsProfileFromLegacyUserDefaults() throws {
        let context = try Self.makeContext()
        let defaults = Self.makeIsolatedDefaults()

        // Pre-populate the legacy keys SettingsStore used to write.
        defaults.set(178, forKey: "settings.heightCm")
        defaults.set(42, forKey: "settings.ageYears")
        defaults.set(BiologicalSex.male.rawValue, forKey: "settings.biologicalSex")
        defaults.set(ActivityFactor.active.rawValue, forKey: "settings.activityFactor")
        defaults.set(72.5, forKey: "settings.goalWeightKg")
        defaults.set(-0.3, forKey: "settings.weeklyChangeKg")

        let profile = UserProfileStore.fetchOrCreate(modelContext: context, legacyDefaults: defaults)
        #expect(profile.heightCm == 178)
        #expect(profile.ageYears == 42)
        #expect(profile.biologicalSex == .male)
        #expect(profile.activityFactor == .active)
        #expect(profile.goalWeightKg == 72.5)
        #expect(profile.weeklyChangeKg == -0.3)
    }

    @Test
    func legacyMigrationOnlyRunsOnFirstFetch() throws {
        let context = try Self.makeContext()
        let defaults = Self.makeIsolatedDefaults()

        defaults.set(160, forKey: "settings.heightCm")
        let first = UserProfileStore.fetchOrCreate(modelContext: context, legacyDefaults: defaults)
        #expect(first.heightCm == 160)

        // Mutate the existing profile, then mutate the legacy defaults
        // and verify a subsequent fetch does NOT re-seed from defaults.
        first.heightCm = 175
        defaults.set(190, forKey: "settings.heightCm")

        let second = UserProfileStore.fetchOrCreate(modelContext: context, legacyDefaults: defaults)
        #expect(second === first)
        #expect(second.heightCm == 175)
    }
}
