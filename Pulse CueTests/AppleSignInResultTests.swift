//
//  AppleSignInResultTests.swift
//  Pulse CueTests
//
//  Covers the sanitized Sign in with Apple path (PR #114): the
//  framework-independent `AppleSignInResult` value type and
//  `AuthSessionStore.completeAppleSignIn(displayName:email:)`. No real Apple
//  UI is invoked — these are pure value/state checks that confirm only
//  non-sensitive display metadata is kept and no token-like fields exist.
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct AppleSignInResultTests {

    // MARK: - Name formatting

    @Test
    func formatsFullNameFromComponents() {
        var components = PersonNameComponents()
        components.givenName = "Taro"
        components.familyName = "Yamada"

        let result = AppleSignInResult(nameComponents: components, email: nil)

        // A non-empty display name is produced from the components…
        #expect(result.displayName?.isEmpty == false)
        // …and it includes the provided name parts.
        #expect(result.displayName?.contains("Taro") == true)
        #expect(result.displayName?.contains("Yamada") == true)
    }

    @Test
    func emailPassesThrough() {
        let result = AppleSignInResult(displayName: "Taro", email: "taro@example.com")
        #expect(result.email == "taro@example.com")
        #expect(result.displayName == "Taro")
    }

    // MARK: - Nil / empty fallback

    @Test
    func nilNameComponentsProduceNilDisplayName() {
        let result = AppleSignInResult(nameComponents: nil, email: nil)
        #expect(result.displayName == nil)
        #expect(result.email == nil)
    }

    @Test
    func blankStringsAreNormalizedToNil() {
        let result = AppleSignInResult(displayName: "   ", email: "\n")
        #expect(result.displayName == nil)
        #expect(result.email == nil)
    }

    @Test
    func emptyComponentsProduceNilDisplayName() {
        let empty = PersonNameComponents()
        let result = AppleSignInResult(nameComponents: empty, email: "a@b.com")
        #expect(result.displayName == nil)
        #expect(result.email == "a@b.com")
    }

    // MARK: - Store completion

    @Test
    func completeAppleSignInSetsSanitizedSignedInState() {
        let store = AuthSessionStore(initialState: .signedOut)

        store.completeAppleSignIn(displayName: "Taro Yamada", email: "taro@example.com")

        #expect(store.isSignedIn == true)
        #expect(store.session?.provider == .apple)
        #expect(store.session?.displayName == "Taro Yamada")
        #expect(store.session?.email == "taro@example.com")
        #expect(store.statusLabel == "Appleでサインイン済み")
    }

    @Test
    func completeAppleSignInWithNilMetadataStillSignsIn() {
        // Apple returns name/email only on first authorization; a later
        // sign-in with nil metadata must still produce a valid signed-in state.
        let store = AuthSessionStore(initialState: .signedOut)

        store.completeAppleSignIn(displayName: nil, email: nil)

        #expect(store.isSignedIn == true)
        #expect(store.session?.provider == .apple)
        #expect(store.session?.displayName == nil)
        #expect(store.session?.email == nil)
        #expect(store.statusLabel == "Appleでサインイン済み")
    }

    @Test
    func appleSignInThenSignOutClears() {
        let store = AuthSessionStore(initialState: .signedOut)
        store.completeAppleSignIn(displayName: "Taro", email: nil)
        #expect(store.isSignedIn == true)

        store.signOut()

        #expect(store.isSignedIn == false)
        #expect(store.session == nil)
        #expect(store.state == .signedOut)
    }

    // MARK: - Non-sensitive session shape

    @Test
    func appleSessionCarriesOnlyDisplayMetadata() {
        // `AuthSession` is value-equal on (provider, displayName, email) only;
        // there is no token/code/user field to carry a secret. This asserts the
        // sanitized session equals one built purely from display metadata.
        let store = AuthSessionStore(initialState: .signedOut)
        store.completeAppleSignIn(displayName: "Taro", email: "taro@example.com")

        let expected = AuthSession(provider: .apple, displayName: "Taro", email: "taro@example.com")
        #expect(store.session == expected)
    }
}
