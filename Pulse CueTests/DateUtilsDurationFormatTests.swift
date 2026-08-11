//
//  DateUtilsDurationFormatTests.swift
//  Pulse CueTests
//
//  Locks the one duration formatter every screen shares: the Runner's rest
//  countdown, History rows, Session detail, Progress totals and the Workout
//  Completion summary. Sub-hour output must stay exactly as it always was;
//  an hour or more must not collapse into an unreadable minute count.
//

import Foundation
import Testing
@testable import Pulse_Cue

struct DateUtilsDurationFormatTests {

    // MARK: - Under an hour (unchanged behaviour)

    @Test
    func subHourStaysMinutesAndSeconds() {
        #expect(DateUtils.formatDuration(seconds: 0) == "00:00")
        #expect(DateUtils.formatDuration(seconds: 9) == "00:09")
        #expect(DateUtils.formatDuration(seconds: 90) == "01:30")
        #expect(DateUtils.formatDuration(seconds: 2_533) == "42:13")
        #expect(DateUtils.formatDuration(seconds: 3_599) == "59:59")
    }

    /// The rest countdown uses the same formatter and never reaches an hour,
    /// so it must keep the zero-padded two-field form.
    @Test
    func restCountdownRangeIsAlwaysTwoFields() {
        for seconds in [0, 1, 10, 45, 60, 75, 90, 120, 600] {
            let text = DateUtils.formatDuration(seconds: seconds)
            #expect(text.count == 5, "\(seconds)s formatted as \(text)")
            #expect(!text.contains("::"))
        }
    }

    // MARK: - An hour and beyond

    @Test
    func oneHourSwitchesToHourMinuteSecond() {
        #expect(DateUtils.formatDuration(seconds: 3_600) == "1:00:00")
        #expect(DateUtils.formatDuration(seconds: 3_601) == "1:00:01")
        #expect(DateUtils.formatDuration(seconds: 3_660) == "1:01:00")
    }

    /// The RC QA session that motivated this: 18,286s used to render "304:46".
    @Test
    func longSessionReadsAsHoursNotAMinuteCount() {
        #expect(DateUtils.formatDuration(seconds: 18_286) == "5:04:46")
    }

    @Test
    func hoursAreNotZeroPaddedButMinutesAndSecondsAre() {
        #expect(DateUtils.formatDuration(seconds: 36_000) == "10:00:00")
        #expect(DateUtils.formatDuration(seconds: 7_384) == "2:03:04")
    }

    // MARK: - Degenerate input

    @Test
    func negativeSecondsClampToZero() {
        #expect(DateUtils.formatDuration(seconds: -1) == "00:00")
        #expect(DateUtils.formatDuration(seconds: -100_000) == "00:00")
    }

    /// Every boundary second is either two fields or three — never a minute
    /// count above 59.
    @Test
    func minuteFieldNeverExceedsFiftyNine() {
        for seconds in [3_540, 3_599, 3_600, 3_601, 7_199, 7_200] {
            let fields = DateUtils.formatDuration(seconds: seconds).split(separator: ":")
            let minuteField = fields.count == 3 ? fields[1] : fields[0]
            #expect((Int(minuteField) ?? 99) <= 59, "\(seconds)s → \(fields)")
        }
    }
}
