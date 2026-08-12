//
//  AccountLinkProviders.swift
//  Pulse Cue
//
//  The two provider-shaped things the app needs after a link exists: asking
//  Apple whether its credential is still good, and asking the Google SDK to
//  restore (or drop) its own session.
//
//  Both are behind protocols so the whole restore / unlink flow is testable
//  without a signing identity, a network, or a device. Neither ever hands a
//  token to the app — Apple answers with a state, Google answers with the
//  profile fields already shown on screen.
//

import Foundation

#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

// MARK: - Apple

/// Whether a stored Apple identifier still refers to a live link.
enum AppleCredentialState: Equatable {
    /// Apple still recognises this user for this app.
    case authorized
    /// Revoked in Settings, signed out of iCloud, or unknown to Apple. The
    /// local link must be dropped — the two are deliberately not
    /// distinguished, because the app's response is the same.
    case unavailable
}

protocol AppleCredentialChecking: Sendable {
    func credentialState(forUserID userID: String) async -> AppleCredentialState
}

struct SystemAppleCredentialChecker: AppleCredentialChecking {
    func credentialState(forUserID userID: String) async -> AppleCredentialState {
        #if canImport(AuthenticationServices)
        await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, _ in
                continuation.resume(returning: state == .authorized ? .authorized : .unavailable)
            }
        }
        #else
        .unavailable
        #endif
    }
}

// MARK: - Google

/// The non-secret parts of a restored Google session.
struct RestoredGoogleUser: Equatable {
    let userIdentifier: String
    let displayName: String?
    let email: String?
}

@MainActor
protocol GoogleSessionManaging: AnyObject {
    /// Asks the SDK to bring back the previous sign-in. The SDK owns the
    /// credential; the app never copies it anywhere.
    func restorePreviousSignIn() async -> RestoredGoogleUser?
    /// Ends the SDK's session. Not `disconnect`, which revokes the app's
    /// access grant entirely — unlinking should not force the user to
    /// re-approve scopes if they link again.
    func signOut()
}

@MainActor
final class GoogleSessionManager: GoogleSessionManaging {
    static let shared = GoogleSessionManager()

    func restorePreviousSignIn() async -> RestoredGoogleUser? {
        #if canImport(GoogleSignIn)
        await withCheckedContinuation { continuation in
            GIDSignIn.sharedInstance.restorePreviousSignIn { user, _ in
                guard let user, let userID = user.userID else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: RestoredGoogleUser(
                    userIdentifier: userID,
                    displayName: user.profile?.name,
                    email: user.profile?.email
                ))
            }
        }
        #else
        nil
        #endif
    }

    func signOut() {
        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.signOut()
        #endif
    }
}
