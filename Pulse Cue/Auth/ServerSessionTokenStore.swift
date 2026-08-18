//
//  ServerSessionTokenStore.swift
//  Pulse Cue
//
//  The PulseCue server session token, in the Keychain.
//
//  This is the first real credential the app has ever held. Everything before
//  it — `LinkedAccount`, the provider identifier, display names — was
//  non-secret and lived in UserDefaults quite correctly. This token is not
//  like those: anyone holding it *is* the user until it expires or is
//  revoked, so UserDefaults is not an option. UserDefaults is a plist in the
//  app container, readable by anything that gets at the container and
//  included in backups by default.
//
//  Accessibility is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
//
//    AfterFirstUnlock — the app needs to restore its session on a launch that
//      may happen in the background, before the user has unlocked since boot.
//      `WhenUnlocked` would fail those launches and drop the user to Guest for
//      no reason.
//
//    ThisDeviceOnly — the token is not included in backups and does not
//      migrate to a new device. That is deliberate: a restored backup must not
//      carry a live session onto different hardware. Signing in again is a
//      small cost; a session silently following a device image is not.
//
//  The token is only ever a `String` in memory for the length of one request.
//  It is never logged, never put in an error, and never written anywhere else.
//

import Foundation
import Security

/// What a read of the stored session token found.
///
/// The three cases are genuinely different and the difference is
/// load-bearing. "There is no token" means the user is a guest. "The Keychain
/// could not answer" means we do not know — and treating that as "no token"
/// would sign someone out because the device happened to be locked when a
/// background launch ran.
enum SessionTokenRead: Equatable {
    case token(String)
    /// Read successfully; there is nothing stored.
    case absent
    /// The Keychain itself failed. Says nothing about whether a token exists.
    case unavailable(OSStatus)
}

/// Storage for the opaque server session token.
protocol ServerSessionTokenStoring: AnyObject, Sendable {
    func read() -> SessionTokenRead
    /// Replaces any existing token. Returns false if the write failed.
    @discardableResult func saveToken(_ token: String) -> Bool
    @discardableResult func deleteToken() -> Bool
}

final class KeychainServerSessionTokenStore: ServerSessionTokenStoring, @unchecked Sendable {

    private let service: String
    private let account: String

    init(
        service: String = "com.kounishiyuuki.pulsecue.session",
        account: String = "server-session-token"
    ) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read() -> SessionTokenRead {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let token = String(data: data, encoding: .utf8),
                  !token.isEmpty
            else {
                // An item exists but holds nothing usable. Treat it as absent
                // rather than as a failure: there is genuinely no session here,
                // and a fresh sign-in will replace it.
                return .absent
            }
            return .token(token)

        case errSecItemNotFound:
            return .absent

        default:
            // Anything else — most plausibly `errSecInteractionNotAllowed` on a
            // background launch before the first unlock — is the Keychain
            // failing to answer, not evidence that no session exists. Reporting
            // it as absent would drop the user to Guest for a transient
            // condition and destroy their session on the next write.
            return .unavailable(status)
        }
    }

    @discardableResult
    func saveToken(_ token: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }

        // Delete-then-add rather than update: it is one code path for "first
        // sign-in" and "signed in again", and it guarantees the accessibility
        // attribute is the one set here rather than one inherited from an
        // older item written by an earlier version of the app.
        SecItemDelete(baseQuery as CFDictionary)

        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func deleteToken() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        // Nothing there is the state we wanted, so it counts as success.
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// In-memory store for tests and previews. Never used in a shipping build.
final class InMemoryServerSessionTokenStore: ServerSessionTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    /// Set to simulate a Keychain that refuses to write.
    var failsToSave = false

    init(token: String? = nil) {
        self.token = token
    }

    /// Set to simulate a Keychain that cannot answer at all.
    var readFailure: OSStatus?

    func read() -> SessionTokenRead {
        lock.lock()
        defer { lock.unlock() }
        if let readFailure { return .unavailable(readFailure) }
        guard let token else { return .absent }
        return .token(token)
    }

    @discardableResult
    func saveToken(_ newToken: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !failsToSave else { return false }
        token = newToken
        return true
    }

    @discardableResult
    func deleteToken() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        token = nil
        return true
    }
}

extension ServerSessionTokenStoring {
    /// The token if one was read, and `nil` for *both* absent and unavailable.
    ///
    /// Deliberately not used by launch restore, which has to tell those two
    /// apart. It exists for callers where the distinction genuinely does not
    /// matter — logout and deletion, which are trying to get rid of the token
    /// either way.
    func tokenIfPresent() -> String? {
        if case let .token(value) = read() { return value }
        return nil
    }
}
