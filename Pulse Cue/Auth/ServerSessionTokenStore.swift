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
//  **Every operation reports failure rather than swallowing it.** A Keychain
//  that cannot answer, cannot write, or cannot delete is not the same as one
//  holding nothing — and the caller has to be able to tell, because "the token
//  might still be on disk" and "there is definitely no token" lead to opposite
//  decisions.
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

/// The result of writing a token.
///
/// A failure here must never be ignored: the caller is holding a live server
/// session that it has just failed to persist, and something has to be done
/// with it.
enum SessionTokenWrite: Equatable {
    case stored
    case failed(OSStatus)
}

/// The result of removing a token.
///
/// `failed` is the one that matters. A token still on disk will be picked up
/// by the next launch, so a caller that treats a failed delete as "signed
/// out" is describing a state that is not true.
enum SessionTokenDelete: Equatable {
    case removed
    /// Nothing was there. The end state the caller wanted, so a success.
    case absent
    case failed(OSStatus)
}

/// Storage for the opaque server session token.
protocol ServerSessionTokenStoring: AnyObject, Sendable {
    func read() -> SessionTokenRead
    /// Replaces any existing token, preserving the old one if the write fails.
    func store(_ token: String) -> SessionTokenWrite
    func delete() -> SessionTokenDelete
    /// Removes the token **only if** the stored value is still `token`.
    ///
    /// The difference matters when an abandoned operation cleans up after
    /// itself: a plain `delete()` would take whatever is there, including a
    /// token a *newer* sign-in had just stored. Matching first means an
    /// operation can only ever remove its own work.
    func delete(ifMatching token: String) -> SessionTokenDelete
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

    /// Update-then-add, never delete-then-add.
    ///
    /// The earlier version deleted the existing item first and then added the
    /// new one, so a failing add left the user with *no* token at all — a
    /// working session destroyed by an operation that was only supposed to
    /// replace it. `SecItemUpdate` leaves the old item untouched when it
    /// fails, which is the behaviour a replace should have.
    func store(_ token: String) -> SessionTokenWrite {
        guard let data = token.data(using: .utf8) else {
            return .failed(errSecParam)
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Re-asserted on every write so an item created by an older build
            // cannot keep a weaker accessibility class.
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updated = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch updated {
        case errSecSuccess:
            return .stored
        case errSecItemNotFound:
            break // Nothing to update; fall through to add.
        default:
            // The old item is still intact, which is the point.
            return .failed(updated)
        }

        var insert = baseQuery
        insert.merge(attributes) { _, new in new }
        let added = SecItemAdd(insert as CFDictionary, nil)
        switch added {
        case errSecSuccess:
            return .stored
        case errSecDuplicateItem:
            // Another writer added one between our update and our add. Retry
            // the update against what is now there rather than deleting it.
            let retried = SecItemUpdate(
                baseQuery as CFDictionary,
                attributes as CFDictionary
            )
            return retried == errSecSuccess ? .stored : .failed(retried)
        default:
            return .failed(added)
        }
    }

    func delete() -> SessionTokenDelete {
        let status = SecItemDelete(baseQuery as CFDictionary)
        switch status {
        case errSecSuccess:
            return .removed
        case errSecItemNotFound:
            // Nothing there is the end state a delete wanted.
            return .absent
        default:
            // The token may still be on disk. The caller must not claim to be
            // signed out.
            return .failed(status)
        }
    }

    func delete(ifMatching token: String) -> SessionTokenDelete {
        // Read-then-delete is not atomic, but the alternative — deleting
        // unconditionally — is unconditionally wrong: it would destroy a
        // newer operation's token. The window here is small and the failure
        // mode is benign (a stale token survives and is revoked server-side
        // anyway), whereas the blind delete's failure mode is signing a user
        // out of the session they just created.
        switch read() {
        case .token(token):
            return delete()
        case .token:
            // Somebody else's token is stored now. Leave it alone.
            return .absent
        case .absent:
            return .absent
        case let .unavailable(status):
            return .failed(status)
        }
    }
}

/// In-memory store for tests and previews. Never used in a shipping build.
final class InMemoryServerSessionTokenStore: ServerSessionTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    /// Set to simulate a Keychain that refuses to write.
    var writeFailure: OSStatus?
    /// Set to simulate a Keychain that cannot answer at all.
    var readFailure: OSStatus?
    /// Set to simulate a Keychain that refuses to delete.
    var deleteFailure: OSStatus?

    init(token: String? = nil) {
        self.token = token
    }

    /// Appears on reads *after* a failed write.
    ///
    /// Models a disk that turns out to hold a token even though the preflight
    /// saw none — another process, or a partially-landed write. Without it the
    /// reconciliation path is unreachable from the normal flow, because the
    /// preflight refuses a sign-in when a token is already present.
    var tokenAfterFailedWrite: String?

    /// Applies once, on the first read *after* a failed write.
    ///
    /// Lets a test model "the write failed and the Keychain is now unreadable"
    /// — the case where the app cannot prove whether a session is on disk.
    var readFailureAfterWrite: OSStatus?
    private var sawFailedWrite = false

    /// Sets the stored value directly, bypassing the simulated write failure.
    /// Test setup only: models what the disk already held.
    func setTokenForTesting(_ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        token = value
    }

    /// The stored value, ignoring simulated failures. Test inspection only.
    var storedToken: String? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    func read() -> SessionTokenRead {
        lock.lock()
        defer { lock.unlock() }
        if let readFailure { return .unavailable(readFailure) }
        if sawFailedWrite, let readFailureAfterWrite {
            return .unavailable(readFailureAfterWrite)
        }
        if sawFailedWrite, let tokenAfterFailedWrite {
            return .token(tokenAfterFailedWrite)
        }
        guard let token else { return .absent }
        return .token(token)
    }

    func store(_ newToken: String) -> SessionTokenWrite {
        lock.lock()
        defer { lock.unlock() }
        // Mirrors the real store: a failed write leaves the old value alone.
        if let writeFailure {
            sawFailedWrite = true
            return .failed(writeFailure)
        }
        token = newToken
        return .stored
    }

    func delete() -> SessionTokenDelete {
        lock.lock()
        defer { lock.unlock() }
        if let deleteFailure { return .failed(deleteFailure) }
        guard token != nil else { return .absent }
        token = nil
        return .removed
    }

    func delete(ifMatching expected: String) -> SessionTokenDelete {
        lock.lock()
        if let readFailure {
            lock.unlock()
            return .failed(readFailure)
        }
        guard token == expected else {
            lock.unlock()
            return .absent
        }
        lock.unlock()
        return delete()
    }
}

extension ServerSessionTokenStoring {
    /// The token if one was read, and `nil` for *both* absent and unavailable.
    ///
    /// Deliberately narrow. Launch restore and account deletion must tell
    /// those two apart — an unreadable Keychain is not an absent token — so
    /// neither uses this. It exists for callers that are trying to get rid of
    /// the token anyway.
    func tokenIfPresent() -> String? {
        if case let .token(value) = read() { return value }
        return nil
    }
}
