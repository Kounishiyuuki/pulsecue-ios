//
//  GoogleSignInResultTests.swift
//  Pulse CueTests
//
//  Covers the sanitized Google Sign-In path (PR #115): the
//  framework-independent `GoogleSignInResult` value type,
//  `AuthSessionStore.completeGoogleSignIn(displayName:email:)`, and the
//  `GoogleSignInConfig` placeholder/valid detection that gates the real flow.
//  No real Google UI/SDK is invoked — these are pure value/state checks that
//  confirm only non-sensitive display metadata is kept and no token-like
//  fields exist.
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct GoogleSignInResultTests {

    // MARK: - GoogleSignInResult sanitization

    @Test
    func keepsDisplayNameAndEmail() {
        let result = GoogleSignInResult(displayName: "Hanako Suzuki", email: "hanako@example.com")
        #expect(result.displayName == "Hanako Suzuki")
        #expect(result.email == "hanako@example.com")
    }

    @Test
    func trimsWhitespace() {
        let result = GoogleSignInResult(displayName: "  Hanako  ", email: " hanako@example.com ")
        #expect(result.displayName == "Hanako")
        #expect(result.email == "hanako@example.com")
    }

    @Test
    func blankAndNilBecomeNil() {
        #expect(GoogleSignInResult(displayName: "   ", email: "\n").displayName == nil)
        #expect(GoogleSignInResult(displayName: "   ", email: "\n").email == nil)
        #expect(GoogleSignInResult(displayName: nil, email: nil).displayName == nil)
        #expect(GoogleSignInResult(displayName: nil, email: nil).email == nil)
    }

    // MARK: - Store completion

    @Test
    func completeGoogleSignInSetsSanitizedSignedInState() {
        let store = AuthSessionStore(initialState: .signedOut)

        store.completeGoogleSignIn(displayName: "Hanako Suzuki", email: "hanako@example.com")

        #expect(store.isSignedIn == true)
        #expect(store.session?.provider == .google)
        #expect(store.session?.displayName == "Hanako Suzuki")
        #expect(store.session?.email == "hanako@example.com")
        #expect(store.statusLabel == "Googleでサインイン済み")
    }

    @Test
    func completeGoogleSignInWithNilMetadataStillSignsIn() {
        let store = AuthSessionStore(initialState: .signedOut)

        store.completeGoogleSignIn(displayName: nil, email: nil)

        #expect(store.isSignedIn == true)
        #expect(store.session?.provider == .google)
        #expect(store.session?.displayName == nil)
        #expect(store.session?.email == nil)
        #expect(store.statusLabel == "Googleでサインイン済み")
    }

    @Test
    func googleSignInThenSignOutClears() {
        let store = AuthSessionStore(initialState: .signedOut)
        store.completeGoogleSignIn(displayName: "Hanako", email: nil)
        #expect(store.isSignedIn == true)

        store.signOut()

        #expect(store.isSignedIn == false)
        #expect(store.session == nil)
        #expect(store.state == .signedOut)
    }

    @Test
    func googleSessionCarriesOnlyDisplayMetadata() {
        let store = AuthSessionStore(initialState: .signedOut)
        store.completeGoogleSignIn(displayName: "Hanako", email: "hanako@example.com")

        let expected = AuthSession(provider: .google, displayName: "Hanako", email: "hanako@example.com")
        #expect(store.session == expected)
    }

    // MARK: - GoogleSignInConfig detection

    @Test
    func placeholderConfigIsNotConfigured() {
        let config = GoogleSignInConfig(clientID: GoogleSignInConfig.placeholderClientID)
        #expect(config.isConfigured == false)
    }

    @Test
    func missingOrBlankConfigIsNotConfigured() {
        #expect(GoogleSignInConfig(clientID: nil).isConfigured == false)
        #expect(GoogleSignInConfig(clientID: "   ").isConfigured == false)
    }

    @Test
    func nonGoogleShapedConfigIsNotConfigured() {
        // A value that isn't shaped like a Google iOS client ID is rejected.
        #expect(GoogleSignInConfig(clientID: "not-a-client-id").isConfigured == false)
        // Even a real-looking domain still bearing the placeholder token is rejected.
        #expect(GoogleSignInConfig(clientID: "YOUR_IOS_CLIENT_ID.apps.googleusercontent.com").isConfigured == false)
    }

    @Test
    func realLookingConfigIsConfigured() {
        // A plausibly-real iOS client ID (no placeholder token, correct suffix)
        // is treated as configured. This is a *shape* check, not a live client.
        let config = GoogleSignInConfig(clientID: "1234567890-abcdefg.apps.googleusercontent.com")
        #expect(config.isConfigured == true)
    }
}
