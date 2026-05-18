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
}
