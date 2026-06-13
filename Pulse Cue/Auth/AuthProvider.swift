//
//  AuthProvider.swift
//  Pulse Cue
//
//  The auth-provider abstraction plus its mock implementations.
//
//  The protocol exists so a later phase can swap in real Sign in with Apple
//  (PR #114) and Google Sign-In (PR #115) implementations without touching
//  call sites. In this phase every provider is a local mock: no SDK, no
//  network, no URL scheme, no OAuth client ID, and no tokens of any kind.
//

import Foundation

/// Produces an `AuthSession` for a given sign-in path.
///
/// `signIn()` is `async throws` purely to be future-proof: the real Apple /
/// Google flows are asynchronous and can fail. The current mocks complete
/// immediately and never throw.
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

/// Placeholder for Sign in with Apple (PR #114). Returns only non-sensitive
/// display metadata; performs no real authentication.
struct MockAppleAuthProvider: AuthProvider {
    let kind: AuthProviderKind = .apple

    func signIn() async throws -> AuthSession {
        AuthSession(provider: .apple, displayName: "Apple ユーザー（準備中）", email: nil)
    }
}

/// Placeholder for Google Sign-In (PR #115). Returns only non-sensitive
/// display metadata; performs no real authentication and adds no SDK.
struct MockGoogleAuthProvider: AuthProvider {
    let kind: AuthProviderKind = .google

    func signIn() async throws -> AuthSession {
        AuthSession(provider: .google, displayName: "Google ユーザー（準備中）", email: nil)
    }
}
