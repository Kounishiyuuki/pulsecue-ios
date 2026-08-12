//
//  AuthShellTests.swift
//  Pulse CueTests
//
//  Covers the local auth *shell* (PR #112): state transitions, the mock
//  providers' non-sensitive sessions, and the guarantee that the shell never
//  gates app usage. No real authentication, tokens, or persistence exist yet,
//  so these tests are pure in-memory state checks.
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct AuthShellTests {

    // MARK: - Initial state

    @Test
    func defaultStateIsGuestAndNonBlocking() {
        let store = AuthSessionStore()
        // Default is local-only guest mode…
        #expect(store.state == .guest)
        #expect(store.isSignedIn == false)
        #expect(store.session == nil)
        // …and the shell never blocks app usage.
        #expect(store.allowsUnauthenticatedAppUsage == true)
    }

    @Test
    func initialStateIsConfigurable() {
        // The injected initial state is preserved verbatim; only unlinking
        // forces the guest state.
        let store = AuthSessionStore(initialState: .signedOut)
        #expect(store.state == .signedOut)
        #expect(store.statusLabel == "未ログイン")
    }

    // MARK: - Guest / sign-out transitions

    @Test
    func continueAsGuestEntersGuestState() {
        let store = AuthSessionStore(initialState: .signedOut)

        store.continueAsGuest()

        #expect(store.state == .guest)
        #expect(store.isSignedIn == false)
    }

    @Test
    func signOutReturnsToSignedOut() {
        let store = AuthSessionStore()

        store.unlinkAccount()

        #expect(store.state == .guest)
        #expect(store.isSignedIn == false)
        #expect(store.session == nil)
    }

    // MARK: - Mock providers

    @Test
    func mockAppleSignInProducesNonSensitiveAppleSession() async {
        let store = AuthSessionStore()

        store.completeAppleSignIn(userIdentifier: "apple-test-user", displayName: "Apple ユーザー", email: nil)

        #expect(store.isSignedIn == true)
        let session = store.session
        #expect(session?.provider == .apple)
        // Display-only metadata; no credential is surfaced.
        #expect(session?.email == nil)
        #expect(store.statusLabel == "Appleと連携済み（この端末のみ）")
    }

    @Test
    func mockGoogleSignInProducesNonSensitiveGoogleSession() async {
        let store = AuthSessionStore()

        store.completeGoogleSignIn(userIdentifier: "google-test-user", displayName: "Google ユーザー", email: nil)

        #expect(store.isSignedIn == true)
        let session = store.session
        #expect(session?.provider == .google)
        #expect(session?.email == nil)
        #expect(store.statusLabel == "Googleと連携済み（この端末のみ）")
    }

    @Test
    func signOutAfterMockSignInClearsSession() async {
        let store = AuthSessionStore()
        store.completeAppleSignIn(userIdentifier: "apple-test-user", displayName: "Apple ユーザー", email: nil)
        #expect(store.isSignedIn == true)

        store.unlinkAccount()

        #expect(store.isSignedIn == false)
        #expect(store.session == nil)
    }

    // MARK: - Provider units

    @Test
    func guestProviderReturnsGuestSession() async throws {
        let session = try await GuestAuthProvider().signIn()
        #expect(session.provider == .guest)
        #expect(session.email == nil)
    }

    @Test
    func providerKindsCoverGuestAndBothLinkProviders() {
        // Apple and Google no longer have provider types: their flows run in
        // LoginView and are recorded through AuthSessionStore. Only the guest
        // path still has one.
        #expect(GuestAuthProvider().kind == .guest)
        #expect(Set(AuthProviderKind.allCases) == [.guest, .apple, .google])
    }

    // MARK: - State helpers

    @Test
    func authStateExposesAttachedSessionOnly() {
        let session = AuthSession(provider: .apple, displayName: "Apple ユーザー（準備中）")
        #expect(AuthState.signedIn(session).session == session)
        #expect(AuthState.guest.session == nil)
        #expect(AuthState.signedOut.session == nil)
    }

    @Test
    func providerKindStatusLabels() {
        #expect(AuthProviderKind.guest.statusLabel == "ゲスト（ローカル利用）")
        #expect(AuthProviderKind.apple.statusLabel == "Appleと連携済み（この端末のみ）")
        #expect(AuthProviderKind.google.statusLabel == "Googleと連携済み（この端末のみ）")
    }
}
