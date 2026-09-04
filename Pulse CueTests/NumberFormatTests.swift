//
//  NumberFormatTests.swift
//  Pulse CueTests
//
//  Two weight formats that look alike and are not.
//
//  Consolidating six near-identical formatters into `NumberFormat` silently
//  changed one screen: Me had always used `String(format: "%.1f", value)`,
//  which keeps the trailing zero, and it was folded into the shared
//  trailing-zero-dropping helper. 72.0 kg became 72 kg on the personal-status
//  row and in its VoiceOver label.
//
//  The expected values below are written out literally rather than produced by
//  calling the formatter, because a test that asks the implementation what it
//  should return cannot catch the implementation changing.
//

import Foundation
import Testing
@testable import Pulse_Cue

struct NumberFormatTests {

    // MARK: - Me: always one decimal

    @Test func aWholeWeightKeepsItsTrailingZero() {
        // The regression, pinned: this read "72" for one PR.
        #expect(NumberFormat.weightOneDecimal(72) == "72.0")
        #expect(NumberFormat.weightOneDecimal(0) == "0.0")
        #expect(NumberFormat.weightOneDecimal(100) == "100.0")
    }

    @Test func aFractionalWeightKeepsExactlyOneDecimal() {
        #expect(NumberFormat.weightOneDecimal(72.5) == "72.5")
        #expect(NumberFormat.weightOneDecimal(71.4) == "71.4")
        #expect(NumberFormat.weightOneDecimal(0.6) == "0.6")
    }

    @Test func extraPrecisionIsRoundedToOneDecimal() {
        #expect(NumberFormat.weightOneDecimal(72.04) == "72.0")
        #expect(NumberFormat.weightOneDecimal(72.44) == "72.4")
        #expect(NumberFormat.weightOneDecimal(72.96) == "73.0")
    }

    @Test func itRoundsTheWayTheScreenAlwaysHas() {
        // `String(format:)` and `NumberFormatter` disagree at the half, so the
        // implementation is part of the contract rather than an equivalent
        // choice. Compared against the expression Me used before the merge.
        for value in [72.05, 72.15, 72.25, 72.35, 0.05, 99.95] as [Double] {
            #expect(NumberFormat.weightOneDecimal(value) == String(format: "%.1f", value))
        }
    }

    // MARK: - Everywhere else: trailing zero dropped

    @Test func theSharedWeightFormatDropsATrailingZero() {
        // Home, Health and the settings cells: unchanged by the consolidation
        // and asserted here so the two contracts stay distinguishable.
        #expect(NumberFormat.weight(72) == "72")
        #expect(NumberFormat.weight(72.5) == "72.5")
    }

    @Test func theTwoWeightFormatsDifferOnlyOnWholeNumbers() {
        #expect(NumberFormat.weight(72) != NumberFormat.weightOneDecimal(72))
        #expect(NumberFormat.weight(72.5) == NumberFormat.weightOneDecimal(72.5))
    }

    // MARK: - Integers

    @Test func integersAreGrouped() {
        #expect(NumberFormat.int(1_485) == "1,485")
        #expect(NumberFormat.int(0) == "0")
        #expect(NumberFormat.int(999) == "999")
    }
}
