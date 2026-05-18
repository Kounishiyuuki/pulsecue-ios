//
//  HealthTargetWeeklyAverageTests.swift
//  Pulse CueTests
//
//  Locks in the weekly-average target rule used by HealthSummary:
//
//      For each date in [endDate - 6, endDate]:
//          resolve target via HealthTargetResolver
//          include non-nil values only
//      Return floor(sum / count), or nil when the window has no
//      configured target at all.
//
//  Coverage:
//   - default-only target → average equals the default
//   - weekday override → affects only matching dates in the window
//   - date override → wins for that single date
//   - empty settings → nil
//   - partial coverage (only some days configured) → averages the
//     configured days, not the whole window
//   - non-default window size honored
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct HealthTargetWeeklyAverageTests {

    private static var calendar: Calendar { Calendar(identifier: .gregorian) }

    /// 2026-04-19 12:00 — a Sunday. Lets the 7-day window land on
    /// 2026-04-13 (Mon) ... 2026-04-19 (Sun).
    private static func sundayEndDate() -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 19
        comps.hour = 12
        return calendar.date(from: comps)!
    }

    // MARK: - Defaults only

    @Test func defaultOnlyAverageEqualsDefault() {
        let settings = HealthTargetSettings(
            defaults: HealthTargets(intakeCalories: 2000, sleepMinutes: 420)
        )
        let avgIntake = HealthTargetWeeklyAverage.averageTarget(
            metric: .intakeCalories,
            endingAt: Self.sundayEndDate(),
            settings: settings,
            calendar: Self.calendar
        )
        let avgSleep = HealthTargetWeeklyAverage.averageTarget(
            metric: .sleepMinutes,
            endingAt: Self.sundayEndDate(),
            settings: settings,
            calendar: Self.calendar
        )
        #expect(avgIntake == 2000)
        #expect(avgSleep == 420)
    }

    // MARK: - Weekday override

    @Test func weekdayOverrideAffectsOnlyMatchingDates() {
        // Default = 2000. Monday gets 2700.
        // Window 2026-04-13 (Mon) .. 2026-04-19 (Sun) has 1 Monday.
        // Expected average = (2700 + 6 * 2000) / 7 = 14700/7 = 2100.
        let settings = HealthTargetSettings(
            defaults: HealthTargets(intakeCalories: 2000),
            weekdayOverrides: [.monday: HealthTargets(intakeCalories: 2700)],
        )
        let avg = HealthTargetWeeklyAverage.averageTarget(
            metric: .intakeCalories,
            endingAt: Self.sundayEndDate(),
            settings: settings,
            calendar: Self.calendar
        )
        #expect(avg == 2100)
    }

    @Test func weekdayOverrideOnlyShadowsConfiguredMetric() {
        // Weekday override sets sleep only; intake must keep default.
        let settings = HealthTargetSettings(
            defaults: HealthTargets(intakeCalories: 2000, sleepMinutes: 420),
            weekdayOverrides: [.saturday: HealthTargets(sleepMinutes: 540)],
        )
        // Window includes 2026-04-18 (Sat). Saturday sleep = 540, the
        // other 6 days = 420 → avg = (540 + 6*420)/7 = 3060/7 = 437.
        let avgSleep = HealthTargetWeeklyAverage.averageTarget(
            metric: .sleepMinutes,
            endingAt: Self.sundayEndDate(),
            settings: settings,
            calendar: Self.calendar
        )
        let avgIntake = HealthTargetWeeklyAverage.averageTarget(
            metric: .intakeCalories,
            endingAt: Self.sundayEndDate(),
            settings: settings,
            calendar: Self.calendar
        )
        #expect(avgSleep == 437)
        #expect(avgIntake == 2000)
    }

    // MARK: - Date override

    @Test func dateOverrideWinsForSpecificDay() {
        // Default = 2000. Single date override on Saturday = 3000.
        // Other 6 days = 2000. Avg = (3000 + 6*2000)/7 = 15000/7 = 2142.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 18 // Saturday
        let saturday = Self.calendar.date(from: comps)!
        let satKey = Self.calendar.startOfDay(for: saturday)

        let settings = HealthTargetSettings(
            defaults: HealthTargets(intakeCalories: 2000),
            dateOverrides: [satKey: HealthTargets(intakeCalories: 3000)],
        )
        let avg = HealthTargetWeeklyAverage.averageTarget(
            metric: .intakeCalories,
            endingAt: Self.sundayEndDate(),
            settings: settings,
            calendar: Self.calendar
        )
        #expect(avg == 2142)
    }

    @Test func dateOverrideOutsideWindowDoesNotAffectAverage() {
        // Date override 10 days before endDate → outside the 7-day
        // window → no effect on the average.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 9
        let outsideDate = Self.calendar.date(from: comps)!
        let outsideKey = Self.calendar.startOfDay(for: outsideDate)

        let settings = HealthTargetSettings(
            defaults: HealthTargets(intakeCalories: 2000),
            dateOverrides: [outsideKey: HealthTargets(intakeCalories: 9999)],
        )
        let avg = HealthTargetWeeklyAverage.averageTarget(
            metric: .intakeCalories,
            endingAt: Self.sundayEndDate(),
            settings: settings,
            calendar: Self.calendar
        )
        #expect(avg == 2000)
    }

    // MARK: - Nil / partial coverage

    @Test func emptySettingsReturnsNil() {
        let avg = HealthTargetWeeklyAverage.averageTarget(
            metric: .intakeCalories,
            endingAt: Self.sundayEndDate(),
            settings: .empty,
            calendar: Self.calendar
        )
        #expect(avg == nil)
    }

    @Test func partialCoverageAveragesConfiguredDaysOnly() {
        // No defaults. Only Monday weekday gets a target of 2200.
        // Other 6 days resolve to nil. Average should be 2200 (single
        // configured day), not (2200/7).
        let settings = HealthTargetSettings(
            weekdayOverrides: [.monday: HealthTargets(intakeCalories: 2200)],
        )
        let avg = HealthTargetWeeklyAverage.averageTarget(
            metric: .intakeCalories,
            endingAt: Self.sundayEndDate(),
            settings: settings,
            calendar: Self.calendar
        )
        #expect(avg == 2200)
    }

    @Test func metricUnsetReturnsNilEvenWithOtherMetricsConfigured() {
        // Defaults configure intake but not sleep — sleep should
        // average to nil.
        let settings = HealthTargetSettings(
            defaults: HealthTargets(intakeCalories: 2000)
        )
        let avgSleep = HealthTargetWeeklyAverage.averageTarget(
            metric: .sleepMinutes,
            endingAt: Self.sundayEndDate(),
            settings: settings,
            calendar: Self.calendar
        )
        #expect(avgSleep == nil)
    }

    // MARK: - Window size

    @Test func customWindowSizeChangesAverage() {
        // 3-day window only: 2026-04-17 (Fri), 2026-04-18 (Sat),
        // 2026-04-19 (Sun). Weekday override on Saturday raises sleep
        // for 1 of the 3 days.
        let settings = HealthTargetSettings(
            defaults: HealthTargets(sleepMinutes: 420),
            weekdayOverrides: [.saturday: HealthTargets(sleepMinutes: 540)],
        )
        let avg = HealthTargetWeeklyAverage.averageTarget(
            metric: .sleepMinutes,
            endingAt: Self.sundayEndDate(),
            windowDays: 3,
            settings: settings,
            calendar: Self.calendar
        )
        // (540 + 420 + 420)/3 = 1380/3 = 460
        #expect(avg == 460)
    }

    @Test func clampedWindowOfOneIsValid() {
        // windowDays <= 0 is clamped to 1 → only endDate counted.
        let settings = HealthTargetSettings(
            defaults: HealthTargets(intakeCalories: 2000),
            weekdayOverrides: [.sunday: HealthTargets(intakeCalories: 2500)],
        )
        let avg = HealthTargetWeeklyAverage.averageTarget(
            metric: .intakeCalories,
            endingAt: Self.sundayEndDate(),  // Sunday
            windowDays: 0,
            settings: settings,
            calendar: Self.calendar
        )
        #expect(avg == 2500)
    }

    // MARK: - Balance kcal

    @Test func balanceAverageRespectsAllThreeLayers() {
        // Defaults balance = -500. Monday weekday override balance = -200.
        // Date override on Sat balance = +300.
        // Window: Mon=-200, Tue=-500, Wed=-500, Thu=-500, Fri=-500, Sat=+300, Sun=-500.
        // Sum = -200 + (-500)*5 + 300 = -200 -2500 +300 = -2400.
        // Swift Int division truncates toward zero: -2400 / 7 = -342.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 18 // Saturday
        let satKey = Self.calendar.startOfDay(for: Self.calendar.date(from: comps)!)
        let settings = HealthTargetSettings(
            defaults: HealthTargets(balanceCalories: -500),
            weekdayOverrides: [.monday: HealthTargets(balanceCalories: -200)],
            dateOverrides: [satKey: HealthTargets(balanceCalories: 300)],
        )
        let avg = HealthTargetWeeklyAverage.averageTarget(
            metric: .balanceCalories,
            endingAt: Self.sundayEndDate(),
            settings: settings,
            calendar: Self.calendar
        )
        #expect(avg == -342)
    }
}
