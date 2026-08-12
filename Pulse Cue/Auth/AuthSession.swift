//
//  AuthSession.swift
//  Pulse Cue
//
//  Non-sensitive, display-only session metadata for the auth shell.
//
//  IMPORTANT — by design this type holds **no secrets**:
//    - no access token
//    - no refresh token
//    - no ID token
//    - no authorization code
//    - no provider credential of any kind
//
//  It carries only what a future Settings/account screen would *display*.
//  When real Apple / Google sign-in lands, any tokens must live behind a
//  separate, intentionally-designed secure store — never on this struct.
//

import Foundation

struct AuthSession: Equatable {
    /// Which (future) provider produced this session.
    let provider: AuthProviderKind
    /// Optional human-readable name for display (e.g. "ゲスト"). Never a credential.
    let displayName: String?
    /// Optional email for display only. Never used for auth in this phase.
    let email: String?
    /// The provider's stable identifier for this user
    /// (`ASAuthorizationAppleIDCredential.user`, `GIDGoogleUser.userID`), or
    /// `nil` for guest. Opaque and app-scoped — an identifier, never a
    /// credential, and it authenticates nothing on its own.
    let userIdentifier: String?

    init(
        provider: AuthProviderKind,
        displayName: String? = nil,
        email: String? = nil,
        userIdentifier: String? = nil
    ) {
        self.provider = provider
        self.displayName = displayName
        self.email = email
        self.userIdentifier = userIdentifier
    }
}
