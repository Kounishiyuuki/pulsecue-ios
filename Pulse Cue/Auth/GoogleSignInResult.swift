//
//  GoogleSignInResult.swift
//  Pulse Cue
//
//  A non-sensitive, framework-independent value type carrying the *only*
//  pieces of a Google Sign-In result PulseCue keeps: an optional display name
//  and an optional email, both for display only. Mirrors `AppleSignInResult`.
//
//  IMPORTANT — by design this type can hold no secrets. It has no field for,
//  and never receives, the Google `idToken`, `accessToken`, `refreshToken`,
//  `serverAuthCode`, or the Google user identifier. The GoogleSignIn-specific
//  mapping lives in `LoginView`; this type stays import-free (Foundation only)
//  so the auth model/store never depend on the GoogleSignIn SDK.
//

import Foundation

struct GoogleSignInResult: Equatable {
    /// Display-only name from the Google profile, if available.
    let displayName: String?
    /// Display-only email from the Google profile, if available.
    let email: String?

    /// Builds a result from already-extracted strings, trimming blanks to nil.
    init(displayName: String?, email: String?) {
        self.displayName = GoogleSignInResult.normalized(displayName)
        self.email = GoogleSignInResult.normalized(email)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
