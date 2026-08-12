//
//  AuthProvider.swift
//  Pulse Cue
//
//  The guest path.
//
//  Apple and Google no longer have provider types here: their flows are
//  driven by the system / SDK UI in `LoginView` and recorded through
//  `AuthSessionStore.completeAppleSignIn` / `completeGoogleSignIn`. The
//  earlier mock providers were removed because they fabricated a signed-in
//  state with no provider identity behind it.
//

import Foundation

/// Produces an `AuthSession` for a given sign-in path.
protocol AuthProvider {
    var kind: AuthProviderKind { get }
    func signIn() async throws -> AuthSession
}

/// Explicit local-only usage. Represents "use the app without an account".
struct GuestAuthProvider: AuthProvider {
    let kind: AuthProviderKind = .guest

    func signIn() async throws -> AuthSession {
        AuthSession(provider: .guest, displayName: "ゲスト", email: nil)
    }
}
