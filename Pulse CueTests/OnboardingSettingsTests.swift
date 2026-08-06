//
//  OnboardingSettingsTests.swift
//  Pulse CueTests
//
//  Verifies the single piece of state the first-launch onboarding flow owns:
//  the `hasCompletedOnboarding` completion flag on `SettingsStore`. No
//  credential, token, or session state is involved — only this Bool, persisted
//  under the `settings.hasCompletedOnboarding` UserDefaults key.
//
//  Each test uses an isolated `UserDefaults` suite so flags never leak across
//  tests (mirrors RunnerStateMachineTests / UserProfileStoreTests).
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct OnboardingSettingsTests {

    private static func makeStore() -> (store: SettingsStore, defaults: UserDefaults) {
        let suiteName = "test.onboarding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (SettingsStore(defaults: defaults), defaults)
    }

    @Test
    func freshInstallHasNotCompletedOnboarding() {
        let (store, _) = Self.makeStore()
        // A fresh install (empty UserDefaults) must show onboarding once.
        #expect(store.hasCompletedOnboarding == false)
    }

    @Test
    func completeOnboardingSetsTheFlag() {
        let (store, _) = Self.makeStore()
        #expect(store.hasCompletedOnboarding == false)

        store.completeOnboarding()

        #expect(store.hasCompletedOnboarding == true)
    }

    @Test
    func completeOnboardingIsIdempotent() {
        let (store, _) = Self.makeStore()

        store.completeOnboarding()
        store.completeOnboarding()

        #expect(store.hasCompletedOnboarding == true)
    }

    @Test
    func completionPersistsToUserDefaults() {
        let (store, defaults) = Self.makeStore()

        store.completeOnboarding()

        // The flag is written through under the agreed key…
        #expect(defaults.bool(forKey: "settings.hasCompletedOnboarding") == true)
        // …and a new store reading the same suite sees it as completed
        // (so a relaunch does not show onboarding again).
        let reopened = SettingsStore(defaults: defaults)
        #expect(reopened.hasCompletedOnboarding == true)
    }

    @Test
    func directFlagAssignmentPersists() {
        let (store, defaults) = Self.makeStore()

        store.hasCompletedOnboarding = true

        #expect(defaults.bool(forKey: "settings.hasCompletedOnboarding") == true)
    }

    @Test
    func onboardingFlagDoesNotDisturbOtherSettings() {
        let (store, _) = Self.makeStore()

        store.completeOnboarding()

        // The onboarding flag is orthogonal to the existing app preferences;
        // their defaults remain intact.
        #expect(store.soundEnabled == true)
        #expect(store.hapticsEnabled == true)
        #expect(store.aiTransmissionScope == .standard)
        #expect(store.defaultRestSeconds == 60)
    }

    @Test
    func defaultRestSecondsDefaultsToSixtyAndPersists() {
        let (store, defaults) = Self.makeStore()
        #expect(store.defaultRestSeconds == 60)

        store.defaultRestSeconds = 90

        #expect(defaults.integer(forKey: "settings.defaultRestSeconds") == 90)
        #expect(SettingsStore(defaults: defaults).defaultRestSeconds == 90)
    }

    @Test(arguments: [(-1, 0), (601, 600), (120, 120)])
    func defaultRestSecondsClampsToSupportedRange(input: Int, expected: Int) {
        let (store, defaults) = Self.makeStore()

        store.defaultRestSeconds = input

        #expect(store.defaultRestSeconds == expected)
        #expect(defaults.integer(forKey: "settings.defaultRestSeconds") == expected)
    }

    @Test(arguments: [(-20, 0), (999, 600)])
    func initializationRepairsPersistedOutOfRangeRest(input: Int, expected: Int) {
        let defaults = UserDefaults(suiteName: "test.settings.invalid-rest.\(UUID().uuidString)")!
        defaults.set(input, forKey: "settings.defaultRestSeconds")

        let store = SettingsStore(defaults: defaults)

        #expect(store.defaultRestSeconds == expected)
        #expect(defaults.integer(forKey: "settings.defaultRestSeconds") == expected)
    }
}
