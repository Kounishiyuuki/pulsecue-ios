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
        store.completeAppleSignIn(userIdentifier: "apple-test-user", displayName: "Apple ユーザー", email: nil)

        #expect(store.isSignedIn == true)
        #expect(store.session?.provider == .apple)
        #expect(store.session?.email == nil)
        #expect(store.statusLabel == "Appleと連携済み（この端末のみ）")
    }

    @Test
    func googleButtonSignsInWithMockGoogle() async {
        let store = AuthSessionStore(initialState: .signedOut)

        // "Googleで続ける"
        store.completeGoogleSignIn(userIdentifier: "google-test-user", displayName: "Google ユーザー", email: nil)

        #expect(store.isSignedIn == true)
        #expect(store.session?.provider == .google)
        #expect(store.session?.email == nil)
        #expect(store.statusLabel == "Googleと連携済み（この端末のみ）")
    }

    // MARK: - Settings logout availability

    @Test
    func logoutIsOnlyAvailableWhenSignedIn() async {
        let store = AuthSessionStore(initialState: .guest)
        // Guest / signed-out are not "signed in", so the Settings logout
        // action stays hidden.
        #expect(store.isSignedIn == false)

        store.completeAppleSignIn(userIdentifier: "apple-test-user", displayName: "Apple ユーザー", email: nil)
        // After a mock sign-in the logout action becomes available…
        #expect(store.isSignedIn == true)

        store.unlinkAccount()
        // …and signing out returns to a non-signed-in state.
        #expect(store.isSignedIn == false)
        #expect(store.state == .guest)
        #expect(store.session == nil)
    }

    // MARK: - Switching providers via the sheet

    @Test
    func switchingFromAppleToGoogleUpdatesSession() async {
        let store = AuthSessionStore(initialState: .signedOut)

        store.completeAppleSignIn(userIdentifier: "apple-test-user", displayName: "Apple ユーザー", email: nil)
        #expect(store.session?.provider == .apple)

        store.completeGoogleSignIn(userIdentifier: "google-test-user", displayName: "Google ユーザー", email: nil)
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

        store.completeAppleSignIn(userIdentifier: "apple-test-user", displayName: "Apple ユーザー", email: nil)
        #expect(store.statusLabel == "Appleと連携済み（この端末のみ）")

        store.completeGoogleSignIn(userIdentifier: "google-test-user", displayName: "Google ユーザー", email: nil)
        #expect(store.statusLabel == "Googleと連携済み（この端末のみ）")
    }
}

/// The Settings account section, per server state and local link. Sign-in
/// state comes from the server account only; the local link is shown as a
/// link, and the old fixed 「この端末のみ」 badge is gone.
@MainActor
struct AccountSettingsPresentationTests {

    private static let profile = ServerAccountProfile(
        user: .init(id: "user-1", state: "active", displayName: "テスト", createdAt: 1),
        linkedProviders: [.init(provider: "apple", linkedAt: 1)],
        session: .init(expiresAt: 1_800_000_000)
    )

    private static let everyState: [ServerAccountState] = [
        .guest, .unresolved, .restoring, .signingIn, .authenticated(profile),
        .unreachable, .notConfigured, .localCleanupFailed,
    ]

    @Test func signInEntryFollowsTheServerStateOnly() {
        for state in Self.everyState {
            for link in [nil, AuthProviderKind.apple, .google] {
                let presentation = AccountSettingsPresentation(serverState: state, linkedProvider: link)
                #expect(presentation.showsSignInEntry == state.offersSignIn, "\(state) / \(String(describing: link))")
            }
        }
        #expect(AccountSettingsPresentation(serverState: .guest, linkedProvider: nil).showsSignInEntry)
        #expect(AccountSettingsPresentation(serverState: .notConfigured, linkedProvider: nil).showsSignInEntry)
        for state: ServerAccountState in [.authenticated(Self.profile), .unresolved, .restoring, .unreachable, .localCleanupFailed] {
            #expect(!AccountSettingsPresentation(serverState: state, linkedProvider: .apple).showsSignInEntry, "\(state)")
        }
    }

    @Test func serverStatusTextPerState() {
        #expect(ServerAccountState.guest.statusLabel == "ゲスト（この端末に保存）")
        #expect(ServerAccountState.authenticated(Self.profile).statusLabel == "Appleでサインイン済み")
        #expect(ServerAccountState.restoring.statusLabel == "アカウントを確認中…")
        #expect(ServerAccountState.unresolved.statusLabel == "アカウントを確認中…")
        #expect(ServerAccountState.unreachable.statusLabel == "オフラインのためアカウント状態を確認できません")
        #expect(ServerAccountState.localCleanupFailed.statusLabel == "サインアウトは完了していません")
        #expect(ServerAccountState.notConfigured.statusLabel == "アカウント機能は未設定です")
        for state in Self.everyState where state != .guest {
            #expect(!state.statusLabel.contains("ゲスト"), "\(state) must not read as guest")
        }
    }

    @Test func authenticatedWithALocalLinkShowsTheLinkAsALinkOnly() {
        let apple = AccountSettingsPresentation(serverState: .authenticated(Self.profile), linkedProvider: .apple)
        #expect(apple.localLinkLabel == "Appleと連携済み")
        #expect(!apple.showsSignInEntry)
        let google = AccountSettingsPresentation(serverState: .authenticated(Self.profile), linkedProvider: .google)
        #expect(google.localLinkLabel == "Googleと連携済み")
    }

    @Test func authenticatedWithoutALocalLinkIsStillSignedIn() {
        let presentation = AccountSettingsPresentation(serverState: .authenticated(Self.profile), linkedProvider: nil)
        #expect(presentation.localLinkLabel == nil)
        #expect(!presentation.showsSignInEntry)
        #expect(presentation.serverState.isAuthenticated)
    }

    @Test func guestWithALeftoverLinkIsNeverShownAsSignedIn() {
        let presentation = AccountSettingsPresentation(serverState: .guest, linkedProvider: .apple)
        #expect(presentation.localLinkLabel == "Appleと連携済み")
        #expect(!presentation.serverState.isAuthenticated)
        #expect(presentation.showsSignInEntry)
    }

    @Test func noLinkMeansNoLinkRowAndNoDeviceOnlyClaim() {
        for state in Self.everyState {
            #expect(AccountSettingsPresentation(serverState: state, linkedProvider: nil).localLinkLabel == nil)
            #expect(AccountSettingsPresentation(serverState: state, linkedProvider: .guest).localLinkLabel == nil)
            for link in [AuthProviderKind.apple, .google] {
                let label = AccountSettingsPresentation(serverState: state, linkedProvider: link).localLinkLabel
                #expect(label?.contains("この端末のみ") == false)
            }
        }
    }
}
