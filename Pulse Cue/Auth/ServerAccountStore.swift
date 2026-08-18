//
//  ServerAccountStore.swift
//  Pulse Cue
//
//  The PulseCue server account: restore at launch, sign in, sign out, delete.
//
//  Three rules run through everything here.
//
//  **Only the server decides who you are.** The app hands over a signed
//  provider token and nothing else. `ASAuthorizationAppleIDCredential.user`,
//  `GIDGoogleUser.userID`, emails and display names are never sent as
//  identity — the server takes the subject out of the signature it verified.
//  There is no field on `AppleSignInRequest` or `GoogleSignInRequest` for
//  them, so it is not a discipline anyone has to remember.
//
//  **A network failure is not a sign-out.** Only an actual rejection clears
//  the Keychain. A timeout leaves the session exactly where it was and the
//  state becomes `.unreachable`, because the alternative signs people out for
//  riding a train.
//
//  **Guest is untouched.** Everything below is additive. With no API
//  configured, no session, or no network, every local feature works exactly
//  as it did, and local training data is never deleted by anything in this
//  file — not by logout, not by account deletion.
//

import Foundation
import Combine

/// What a deletion attempt achieved, as far as the app can truthfully say.
enum AccountDeletionResult: Equatable {
    /// The server confirmed the account is gone.
    case deleted
    /// Accepted and irreversible, but provider revocation has not finished.
    case pending
    /// The account is still there.
    case failed
}

@MainActor
final class ServerAccountStore: ObservableObject {

    @Published private(set) var state: ServerAccountState
    /// The most recent failure, for the UI to show and then clear.
    @Published private(set) var lastFailure: ServerAccountFailure?

    private let api: any PulseCueAccountAPI
    private let tokenStore: any ServerSessionTokenStoring
    private let deviceName: String?

    init(
        api: any PulseCueAccountAPI,
        tokenStore: any ServerSessionTokenStoring,
        deviceName: String? = nil
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.deviceName = deviceName
        self.state = api.isConfigured ? .guest : .notConfigured
    }

    // MARK: - Launch restore

    /// Re-establishes the account at launch.
    ///
    ///   no token           → guest
    ///   token, 200         → authenticated
    ///   token, 401         → drop the token, guest
    ///   token, no network  → keep the token, unreachable
    ///
    /// The third and fourth lines are the ones that matter. They look similar
    /// from the call site and mean opposite things.
    func restore() async {
        guard api.isConfigured else {
            state = .notConfigured
            return
        }
        let stored = tokenStore.read()
        guard case let .token(token) = stored else {
            if case .unavailable = stored {
                // The Keychain could not answer — most plausibly a background
                // launch before the first unlock. That says nothing about
                // whether a session exists, so nothing is deleted and the user
                // is not downgraded to Guest. Local features are unaffected.
                state = .unreachable
                return
            }
            state = .guest
            return
        }

        state = .restoring
        do {
            let profile = try await api.fetchProfile(sessionToken: token)
            guard profile.isActive else {
                // The account is being deleted. Nothing to come back to.
                discardSession()
                return
            }
            state = .authenticated(profile)
        } catch let error as AccountAPIError where error.invalidatesStoredSession {
            // The server genuinely refused it: revoked, expired, or the
            // account is gone. This is the only path that clears the Keychain.
            discardSession()
        } catch {
            // Offline, timed out, 5xx, or a response we could not read. The
            // session is probably fine and the app is fully usable; only
            // account features wait.
            state = .unreachable
        }
    }

    // MARK: - Sign-in

    /// Trades a verified Apple credential for a PulseCue session.
    ///
    /// `authorizationCode` is required. Without it the server cannot obtain
    /// the refresh token it needs to revoke at account deletion, so a sign-in
    /// missing it must fail rather than create an account that can never be
    /// deleted properly. Apple provides it on every authorization; its
    /// absence means something went wrong, not that it is optional.
    func signInWithApple(
        identityToken: String,
        authorizationCode: String,
        rawNonce: String
    ) async {
        guard api.isConfigured else {
            fail(.notConfigured)
            return
        }
        guard !identityToken.isEmpty, !authorizationCode.isEmpty, !rawNonce.isEmpty else {
            fail(.missingProviderCredential)
            return
        }

        state = .signingIn
        await completeSignIn {
            try await self.api.signInWithApple(
                AppleSignInRequest(
                    identityToken: identityToken,
                    authorizationCode: authorizationCode,
                    rawNonce: rawNonce,
                    deviceName: self.deviceName
                )
            )
        }
    }

