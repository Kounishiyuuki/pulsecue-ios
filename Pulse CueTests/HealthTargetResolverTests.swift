//
//  HealthTargetResolverTests.swift
//  Pulse CueTests
//
//  Locks in the documented resolution priority for
//  `HealthTargetResolver`:
//
//      1. date-specific override
//      2. weekday override
//      3. default target
//      4. nil (no layer configures the metric)
//
//  Per-metric independence is also exercised: a weekday override that
//  only sets sleep must NOT shadow defaults for intake / exercise /
//  balance. This is the contract that lets the UI keep weekday rows
//  short (you only state what changes).
//
//  All test dates are constructed via DateComponents so we don't rely
//  on the test-runner's clock. We use 2026-04-13 (a Monday in the
//  Gregorian calendar) as the canonical "weekday under test" date.
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct HealthTargetResolverTests {

    // MARK: - Fixtures

    private static var calendar: Calendar { Calendar(identifier: .gregorian) }

    /// 2026-04-13 09:30 local — a Monday.
    private static func mondayDate() -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 4
        comps.day = 13
        comps.hour = 9
        comps.minute = 30
        return calendar.date(from: comps)!
    }

    /// Same Monday but 23:59 — to confirm time-of-day doesn't change
    /// which weekday/date bucket the resolver picks.
    private static func mondayLateDate() -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 4
        comps.day = 13
        comps.hour = 23
        comps.minute = 59
        return calendar.date(from: comps)!
    }

    /// 2026-04-14 — the Tuesday that immediately follows.
    private static func tuesdayDate() -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 4
        comps.day = 14
        comps.hour = 10
        return calendar.date(from: comps)!
    }

    // MARK: - Default target (priority 3)

    @Test func defaultTargetIsReturnedWhenNoOverridesApply() {
        let settings = HealthTargetSettings(
            defaults: HealthTargets(
                intakeCalories: 2000,
                sleepMinutes: 420,
                exerciseCalories: 300,
                balanceCalories: 1700,
            ),
        )
        let date = Self.mondayDate()
        #expect(HealthTargetResolver.resolve(metric: .intakeCalories, date: date, settings: settings, calendar: Self.calendar) == 2000)
        #expect(HealthTargetResolver.resolve(metric: .sleepMinutes, date: date, settings: settings, calendar: Self.calendar) == 420)
        #expect(HealthTargetResolver.resolve(metric: .exerciseCalories, date: date, settings: settings, calendar: Self.calendar) == 300)
        #expect(HealthTargetResolver.resolve(metric: .balanceCalories, date: date, settings: settings, calendar: Self.calendar) == 1700)
        #expect(HealthTargetResolver.layer(for: .intakeCalories, date: date, settings: settings, calendar: Self.calendar) == .defaultTarget)
    }

    @Test func unsetMetricReturnsNilEvenWhenOtherDefaultsExist() {
        // Only intake is configured. Sleep / exercise / balance must
        // resolve to nil even though `defaults` is non-empty.
        let settings = HealthTargetSettings(
            defaults: HealthTargets(intakeCalories: 2200),
        )
        let date = Self.mondayDate()
        #expect(HealthTargetResolver.resolve(metric: .intakeCalories, date: date, settings: settings, calendar: Self.calendar) == 2200)
        #expect(HealthTargetResolver.resolve(metric: .sleepMinutes, date: date, settings: settings, calendar: Self.calendar) == nil)
        #expect(HealthTargetResolver.resolve(metric: .exerciseCalories, date: date, settings: settings, calendar: Self.calendar) == nil)
        #expect(HealthTargetResolver.resolve(metric: .balanceCalories, date: date, settings: settings, calendar: Self.calendar) == nil)
        #expect(HealthTargetResolver.layer(for: .sleepMinutes, date: date, settings: settings, calendar: Self.calendar) == .none)
    }

    // MARK: - Weekday override (priority 2)

    @Test func weekdayOverrideShadowsDefaultOnlyForConfiguredMetrics() {
        // Monday sleep target = 480, others fall through to defaults.
        let settings = HealthTargetSettings(
            defaults: HealthTargets(intakeCalories: 2000, sleepMinutes: 420),
            weekdayOverrides: [.monday: HealthTargets(sleepMinutes: 480)],
        )
        let monday = Self.mondayDate()
        #expect(HealthTargetResolver.resolve(metric: .sleepMinutes, date: monday, settings: settings, calendar: Self.calendar) == 480)
        #expect(HealthTargetResolver.resolve(metric: .intakeCalories, date: monday, settings: settings, calendar: Self.calendar) == 2000)
        #expect(HealthTargetResolver.layer(for: .sleepMinutes, date: monday, settings: settings, calendar: Self.calendar) == .weekdayOverride)
        #expect(HealthTargetResolver.layer(for: .intakeCalories, date: monday, settings: settings, calendar: Self.calendar) == .defaultTarget)
    }

    @Test func weekdayOverrideAppliesOnlyOnMatchingWeekday() {
        // Monday gets +200 intake; Tuesday should use the default.
        let settings = HealthTargetSettings(
            defaults: HealthTargets(intakeCalories: 2000),
            weekdayOverrides: [.monday: HealthTargets(intakeCalories: 2200)],
        )
        #expect(HealthTargetResolver.resolve(metric: .intakeCalories, date: Self.mondayDate(), settings: settings, calendar: Self.calendar) == 2200)
        #expect(HealthTargetResolver.resolve(metric: .intakeCalories, date: Self.tuesdayDate(), settings: settings, calendar: Self.calendar) == 2000)
    }

    @Test func weekdayOverrideIsTimeOfDayIndependent() {
        // Same Monday at 09:30 and 23:59 must resolve to the same value.
        let settings = HealthTargetSettings(
            defaults: HealthTargets(sleepMinutes: 420),
            weekdayOverrides: [.monday: HealthTargets(sleepMinutes: 480)],
        )
        let morning = HealthTargetResolver.resolve(metric: .sleepMinutes, date: Self.mondayDate(), settings: settings, calendar: Self.calendar)
        let lateNight = HealthTargetResolver.resolve(metric: .sleepMinutes, date: Self.mondayLateDate(), settings: settings, calendar: Self.calendar)
        #expect(morning == 480)
        #expect(lateNight == 480)
    }

    // MARK: - Date-specific override (priority 1)

    @Test func dateOverrideWinsOverWeekdayAndDefault() {
        let monday = Self.mondayDate()
        let dayKey = Self.calendar.startOfDay(for: monday)
        let settings = HealthTargetSettings(
            defaults: HealthTargets(intakeCalories: 2000),
            weekdayOverrides: [.monday: HealthTargets(intakeCalories: 2200)],
            dateOverrides: [dayKey: HealthTargets(intakeCalories: 2500)],
        )
        #expect(HealthTargetResolver.resolve(metric: .intakeCalories, date: monday, settings: settings, calendar: Self.calendar) == 2500)
        #expect(HealthTargetResolver.layer(for: .intakeCalories, date: monday, settings: settings, calendar: Self.calendar) == .dateOverride)
    }

    @Test func dateOverridePartialFieldsFallThroughPerMetric() {
        // Date override sets only exercise — intake falls back to the
        // weekday override; sleep falls back to defaults.
        let monday = Self.mondayDate()
        let dayKey = Self.calendar.startOfDay(for: monday)
        let settings = HealthTargetSettings(
            defaults: HealthTargets(intakeCalories: 2000, sleepMinutes: 420),
            weekdayOverrides: [.monday: HealthTargets(intakeCalories: 2200)],
            dateOverrides: [dayKey: HealthTargets(exerciseCalories: 600)],
        )
        #expect(HealthTargetResolver.resolve(metric: .exerciseCalories, date: monday, settings: settings, calendar: Self.calendar) == 600)
        #expect(HealthTargetResolver.layer(for: .exerciseCalories, date: monday, settings: settings, calendar: Self.calendar) == .dateOverride)
        #expect(HealthTargetResolver.resolve(metric: .intakeCalories, date: monday, settings: settings, calendar: Self.calendar) == 2200)
        #expect(HealthTargetResolver.layer(for: .intakeCalories, date: monday, settings: settings, calendar: Self.calendar) == .weekdayOverride)
        #expect(HealthTargetResolver.resolve(metric: .sleepMinutes, date: monday, settings: settings, calendar: Self.calendar) == 420)
        #expect(HealthTargetResolver.layer(for: .sleepMinutes, date: monday, settings: settings, calendar: Self.calendar) == .defaultTarget)
    }

    @Test func dateOverrideAppliesOnlyOnExactStartOfDay() {
        // Only Monday has a date override. Tuesday must skip it.
        let monday = Self.mondayDate()
        let dayKey = Self.calendar.startOfDay(for: monday)
        let settings = HealthTargetSettings(
            defaults: HealthTargets(intakeCalories: 2000),
            dateOverrides: [dayKey: HealthTargets(intakeCalories: 2500)],
        )
        #expect(HealthTargetResolver.resolve(metric: .intakeCalories, date: monday, settings: settings, calendar: Self.calendar) == 2500)
        #expect(HealthTargetResolver.resolve(metric: .intakeCalories, date: Self.tuesdayDate(), settings: settings, calendar: Self.calendar) == 2000)
    }

    // MARK: - Missing-target fallback

    @Test func emptySettingsReturnNilForEveryMetric() {
        let settings = HealthTargetSettings.empty
        let date = Self.mondayDate()
        for metric in HealthTargetMetric.allCases {
            #expect(HealthTargetResolver.resolve(metric: metric, date: date, settings: settings, calendar: Self.calendar) == nil)
            #expect(HealthTargetResolver.layer(for: metric, date: date, settings: settings, calendar: Self.calendar) == .none)
        }
    }

    @Test func resolveAllProducesAllFourMetricsAtOnce() {
        let monday = Self.mondayDate()
        let dayKey = Self.calendar.startOfDay(for: monday)
        let settings = HealthTargetSettings(
            defaults: HealthTargets(intakeCalories: 2000, sleepMinutes: 420, balanceCalories: 1700),
            weekdayOverrides: [.monday: HealthTargets(sleepMinutes: 480)],
            dateOverrides: [dayKey: HealthTargets(exerciseCalories: 600)],
        )
        let resolved = HealthTargetResolver.resolveAll(date: monday, settings: settings, calendar: Self.calendar)
        #expect(resolved.intakeCalories == 2000)         // default
        #expect(resolved.sleepMinutes == 480)            // weekday
        #expect(resolved.exerciseCalories == 600)        // date
        #expect(resolved.balanceCalories == 1700)        // default
    }

    // MARK: - Store round-trip (encoding stability)

    @Test func storeRoundTripsAllThreeLayers() {
        let suiteName = "health-target-store-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let store = HealthTargetStore(defaults: suite, storageKey: "test.key")
        let monday = Self.mondayDate()

        store.updateDefaults(HealthTargets(intakeCalories: 2000, sleepMinutes: 420))
        store.updateWeekdayOverride(.monday, targets: HealthTargets(sleepMinutes: 480))
        store.updateDateOverride(monday, targets: HealthTargets(intakeCalories: 2500))

        // Re-hydrate from the same UserDefaults and confirm resolver
        // still walks all three layers correctly.
        let reloaded = HealthTargetStore(defaults: suite, storageKey: "test.key")
        #expect(HealthTargetResolver.resolve(metric: .intakeCalories, date: monday, settings: reloaded.settings, calendar: Self.calendar) == 2500)
        #expect(HealthTargetResolver.resolve(metric: .sleepMinutes, date: monday, settings: reloaded.settings, calendar: Self.calendar) == 480)
        #expect(HealthTargetResolver.resolve(metric: .intakeCalories, date: Self.tuesdayDate(), settings: reloaded.settings, calendar: Self.calendar) == 2000)
    }

    @Test func storeClearsEmptyOverrides() {
        let suiteName = "health-target-store-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let store = HealthTargetStore(defaults: suite, storageKey: "test.key")
        store.updateWeekdayOverride(.monday, targets: HealthTargets(sleepMinutes: 480))
        #expect(store.settings.weekdayOverrides[.monday] != nil)
        // Writing an empty target set should remove the entry.
        store.updateWeekdayOverride(.monday, targets: HealthTargets())
        #expect(store.settings.weekdayOverrides[.monday] == nil)
    }

    // MARK: - Date override store API (PR #37)

    /// Writing then clearing a date override updates the resolver
    /// view of the world: after clear, the metric falls back to the
    /// weekday/default layer.
    @Test func storeDateOverrideFallsBackAfterClear() {
        let suiteName = "health-target-store-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let store = HealthTargetStore(defaults: suite, storageKey: "test.key")
        store.updateDefaults(HealthTargets(intakeCalories: 2000))
        store.updateWeekdayOverride(.monday, targets: HealthTargets(intakeCalories: 2200))

        let monday = Self.mondayDate()
        store.updateDateOverride(monday, targets: HealthTargets(intakeCalories: 2500))

        #expect(HealthTargetResolver.resolve(metric: .intakeCalories, date: monday, settings: store.settings, calendar: Self.calendar) == 2500)

        store.clearDateOverride(monday)
        // Now weekday override should drive the value.
        #expect(HealthTargetResolver.resolve(metric: .intakeCalories, date: monday, settings: store.settings, calendar: Self.calendar) == 2200)
        // And the dictionary entry is gone.
        let dayKey = Self.calendar.startOfDay(for: monday)
        #expect(store.settings.dateOverrides[dayKey] == nil)
    }

    /// Writing an empty `HealthTargets` for a date entry removes it
    /// automatically. This is the same auto-cleanup behavior used for
    /// weekday overrides and is the contract the Date UI relies on
    /// when the user clears every field in an override row.
    @Test func storeAutoRemovesEmptyDateOverride() {
        let suiteName = "health-target-store-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let store = HealthTargetStore(defaults: suite, storageKey: "test.key")
        let monday = Self.mondayDate()
        store.updateDateOverride(monday, targets: HealthTargets(sleepMinutes: 510))
        let dayKey = Self.calendar.startOfDay(for: monday)
        #expect(store.settings.dateOverrides[dayKey] != nil)

        store.updateDateOverride(monday, targets: HealthTargets())
        #expect(store.settings.dateOverrides[dayKey] == nil)
    }

    /// Different times within the same local day must collapse to the
    /// same dictionary key — otherwise an override saved at 09:00
    /// would not be returned for the same day at 23:00.
    @Test func storeDateOverrideUsesLocalDayBoundary() {
        let suiteName = "health-target-store-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let store = HealthTargetStore(defaults: suite, storageKey: "test.key")
        let morning = Self.mondayDate()       // 09:30
        let lateNight = Self.mondayLateDate() // 23:59 — same local day

        store.updateDateOverride(morning, targets: HealthTargets(intakeCalories: 2500))

        // The late-night Date should resolve through the same key.
        #expect(HealthTargetResolver.resolve(metric: .intakeCalories, date: lateNight, settings: store.settings, calendar: Self.calendar) == 2500)
        // Exactly one dictionary entry — no duplicate at 23:59.
        #expect(store.settings.dateOverrides.count == 1)
    }

    /// Two distinct local days must each get their own dictionary
    /// entry. Locks the per-day isolation when the user adds back-to-
    /// back overrides for, e.g., a weekend trip.
    @Test func storeKeepsSeparateEntriesForDifferentDates() {
        let suiteName = "health-target-store-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let store = HealthTargetStore(defaults: suite, storageKey: "test.key")
        let monday = Self.mondayDate()
        let tuesday = Self.tuesdayDate()

        store.updateDateOverride(monday, targets: HealthTargets(intakeCalories: 2500))
        store.updateDateOverride(tuesday, targets: HealthTargets(intakeCalories: 1800))

        #expect(store.settings.dateOverrides.count == 2)
        #expect(HealthTargetResolver.resolve(metric: .intakeCalories, date: monday, settings: store.settings, calendar: Self.calendar) == 2500)
        #expect(HealthTargetResolver.resolve(metric: .intakeCalories, date: tuesday, settings: store.settings, calendar: Self.calendar) == 1800)

        // Clearing one date does not affect the other.
        store.clearDateOverride(monday)
        let mondayKey = Self.calendar.startOfDay(for: monday)
        let tuesdayKey = Self.calendar.startOfDay(for: tuesday)
        #expect(store.settings.dateOverrides[mondayKey] == nil)
        #expect(store.settings.dateOverrides[tuesdayKey] != nil)
    }

    /// Date-override round-trip across a re-loaded store: the date
    /// keys must survive the `yyyy-MM-dd` encoding used in
    /// `health.targetSettings.v1`, and the resolver must still pick
    /// them up after re-hydration.
    @Test func storeDateOverridePersistsAcrossRehydration() {
        let suiteName = "health-target-store-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let store = HealthTargetStore(defaults: suite, storageKey: "test.key")
        let monday = Self.mondayDate()
        store.updateDateOverride(monday, targets: HealthTargets(
            intakeCalories: 2500,
            sleepMinutes: 510,
            exerciseCalories: 600,
            balanceCalories: 1800,
        ))

        let reloaded = HealthTargetStore(defaults: suite, storageKey: "test.key")
        let resolved = HealthTargetResolver.resolveAll(date: monday, settings: reloaded.settings, calendar: Self.calendar)
        #expect(resolved.intakeCalories == 2500)
        #expect(resolved.sleepMinutes == 510)
        #expect(resolved.exerciseCalories == 600)
        #expect(resolved.balanceCalories == 1800)
    }
}
