//
//  AuthSessionStore.swift
//  Pulse Cue
//
//  Observable holder for the local auth-shell state. Provided in the app
//  environment so future PRs (Login/Register UI, Apple, Google) have a ready
//  place to read/drive account state from.
//
//  Hard boundaries for this phase:
//    - No token persistence. No Keychain. No UserDefaults credential storage.
//    - No real network / SDK. Providers are mocks.
//    - Does NOT gate app usage: `allowsUnauthenticatedAppUsage` is always
//      true, and existing MVP features never consult this store.
//    - State is in-memory only; it is intentionally not persisted across
//      launches (a relaunch returns to the default `guest` mode).
//

import Foundation
import Combine

@MainActor
final class AuthSessionStore: ObservableObject {

    /// The current local auth state. Defaults to `.guest` to reflect that the
    /// app currently runs in local-only mode for everyone. Read-only from the
    /// outside; transitions go through the explicit methods below.
    @Published private(set) var state: AuthState

    /// Documents (and lets tests assert) that the auth shell never blocks the
    /// app. Existing MVP flows must remain usable regardless of `state`.
    let allowsUnauthenticatedAppUsage = true

    private let guestProvider: AuthProvider
    private let appleProvider: AuthProvider
    private let googleProvider: AuthProvider

    init(
        initialState: AuthState = .guest,
        guestProvider: AuthProvider = GuestAuthProvider(),
        appleProvider: AuthProvider = MockAppleAuthProvider(),
        googleProvider: AuthProvider = MockGoogleAuthProvider()
    ) {
        self.state = initialState
        self.guestProvider = guestProvider
        self.appleProvider = appleProvider
        self.googleProvider = googleProvider
    }

    /// The attached session, if signed in. `nil` for guest / signed-out.
    var session: AuthSession? { state.session }

    /// Japanese label for the read-only Settings status row.
    var statusLabel: String { state.statusLabel }

    /// Whether the user is in a signed-in (non-guest) state.
    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    // MARK: - Transitions

    /// Enter explicit local-only guest mode.
    func continueAsGuest() {
        state = .guest
    }

    /// Mock Apple sign-in (placeholder for PR #114). No real auth occurs.
    func signInWithMockApple() async {
        guard let session = try? await appleProvider.signIn() else { return }
        state = .signedIn(session)
    }

    /// Mock Google sign-in (placeholder for PR #115). No real auth occurs.
    func signInWithMockGoogle() async {
        guard let session = try? await googleProvider.signIn() else { return }
        state = .signedIn(session)
    }

    /// Clear any account context. The app stays usable afterwards.
    func signOut() {
        state = .signedOut
    }
}
