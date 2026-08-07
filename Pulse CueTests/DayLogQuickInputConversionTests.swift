//
//  DayLogQuickInputConversionTests.swift
//  Pulse CueTests
//
//  Pure conversion helpers behind the keyboard-free sleep/weight wheels in
//  `DayLogQuickInputSheet`. They must round-trip stored `DayLog` values so
//  opening the sheet never silently changes a recorded number.
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct DayLogQuickInputConversionTests {

    // MARK: - Sleep

    @Test
    func sleepComponentsSplitsMinutesIntoHoursAndMinutes() {
        #expect(DayLogQuickInputSheet.sleepComponents(fromMinutes: 0) == (0, 0))
        #expect(DayLogQuickInputSheet.sleepComponents(fromMinutes: 60) == (1, 0))
        #expect(DayLogQuickInputSheet.sleepComponents(fromMinutes: 437) == (7, 17))
        // Negative (corrupt) values floor to zero rather than crashing.
        #expect(DayLogQuickInputSheet.sleepComponents(fromMinutes: -5) == (0, 0))
    }

    @Test
    func totalSleepMinutesRoundTripsComponents() {
        #expect(DayLogQuickInputSheet.totalSleepMinutes(hours: 7, minutes: 17) == 437)
        #expect(DayLogQuickInputSheet.totalSleepMinutes(hours: 0, minutes: 0) == 0)
        #expect(DayLogQuickInputSheet.totalSleepMinutes(hours: 8, minutes: 0) == 480)
        // A round-trip of an arbitrary stored value preserves it exactly.
        let stored = 512
        let c = DayLogQuickInputSheet.sleepComponents(fromMinutes: stored)
        #expect(DayLogQuickInputSheet.totalSleepMinutes(hours: c.hours, minutes: c.minutes) == stored)
    }

    @Test
    func unrecordedSleepOpensOnSixHourDraftAndExistingValueWins() {
        // No stored value → 6h00m draft (display-only until an explicit save).
        #expect(DayLogQuickInputSheet.initialSleepMinutes(stored: nil) == 360)
        #expect(DayLogQuickInputSheet.sleepComponents(fromMinutes: 360) == (6, 0))
        // An existing record is preferred over the draft.
        #expect(DayLogQuickInputSheet.initialSleepMinutes(stored: 500) == 500)
        #expect(DayLogQuickInputSheet.initialSleepMinutes(stored: 0) == 0)
    }

    @Test
    func sleepCeilingIsTwentyFourHoursWithMinutesNormalizedToZero() {
        // 24h is the ceiling; selecting 24h drops any minutes (only 24h00m).
        #expect(DayLogQuickInputSheet.totalSleepMinutes(hours: 24, minutes: 30) == 24 * 60)
        #expect(DayLogQuickInputSheet.totalSleepMinutes(hours: 24, minutes: 0) == 24 * 60)
        #expect(DayLogQuickInputSheet.sleepComponents(fromMinutes: 24 * 60) == (24, 0))
        // Just under the ceiling keeps full precision.
        #expect(DayLogQuickInputSheet.totalSleepMinutes(hours: 23, minutes: 59) == 23 * 60 + 59)
    }

    // MARK: - Weight

    @Test
    func weightComponentsSplitAndRoundToNearestTenth() {
        #expect(DayLogQuickInputSheet.weightComponents(fromKg: 72.5) == (72, 5))
        #expect(DayLogQuickInputSheet.weightComponents(fromKg: 60.0) == (60, 0))
        #expect(DayLogQuickInputSheet.weightComponents(fromKg: 199.9) == (199, 9))
        // Extra precision snaps to the nearest 0.1 kg (matches the 1-decimal display).
        #expect(DayLogQuickInputSheet.weightComponents(fromKg: 72.53) == (72, 5))
        #expect(DayLogQuickInputSheet.weightComponents(fromKg: 72.57) == (72, 6))
    }

    @Test
    func weightValueRoundTripsComponents() {
        #expect(DayLogQuickInputSheet.weightValue(whole: 72, decimal: 5) == 72.5)
        #expect(DayLogQuickInputSheet.weightValue(whole: 60, decimal: 0) == 60.0)
        // Round-trip of a stored, already-1-decimal value is exact.
        let stored = 84.3
        let c = DayLogQuickInputSheet.weightComponents(fromKg: stored)
        #expect(DayLogQuickInputSheet.weightValue(whole: c.whole, decimal: c.decimal) == stored)
    }
}
