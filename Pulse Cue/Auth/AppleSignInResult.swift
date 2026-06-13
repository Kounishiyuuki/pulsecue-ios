//
//  AppleSignInResult.swift
//  Pulse Cue
//
//  A non-sensitive, framework-independent value type carrying the *only*
//  pieces of a Sign in with Apple result PulseCue keeps: an optional display
//  name and an optional email, both for display only.
//
//  IMPORTANT — by design this type can hold no secrets. It has no field for,
//  and never receives, the Apple `identityToken`, `authorizationCode`, or the
//  Apple `user` identifier. The AuthenticationServices-specific mapping lives
//  in `LoginView`; this type stays import-free (Foundation only) so the auth
//  model/store never depend on AuthenticationServices.
//

import Foundation

struct AppleSignInResult: Equatable {
    /// Display-only name (Apple returns this only on the first authorization).
    let displayName: String?
    /// Display-only email (Apple returns this only on the first authorization).
    let email: String?

    /// Builds a result from already-extracted strings, trimming blanks to nil.
    init(displayName: String?, email: String?) {
        self.displayName = AppleSignInResult.normalized(displayName)
        self.email = AppleSignInResult.normalized(email)
    }

    /// Builds a result from Apple's `PersonNameComponents` (present only on the
    /// first authorization). Falls back to a nil display name when no usable
    /// name is available.
    init(nameComponents: PersonNameComponents?, email: String?) {
        self.init(
            displayName: AppleSignInResult.formattedName(from: nameComponents),
            email: email
        )
    }

    /// Formats `PersonNameComponents` into a single display string, or nil when
    /// the components are missing/empty.
    static func formattedName(from components: PersonNameComponents?) -> String? {
        guard let components else { return nil }
        let formatter = PersonNameComponentsFormatter()
        formatter.style = .default
        return normalized(formatter.string(from: components))
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
