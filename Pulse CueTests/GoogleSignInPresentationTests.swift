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

    /// No **real** server client id may be committed.
    ///
    /// This used to require `GIDServerClientID` to be absent entirely, on the
    /// grounds that no backend existed. A backend exists now and the key is
    /// present as a documented placeholder, so the assertion moves to what it
    /// was actually protecting: a real Google credential must never land in
    /// the repository. That is the same guard `GIDClientID` already has, and
    /// it is stricter than "the key is missing" — which would have gone quiet
    /// the moment anyone added the key at all.
    @Test func noRealServerClientIDIsCommitted() {
        let raw = Bundle.main.object(forInfoDictionaryKey: "GIDServerClientID") as? String
        let config = GoogleServerSignInConfig(serverClientID: raw)
        #expect(
            !config.isConfigured,
            "a real Web/server client id must not be committed: \(raw ?? "nil")"
        )
    }

    /// The server client id is a *different* client from the iOS one.
    ///
    /// Both end in `.apps.googleusercontent.com`, so shape cannot tell them
    /// apart, but they must never be equal. Pasting the iOS client id into the
    /// server slot fails closed — the backend rejects every token — which
    /// presents as "sign-in is broken" rather than "wrong value".
    @Test func serverClientIDIsNotTheIOSClientID() {
        let raw = Bundle.main.object(forInfoDictionaryKey: "GIDServerClientID") as? String
        let config = GoogleServerSignInConfig(serverClientID: raw)
        #expect(config.isDistinct(from: GoogleSignInConfig.fromMainBundle().clientID))
    }

    /// The server client id gets **no** reversed URL scheme.
    ///
    /// It is not an app identity and nothing redirects to it; registering one
    /// would claim a scheme for a client that never receives a callback.
    @Test func serverClientIDHasNoReversedUrlScheme() {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "GIDServerClientID") as? String
        else { return }
        let reversed = "com.googleusercontent.apps." + raw.replacingOccurrences(
            of: ".apps.googleusercontent.com", with: ""
        )
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(!schemes.contains(reversed))
    }

    /// The API base URL must be a placeholder, never a real production host.
    @Test func noRealAPIBaseURLIsCommitted() {
        let raw = Bundle.main.object(forInfoDictionaryKey: "PulseCueAPIBaseURL") as? String
        #expect(
            !PulseCueAPIConfiguration(rawValue: raw).isConfigured,
            "a real API base URL must not be committed: \(raw ?? "nil")"
        )
    }
}
