//
//  LinkedAccount.swift
//  Pulse Cue
//
//  What PulseCue remembers about an Apple or Google link, and where it keeps
//  it. There is no PulseCue account and no server: linking records, on this
//  device only, which provider identity the user attached to their local
//  profile so the app can show it again after a relaunch.
//
//  Nothing here is a credential. No identity token, authorization code,
//  access token, refresh token or client secret is ever read, let alone
//  stored — the provider SDKs own all of that. What is kept is the provider's
//  stable user identifier plus the display name and email the user already
//  sees on screen.
//
//  UserDefaults is therefore the right home rather than the Keychain: it
//  holds no secret, and the identifier alone authenticates nothing. Apple's
//  identifier is opaque and scoped to this app, and it is re-validated
//  against `ASAuthorizationAppleIDProvider` on every launch, so a copied
//  value cannot resurrect a link that Apple has revoked.
//

import Foundation

/// A provider identity attached to this device's profile.
struct LinkedAccount: Equatable, Codable {
    /// Only `.apple` or `.google`; guest is the absence of a link.
    let provider: AuthProviderKind
    /// The provider's stable identifier for this user
    /// (`ASAuthorizationAppleIDCredential.user`, `GIDGoogleUser.userID`).
    let userIdentifier: String
    let displayName: String?
    let email: String?

    init(provider: AuthProviderKind, userIdentifier: String, displayName: String? = nil, email: String? = nil) {
        self.provider = provider
        self.userIdentifier = userIdentifier
        self.displayName = displayName
        self.email = email
    }

    var session: AuthSession {
        AuthSession(
            provider: provider,
            displayName: displayName,
            email: email,
            userIdentifier: userIdentifier
        )
    }
}

@MainActor
protocol LinkedAccountStoring: AnyObject {
    var linkedAccount: LinkedAccount? { get }
    func save(_ account: LinkedAccount)
    func clear()
}

/// The on-device record of the link. Deliberately tiny and non-secret.
@MainActor
final class UserDefaultsLinkedAccountStore: LinkedAccountStoring {
    private let defaults: UserDefaults
    private let key = "auth.linkedAccount"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var linkedAccount: LinkedAccount? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LinkedAccount.self, from: data)
    }

    func save(_ account: LinkedAccount) {
        guard let data = try? JSONEncoder().encode(account) else { return }
        defaults.set(data, forKey: key)
    }

    /// Unlinking forgets the provider identity and nothing else. Workouts,
    /// routines, history, gyms and health entries are untouched — they were
    /// never tied to the link.
    func clear() {
        defaults.removeObject(forKey: key)
    }
}

/// In-memory store for tests and previews.
@MainActor
final class InMemoryLinkedAccountStore: LinkedAccountStoring {
    private(set) var linkedAccount: LinkedAccount?

    init(linkedAccount: LinkedAccount? = nil) {
        self.linkedAccount = linkedAccount
    }

    func save(_ account: LinkedAccount) { linkedAccount = account }
    func clear() { linkedAccount = nil }
}
