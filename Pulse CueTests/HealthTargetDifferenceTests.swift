//
//  HealthTargetDifferenceTests.swift
//  Pulse CueTests
//
//  Locks in the human-readable difference text shown on Today cards.
//  Covers:
//   - intake / exercise / balance kcal: "あと N kcal" / "+N kcal" / "目標 達成"
//   - sleep minutes: "目標まで あと X時間Y分" / "+X時間Y分" / "目標 達成"
//   - nil fallbacks (no target / no value) return nil so callers can
//     keep the prior "no target" display
//   - tolerance bands (±50 kcal / ±10 minutes) trigger 達成
//   - integration with HealthTargetResolver for default / weekday /
//     date override priority on the same call site
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct HealthTargetDifferenceTests {

    // MARK: - kcal: nil fallback

    @Test func returnsNilWhenCurrentIsNil() {
        #expect(HealthTargetDifference.formatKcal(current: nil, target: 2000) == nil)
    }

    @Test func returnsNilWhenTargetIsNil() {
        #expect(HealthTargetDifference.formatKcal(current: 1500, target: nil) == nil)
    }

    @Test func returnsNilWhenBothAreNil() {
        #expect(HealthTargetDifference.formatKcal(current: nil, target: nil) == nil)
    }

    // MARK: - kcal: under target

    @Test func intakeUnderTargetShowsRemainingKcal() {
        let result = HealthTargetDifference.formatKcal(current: 1850, target: 2300)
        #expect(result?.direction == .under)
        #expect(result?.delta == -450)
        #expect(result?.label == "あと 450 kcal")
    }

    @Test func intakeFarBelowTargetUsesThousandsSeparator() {
        let result = HealthTargetDifference.formatKcal(current: 200, target: 2500)
        #expect(result?.label == "あと 2,300 kcal")
    }

    // MARK: - kcal: over target

    @Test func exerciseOverTargetShowsPlusKcal() {
        let result = HealthTargetDifference.formatKcal(current: 420, target: 350)
        #expect(result?.direction == .over)
        #expect(result?.delta == 70)
        #expect(result?.label == "+70 kcal")
    }

    // MARK: - kcal: on-target band

    @Test func intakeWithinFiftyKcalBandIsOnTarget() {
        // +50 exactly → onTarget (inclusive)
        #expect(HealthTargetDifference.formatKcal(current: 2050, target: 2000)?.direction == .onTarget)
        // -50 exactly → onTarget
        #expect(HealthTargetDifference.formatKcal(current: 1950, target: 2000)?.direction == .onTarget)
        // 0 → onTarget
        #expect(HealthTargetDifference.formatKcal(current: 2000, target: 2000)?.label == "目標 達成")
    }

    @Test func intakeJustOutsideKcalBandIsNotOnTarget() {
        #expect(HealthTargetDifference.formatKcal(current: 2051, target: 2000)?.direction == .over)
        #expect(HealthTargetDifference.formatKcal(current: 1949, target: 2000)?.direction == .under)
    }

    // MARK: - balance kcal (uses same wording as kcal)

    @Test func balanceUnderTargetShowsRemainingKcal() {
        // target balance -500 (deficit), today's actual -480 → still
        // need 20 more kcal of deficit → "あと 20 kcal" makes sense
        // for a cut. The formatter doesn't reason about cut vs bulk;
        // it just renders the magnitude of the delta.
        let result = HealthTargetDifference.formatBalance(current: -480, target: -500)
        #expect(result?.direction == .onTarget) // 20 kcal is within band
    }

    @Test func balanceOverTargetByLargeDeltaShowsPlus() {
        let result = HealthTargetDifference.formatBalance(current: -100, target: -500)
        #expect(result?.direction == .over)
        #expect(result?.delta == 400)
        #expect(result?.label == "+400 kcal")
    }

    // MARK: - sleep minutes: under target

    @Test func sleepUnderTargetCrossingHourBoundaryReadsAsHoursMinutes() {
        // current = 6h 20m = 380, target = 7h 30m = 450 → 70 min gap.
        let result = HealthTargetDifference.formatSleepMinutes(current: 380, target: 450)
        #expect(result?.direction == .under)
        #expect(result?.delta == -70)
        #expect(result?.label == "目標まで あと 1時間10分")
    }

    @Test func sleepUnderTargetWithoutCrossingHourBoundary() {
        // 30 min short.
        let result = HealthTargetDifference.formatSleepMinutes(current: 420, target: 450)
        #expect(result?.label == "目標まで あと 30分")
    }

    @Test func sleepUnderTargetAtExactHourBoundary() {
        // 60 min short → "1時間"
        let result = HealthTargetDifference.formatSleepMinutes(current: 390, target: 450)
        #expect(result?.label == "目標まで あと 1時間")
    }

    // MARK: - sleep minutes: over target

    @Test func sleepOverTargetShowsPlusHoursMinutes() {
        // +90 min → "+1時間30分"
        let result = HealthTargetDifference.formatSleepMinutes(current: 540, target: 450)
        #expect(result?.direction == .over)
        #expect(result?.label == "+1時間30分")
    }

    @Test func sleepOverTargetWithoutCrossingHourBoundary() {
        // +25 min → "+25分"
        let result = HealthTargetDifference.formatSleepMinutes(current: 475, target: 450)
        #expect(result?.label == "+25分")
    }

    // MARK: - sleep minutes: on-target band

    @Test func sleepWithinTenMinutesBandIsOnTarget() {
        #expect(HealthTargetDifference.formatSleepMinutes(current: 450, target: 450)?.direction == .onTarget)
        #expect(HealthTargetDifference.formatSleepMinutes(current: 460, target: 450)?.direction == .onTarget)
        #expect(HealthTargetDifference.formatSleepMinutes(current: 440, target: 450)?.direction == .onTarget)
    }

    @Test func sleepJustOutsideMinuteBandIsNotOnTarget() {
        #expect(HealthTargetDifference.formatSleepMinutes(current: 461, target: 450)?.direction == .over)
        #expect(HealthTargetDifference.formatSleepMinutes(current: 439, target: 450)?.direction == .under)
    }

    // MARK: - sleep minutes: nil fallback

    @Test func sleepReturnsNilWhenEitherSideMissing() {
        #expect(HealthTargetDifference.formatSleepMinutes(current: nil, target: 450) == nil)
        #expect(HealthTargetDifference.formatSleepMinutes(current: 420, target: nil) == nil)
    }

    // MARK: - formatHourMinute building block

    @Test func formatHourMinuteHandlesAllShapes() {
        #expect(HealthTargetDifference.formatHourMinute(70) == "1時間10分")
        #expect(HealthTargetDifference.formatHourMinute(60) == "1時間")
        #expect(HealthTargetDifference.formatHourMinute(45) == "45分")
        #expect(HealthTargetDifference.formatHourMinute(0) == "0分")
        // Negative input is clamped (callers pass abs internally) — the
        // formatter must not return a malformed "−1時間…" string.
        #expect(HealthTargetDifference.formatHourMinute(-30) == "0分")
    }

    // MARK: - Integration with HealthTargetResolver priority

    @Test func resolverDefaultDrivesTodayDifference() {
        // No weekday / date override → defaults win.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 13  // Monday
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: comps)!
        let settings = HealthTargetSettings(
            defaults: HealthTargets(intakeCalories: 2300),
        )
        let target = HealthTargetResolver.resolve(metric: .intakeCalories, date: date, settings: settings, calendar: calendar)
        let result = HealthTargetDifference.formatKcal(current: 1850, target: target)
        #expect(result?.label == "あと 450 kcal")
    }

    @Test func resolverWeekdayOverrideDrivesTodayDifference() {
        // Monday gets a higher target (training day) → +200 kcal.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 13  // Monday
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: comps)!
        let settings = HealthTargetSettings(
            defaults: HealthTargets(intakeCalories: 2100),
            weekdayOverrides: [.monday: HealthTargets(intakeCalories: 2500)],
        )
        let target = HealthTargetResolver.resolve(metric: .intakeCalories, date: date, settings: settings, calendar: calendar)
        let result = HealthTargetDifference.formatKcal(current: 1850, target: target)
        // 1850 - 2500 = -650
        #expect(result?.label == "あと 650 kcal")
    }

    @Test func resolverNilTargetFallsBackToNoDifference() {
        // Empty settings → resolver returns nil → formatter returns
        // nil → caller keeps prior "no target" display.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 13
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: comps)!
        let target = HealthTargetResolver.resolve(metric: .sleepMinutes, date: date, settings: .empty, calendar: calendar)
        #expect(target == nil)
        #expect(HealthTargetDifference.formatSleepMinutes(current: 420, target: target) == nil)
    }
}
