//
//  ProfileGymSetupStatusTests.swift
//  Pulse CueTests
//
//  Covers the read-only setup status derivation (PR #116). The status is a
//  pure function of existing sources (height / today's weight / gym presence)
//  and is independent of auth state — guests and signed-in users derive it the
//  same way. No new storage or source of truth is involved.
//

import Foundation
import Testing
@testable import Pulse_Cue

struct ProfileGymSetupStatusTests {

    @Test
    func nothingSet() {
        let status = ProfileGymSetupStatus(heightCm: nil, todayWeightKg: nil, hasGym: false)
        #expect(status.heightSet == false)
        #expect(status.weightRecorded == false)
        #expect(status.gymRegistered == false)
        #expect(status.isComplete == false)
        #expect(status.completedCount == 0)
        #expect(status.totalCount == 3)
    }

    @Test
    func heightOnly() {
        let status = ProfileGymSetupStatus(heightCm: 172, todayWeightKg: nil, hasGym: false)
        #expect(status.heightSet == true)
        #expect(status.weightRecorded == false)
        #expect(status.gymRegistered == false)
        #expect(status.isComplete == false)
        #expect(status.completedCount == 1)
    }

    @Test
    func weightOnly() {
        let status = ProfileGymSetupStatus(heightCm: 0, todayWeightKg: 68.5, hasGym: false)
        #expect(status.heightSet == false)
        #expect(status.weightRecorded == true)
        #expect(status.gymRegistered == false)
        #expect(status.completedCount == 1)
    }

    @Test
    func gymOnly() {
        let status = ProfileGymSetupStatus(heightCm: nil, todayWeightKg: nil, hasGym: true)
        #expect(status.gymRegistered == true)
        #expect(status.heightSet == false)
        #expect(status.weightRecorded == false)
        #expect(status.completedCount == 1)
    }

    @Test
    func allComplete() {
        let status = ProfileGymSetupStatus(heightCm: 170, todayWeightKg: 70.0, hasGym: true)
        #expect(status.heightSet == true)
        #expect(status.weightRecorded == true)
        #expect(status.gymRegistered == true)
        #expect(status.isComplete == true)
        #expect(status.completedCount == 3)
    }

    @Test
    func nonPositiveHeightAndWeightAreNotSet() {
        // Zero / negative values are treated as "not set", guarding against a
        // blank or degenerate profile/log being counted as complete.
        let status = ProfileGymSetupStatus(heightCm: 0, todayWeightKg: 0, hasGym: true)
        #expect(status.heightSet == false)
        #expect(status.weightRecorded == false)
        #expect(status.gymRegistered == true)
        #expect(status.isComplete == false)
        #expect(status.completedCount == 1)
    }

    @Test
    func blankGymIsCallerResponsibility() {
        // `hasGym` is supplied by the caller (a non-empty gym list). The status
        // type simply reflects it; an empty list means no gym registered.
        #expect(ProfileGymSetupStatus(heightCm: 170, todayWeightKg: 70, hasGym: false).gymRegistered == false)
        #expect(ProfileGymSetupStatus(heightCm: 170, todayWeightKg: 70, hasGym: true).gymRegistered == true)
    }
}
