//
//  TodayHomeCopyTests.swift
//  Pulse CueTests
//
//  The tab set is the intended four (see `PrimaryNavigationTests` for what
//  those four are and why).
//
//  This file used to also pin `TodayConditionCopy`, a pure mapping from "how
//  many of today's four fields are filled" to a headline and subhead. Home
//  stopped rendering it when the dashboard was reorganised — `TodayView` kept
//  two private accessors that nothing called, and those went in #180. The type
//  itself survived on the strength of these tests and a comment saying a
//  future readiness display might want it.
//
//  It is gone now. A tested type with no caller is not a contract; it is a
//  suite that cannot fail for any reason a user would notice, and it reports
//  coverage the app does not have. If the readiness display is ever built, the
//  copy will be written against that screen's needs rather than recovered from
//  a mapping nobody has looked at since.
//

import Testing
@testable import Pulse_Cue

struct TodayHomeCopyTests {

    @Test func tabSetIsTheFourIntendedTabs() {
        #expect(AppTab.allCases == [.home, .training, .nutrition, .me])
        #expect(AppTab.allCases.count == 4)
    }
}
