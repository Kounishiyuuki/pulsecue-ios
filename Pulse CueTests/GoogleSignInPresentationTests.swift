//
//  GoogleSignInPresentationTests.swift
//  Pulse CueTests
//
//  Locks the Release authentication-presentation rule: an unavailable /
//  "設定準備中" Google control is NEVER shown to Release users. It appears
//  only when a real client is configured; DEBUG additionally keeps the
//  unavailable state visible for development.
//

import Testing
@testable import Pulse_Cue

struct GoogleSignInPresentationTests {

    // MARK: - Release presentation

    @Test func releaseHidesUnconfiguredGoogleControl() {
        // The whole point: placeholder config in a Release build shows nothing.
        #expect(GoogleSignInPresentation.showsControl(isConfigured: false, isDebugBuild: false) == false)
    }

    @Test func releaseShowsGoogleOnlyWhenConfigured() {
        #expect(GoogleSignInPresentation.showsControl(isConfigured: true, isDebugBuild: false))
    }

    // MARK: - Debug presentation

    @Test func debugShowsGoogleEvenWhenUnconfigured() {
        // Development keeps the explicit "unavailable" state visible.
        #expect(GoogleSignInPresentation.showsControl(isConfigured: false, isDebugBuild: true))
        #expect(GoogleSignInPresentation.showsControl(isConfigured: true, isDebugBuild: true))
    }

    // MARK: - Current app configuration

    @Test func mainBundleGoogleConfigIsPlaceholderSoReleaseHidesIt() {
        // Documents the current shipped state: the Info.plist Google config is
        // still the documented placeholder, so a Release build hides the
        // control. If a real client is ever configured this flips to `true`
        // and the assertion below should be updated deliberately.
        let config = GoogleSignInConfig.fromMainBundle()
        #expect(config.isConfigured == false)
        #expect(GoogleSignInPresentation.showsControl(isConfigured: config.isConfigured, isDebugBuild: false) == false)
    }
}
