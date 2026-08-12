//
//  GoogleSignInPresentationTests.swift
//  Pulse CueTests
//
//  Locks the Release authentication-presentation rule: an unavailable /
//  "設定準備中" Google control is NEVER shown to Release users. It appears
//  only when a real client is configured; DEBUG additionally keeps the
//  unavailable state visible for development.
//

import Foundation
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

    @Test func mainBundleGoogleConfigIsARealClientSoReleaseShowsIt() {
        // A real iOS OAuth client is now configured, which the previous
        // version of this test explicitly asked to flip deliberately.
        let config = GoogleSignInConfig.fromMainBundle()
        #expect(config.isConfigured)
        #expect(GoogleSignInPresentation.showsControl(isConfigured: config.isConfigured, isDebugBuild: false))
        // Guard the shape rather than the literal, and prove the placeholder
        // is gone.
        let clientID = try! #require(config.clientID)
        #expect(clientID.hasSuffix(".apps.googleusercontent.com"))
        #expect(!clientID.contains("YOUR_IOS_CLIENT_ID"))
    }

    /// The reversed client ID must be registered as a URL scheme, or the
    /// OAuth callback never returns to the app.
    @Test func infoPlistRegistersTheReversedClientIDUrlScheme() {
        let config = GoogleSignInConfig.fromMainBundle()
        let clientID = try! #require(config.clientID)
        let expected = "com.googleusercontent.apps." + clientID.replacingOccurrences(
            of: ".apps.googleusercontent.com", with: ""
        )
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes.contains(expected), "missing \(expected) in \(schemes)")
    }

    /// No backend exists, so no server client id may be configured.
    @Test func noServerClientIDIsConfigured() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "GIDServerClientID") == nil)
    }
}
