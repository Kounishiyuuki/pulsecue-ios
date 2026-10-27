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

    /// The production Web/server client id is configured.
    ///
    /// This used to assert the opposite — that no real server client id was
    /// committed — because the backend did not exist yet. Production now ships
    /// the real Web client id on purpose, so the guard moves to what matters
    /// for a release: the key is present, has the Google client shape, and is
    /// not the documented placeholder. The literal is not repeated here; the
    /// Info.plist stays the single source of truth.
    @Test func productionServerClientIDIsConfigured() {
        let raw = Bundle.main.object(forInfoDictionaryKey: "GIDServerClientID") as? String
        let config = GoogleServerSignInConfig(serverClientID: raw)
        #expect(config.isConfigured, "GIDServerClientID must be a real Web/server client id: \(raw ?? "nil")")
        let serverClientID = try! #require(config.serverClientID)
        #expect(serverClientID.hasSuffix(".apps.googleusercontent.com"))
        #expect(serverClientID != GoogleServerSignInConfig.placeholderServerClientID)
        #expect(!serverClientID.contains("YOUR_WEB_SERVER_CLIENT_ID"))
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

    /// The production API base URL is configured and safe to send tokens to.
    ///
    /// Previously this required a placeholder. Production now points at the
    /// real Worker, so the test checks the properties the account layer relies
    /// on — HTTPS, a real host, no credentials, not the placeholder — without
    /// hardcoding the host itself.
    @Test func productionAPIBaseURLIsConfigured() {
        let raw = Bundle.main.object(forInfoDictionaryKey: "PulseCueAPIBaseURL") as? String
        let config = PulseCueAPIConfiguration(rawValue: raw)
        #expect(config.isConfigured, "PulseCueAPIBaseURL must be a valid production endpoint: \(raw ?? "nil")")
        let baseURL = try! #require(config.baseURL)
        #expect(baseURL.scheme == "https")
        let host = try! #require(baseURL.host)
        #expect(!host.isEmpty)
        #expect(host != "localhost" && host != "127.0.0.1")
        #expect(baseURL.user == nil && baseURL.password == nil)
        #expect(!(raw ?? "").contains("YOUR_PULSECUE_API_HOST"))
    }
}
