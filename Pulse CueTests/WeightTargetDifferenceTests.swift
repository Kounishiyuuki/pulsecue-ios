//
//  WeightTargetDifferenceTests.swift
//  Pulse CueTests
//
//  Locks in the goal-difference + previous-change wording used on
//  Today and HealthSummary's weight rows.
//
//  Coverage:
//   - goal difference: under / over / on-target band (±0.5 kg) /
//     nil current / nil goal / goal = 0
//   - previous change: gain / loss / near-zero rounding to ±0 /
//     missing previous
//   - formatKg: always 1 decimal, never emits sign
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct WeightTargetDifferenceTests {

    // MARK: - Goal difference: under

    @Test func goalUnderTargetShowsRemainingKg() {
        let result = WeightTargetDifference.goalDifference(current: 68.2, goal: 65.0)
        #expect(result?.direction == .over) // current > goal → over
        // 68.2 - 65.0 = 3.2 kg over
        #expect(result?.label == "目標より +3.2 kg")
    }

    @Test func goalCurrentBelowGoalReadsAsRemaining() {
        // Bulker: current 70, goal 75 → 5 kg to gain.
        let result = WeightTargetDifference.goalDifference(current: 70.0, goal: 75.0)
        #expect(result?.direction == .under) // current < goal → under
        #expect(result?.label == "目標まで あと 5.0 kg")
    }

    // MARK: - Goal difference: on-target band

    @Test func goalWithinHalfKgBandIsOnTarget() {
        #expect(WeightTargetDifference.goalDifference(current: 65.0, goal: 65.0)?.direction == .onTarget)
        #expect(WeightTargetDifference.goalDifference(current: 65.5, goal: 65.0)?.direction == .onTarget)
        #expect(WeightTargetDifference.goalDifference(current: 64.5, goal: 65.0)?.direction == .onTarget)
        #expect(WeightTargetDifference.goalDifference(current: 65.0, goal: 65.0)?.label == "目標 達成")
    }

    @Test func goalJustOutsideKgBandIsNotOnTarget() {
        let over = WeightTargetDifference.goalDifference(current: 65.6, goal: 65.0)
        #expect(over?.direction == .over)
        let under = WeightTargetDifference.goalDifference(current: 64.4, goal: 65.0)
        #expect(under?.direction == .under)
    }

    // MARK: - Goal difference: nil / zero goal

    @Test func goalDifferenceReturnsNilWhenCurrentMissing() {
        #expect(WeightTargetDifference.goalDifference(current: nil, goal: 65.0) == nil)
    }

    @Test func goalDifferenceReturnsNilWhenGoalMissing() {
        #expect(WeightTargetDifference.goalDifference(current: 68.0, goal: nil) == nil)
    }

    @Test func goalDifferenceReturnsNilWhenGoalIsZero() {
        // goalWeightKg defaults to 65.0 but a user could clear it to
        // 0 — treat 0 as "no goal" rather than as a meaningful target.
        #expect(WeightTargetDifference.goalDifference(current: 68.0, goal: 0.0) == nil)
    }

    // MARK: - Previous change: gain / loss

    @Test func previousChangeGainShowsPlusKg() {
        let result = WeightTargetDifference.previousChange(latest: 70.4, previous: 70.1)
        #expect(result?.direction == .over)
        #expect(result?.label == "前回比 +0.3 kg")
    }

    @Test func previousChangeLossShowsMinusKg() {
        let result = WeightTargetDifference.previousChange(latest: 70.0, previous: 70.5)
        #expect(result?.direction == .under)
        #expect(result?.label == "前回比 -0.5 kg")
    }

    @Test func previousChangeLargeLossKeepsOneDecimal() {
        let result = WeightTargetDifference.previousChange(latest: 68.0, previous: 70.5)
        #expect(result?.label == "前回比 -2.5 kg")
    }

    // MARK: - Previous change: near-zero

    @Test func previousChangeNearZeroRoundsToFlat() {
        // Delta 0.04 kg → below floor → ±0
        let result = WeightTargetDifference.previousChange(latest: 70.04, previous: 70.0)
        #expect(result?.direction == .onTarget)
        #expect(result?.label == "前回比 ±0 kg")
        #expect(result?.deltaKg == 0)
    }

    @Test func previousChangeExactZero() {
        let result = WeightTargetDifference.previousChange(latest: 70.0, previous: 70.0)
        #expect(result?.direction == .onTarget)
        #expect(result?.label == "前回比 ±0 kg")
    }

    @Test func previousChangeAboveFloorReadsAsChange() {
        // Delta 0.1 kg is unambiguously above the 0.05 rounding
        // floor and renders rather than collapsing to ±0.
        let result = WeightTargetDifference.previousChange(latest: 70.1, previous: 70.0)
        #expect(result?.direction == .over)
        #expect(result?.label == "前回比 +0.1 kg")
    }

    // MARK: - Previous change: nil fallback

    @Test func previousChangeReturnsNilWhenLatestMissing() {
        #expect(WeightTargetDifference.previousChange(latest: nil, previous: 70.0) == nil)
    }

    @Test func previousChangeReturnsNilWhenPreviousMissing() {
        #expect(WeightTargetDifference.previousChange(latest: 70.0, previous: nil) == nil)
    }

    // MARK: - formatKg

    @Test func formatKgAlwaysOneDecimal() {
        #expect(WeightTargetDifference.formatKg(3.0) == "3.0")
        #expect(WeightTargetDifference.formatKg(3.2) == "3.2")
        #expect(WeightTargetDifference.formatKg(0.0) == "0.0")
    }

    @Test func formatKgClampsNegativeToZero() {
        // Callers prepend the sign, so the helper should never emit
        // its own minus sign even if handed a negative.
        #expect(WeightTargetDifference.formatKg(-2.5) == "0.0")
    }
}