    /// Trades a Google ID token for a PulseCue session.
    ///
    /// The ID token is the only thing sent. The SDK's `userID`, email and
    /// profile name are not identity as far as the server is concerned, and
    /// there is nowhere on the request to put them.
    func signInWithGoogle(idToken: String) async {
        guard api.isConfigured else {
            fail(.notConfigured)
            return
        }
        guard !idToken.isEmpty else {
            fail(.missingProviderCredential)
            return
        }

        state = .signingIn
        await completeSignIn {
            try await self.api.signInWithGoogle(
                GoogleSignInRequest(idToken: idToken, deviceName: self.deviceName)
            )
        }
    }

    private func completeSignIn(
        _ operation: () async throws -> ServerSessionResponse
    ) async {
        do {
            let response = try await operation()
            guard tokenStore.saveToken(response.sessionToken) else {
                // A session we cannot persist would evaporate at the next
                // launch and look like a random sign-out. Better to say so.
                state = .guest
                fail(.couldNotStoreSession)
                return
            }
            // Ask the server who this is rather than assuming. It is one more
            // round trip and it means the UI is describing a confirmed
            // account, not a hopeful one.
            let profile = try await api.fetchProfile(sessionToken: response.sessionToken)
            state = .authenticated(profile)
            lastFailure = nil
        } catch let error as AccountAPIError {
            state = tokenStore.tokenIfPresent() == nil ? .guest : .unreachable
            fail(failure(for: error))
        } catch {
            state = .guest
            fail(.unreachable)
        }
    }

    // MARK: - Logout

    /// Signs out of this device.
    ///
    /// The local part always happens. A user must never be stuck signed in
    /// because the server is unreachable, so the token is dropped whatever
    /// the server says; the server-side revocation is best effort, and the
    /// session expires on its own within 60 days regardless.
    ///
    /// Local training data is untouched.
    @discardableResult
    func logout() async -> Bool {
        let token = tokenStore.tokenIfPresent()
        var revokedOnServer = false

        if let token {
            do {
                try await api.logout(sessionToken: token)
                revokedOnServer = true
            } catch let error as AccountAPIError where error.invalidatesStoredSession {
                // Already dead server-side. That is the end state we wanted.
                revokedOnServer = true
            } catch {
                revokedOnServer = false
            }
        }

        discardSession()
        return revokedOnServer
    }

    // MARK: - Account deletion

    /// Asks the server to delete the PulseCue account.
    ///
    /// **This is not device data deletion.** Workouts, routines, history,
    /// gyms and health entries are local and stay exactly where they are. The
    /// UI must keep the two apart, because a user who confuses them loses
    /// everything.
    ///
    /// The server answers `202` when deletion is under way but provider
    /// revocation has not finished. That is a success: irreversible, just not
    /// complete. Either way the local session goes.
    func deleteAccount() async -> AccountDeletionResult {
        guard let token = tokenStore.tokenIfPresent() else {
            // Nothing to delete server-side; make sure we are locally clean.
            discardSession()
            return .deleted
        }

        do {
            // 200 and 202 are both accepted and irreversible, but only 200
            // means the account is actually gone. The UI has to be able to
            // tell them apart, so the distinction is carried out of here
            // rather than flattened into a Bool.
            let outcome = try await api.deleteAccount(sessionToken: token)
            discardSession()
            return outcome == .pending ? .pending : .deleted
        } catch let error as AccountAPIError where error.invalidatesStoredSession {
            // The session is gone, so either it was already deleted or it is
            // no longer usable. Locally the outcome is the same.
            discardSession()
            return .deleted
        } catch {
            // The account is still there. Do not clear the session and do not
            // tell the user it worked.
            fail(.unreachable)
            return .failed
        }
    }

    // MARK: - Internals

    /// Forgets the session on this device. Never touches local training data.
    private func discardSession() {
        tokenStore.deleteToken()
        state = api.isConfigured ? .guest : .notConfigured
    }

    private func fail(_ failure: ServerAccountFailure) {
        lastFailure = failure
    }

    func clearFailure() {
        lastFailure = nil
    }

    private func failure(for error: AccountAPIError) -> ServerAccountFailure {
        switch error {
        case .invalidCredentials: return .rejected
        case .notConfigured: return .notConfigured
        case .unavailable, .malformedResponse: return .unreachable
        }
    }
}
