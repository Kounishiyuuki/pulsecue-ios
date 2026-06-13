//
//  AuthUILogicTests.swift
//  Pulse CueTests
//
//  Models the action logic behind the Login/Register UI shell (PR #113):
//  the exact `AuthSessionStore` transitions that `LoginView`'s buttons and
//  the Settings account card drive. These are local/mock actions only — no
//  real auth, SDK, network, or tokens are involved.
//
//  Complements `AuthShellTests` (which covers the store in isolation) by
//  asserting the UI-facing sequences: choose-a-method, sign-out availability,
//  and the displayed status label for each state.
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct AuthUILogicTests {

    // MARK: - LoginView button actions

    @Test
    func guestButtonEntersGuestState() {
        let store = AuthSessionStore(initialState: .signedOut)

        // "ゲストで続ける"
        store.continueAsGuest()

        #expect(store.state == .guest)
        #expect(store.isSignedIn == false)
        #expect(store.statusLabel == "ゲスト（ローカル利用）")
    }

    @Test
    func appleButtonSignsInWithMockApple() async {
        let store = AuthSessionStore(initialState: .signedOut)

        // "Appleで続ける"
        await store.signInWithMockApple()

        #expect(store.isSignedIn == true)
        #expect(store.session?.provider == .apple)
        #expect(store.session?.email == nil)
        #expect(store.statusLabel == "Appleでサインイン済み")
    }

    @Test
    func googleButtonSignsInWithMockGoogle() async {
        let store = AuthSessionStore(initialState: .signedOut)

        // "Googleで続ける"
        await store.signInWithMockGoogle()

        #expect(store.isSignedIn == true)
        #expect(store.session?.provider == .google)
        #expect(store.session?.email == nil)
        #expect(store.statusLabel == "Googleでサインイン済み")
    }

    // MARK: - Settings logout availability

    @Test
    func logoutIsOnlyAvailableWhenSignedIn() async {
        let store = AuthSessionStore(initialState: .guest)
        // Guest / signed-out are not "signed in", so the Settings logout
        // action stays hidden.
        #expect(store.isSignedIn == false)

        await store.signInWithMockApple()
        // After a mock sign-in the logout action becomes available…
        #expect(store.isSignedIn == true)

        store.signOut()
        // …and signing out returns to a non-signed-in state.
        #expect(store.isSignedIn == false)
        #expect(store.state == .signedOut)
        #expect(store.session == nil)
    }

    // MARK: - Switching providers via the sheet

    @Test
    func switchingFromAppleToGoogleUpdatesSession() async {
        let store = AuthSessionStore(initialState: .signedOut)

        await store.signInWithMockApple()
        #expect(store.session?.provider == .apple)

        await store.signInWithMockGoogle()
        #expect(store.session?.provider == .google)
        #expect(store.isSignedIn == true)
    }

    // MARK: - Status label coverage

    @Test
    func statusLabelMatchesEachState() async {
        let store = AuthSessionStore(initialState: .signedOut)
        #expect(store.statusLabel == "未ログイン")

        store.continueAsGuest()
        #expect(store.statusLabel == "ゲスト（ローカル利用）")

        await store.signInWithMockApple()
        #expect(store.statusLabel == "Appleでサインイン済み")

        await store.signInWithMockGoogle()
        #expect(store.statusLabel == "Googleでサインイン済み")
    }
}
