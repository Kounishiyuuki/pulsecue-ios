//
//  AuthSessionStore.swift
//  Pulse Cue
//
//  The app's account state. PulseCue has no server and no PulseCue account:
//  signing in with Apple or Google *links* a provider identity to this
//  device's local profile, so the app can show who is linked and restore that
//  display after a relaunch. Nothing syncs, nothing is backed up, and nothing
//  is stored anywhere but this device.
//
//  Guest is always a complete way to use the app. Linking and unlinking never
//  touch workouts, routines, history, gyms or health entries — those are
//  local data that was never owned by the link.
//
//  No token, authorization code or client secret is read or persisted here.
//  The provider SDKs own credentials; this store keeps a stable identifier
//  and the display fields the user already sees.
//

import Foundation
import Combine

@MainActor
final class AuthSessionStore: ObservableObject {
    @Published private(set) var state: AuthState

    /// The app is fully usable without linking anything, forever.
    let allowsUnauthenticatedAppUsage = true

    private let linkedAccountStore: any LinkedAccountStoring
    private let appleCredentials: any AppleCredentialChecking
    private let googleSession: any GoogleSessionManaging

    init(
        initialState: AuthState = .guest,
        linkedAccountStore: (any LinkedAccountStoring)? = nil,
        appleCredentials: (any AppleCredentialChecking)? = nil,
        googleSession: (any GoogleSessionManaging)? = nil
    ) {
        self.state = initialState
        self.linkedAccountStore = linkedAccountStore ?? UserDefaultsLinkedAccountStore()
        self.appleCredentials = appleCredentials ?? SystemAppleCredentialChecker()
        self.googleSession = googleSession ?? GoogleSessionManager.shared
    }

    var session: AuthSession? { state.session }
    var statusLabel: String { state.statusLabel }

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    /// The identity currently linked to this device, if any.
    var linkedAccount: LinkedAccount? { linkedAccountStore.linkedAccount }

    // MARK: - Guest

    func continueAsGuest() {
        state = .guest
    }

    // MARK: - Linking

    /// Records an Apple link. Called with the credential's stable `user` plus
    /// whatever display fields Apple returned — Apple only sends name and
    /// email on the very first authorization, so both stay optional.
    func completeAppleSignIn(userIdentifier: String, displayName: String?, email: String?) {
        link(
            LinkedAccount(
                provider: .apple,
                userIdentifier: userIdentifier,
                displayName: displayName,
                email: email
            )
        )
    }

    /// Records a Google link from the SDK's `GIDGoogleUser`.
    func completeGoogleSignIn(userIdentifier: String, displayName: String?, email: String?) {
        link(
            LinkedAccount(
                provider: .google,
                userIdentifier: userIdentifier,
                displayName: displayName,
                email: email
            )
        )
    }

    private func link(_ account: LinkedAccount) {
        linkedAccountStore.save(account)
        state = .signedIn(account.session)
    }

    // MARK: - Restoration

    /// Re-establishes the linked display at launch, asking the provider first
    /// so the app never shows a link the provider no longer honours.
    ///
    /// Apple: the stored identifier is checked with
    /// `ASAuthorizationAppleIDProvider`; anything but `authorized` (revoked in
    /// Settings, signed out of iCloud, unknown) drops the link.
    /// Google: the SDK restores its own session, and the app takes only the
    /// identifier and profile fields from it.
    func restoreLinkedAccount() async {
        guard let stored = linkedAccountStore.linkedAccount else { return }

        switch stored.provider {
        case .apple:
            let credentialState = await appleCredentials.credentialState(forUserID: stored.userIdentifier)
            guard credentialState == .authorized else {
                dropLinkAndFallBackToGuest()
                return
            }
            state = .signedIn(stored.session)

        case .google:
            guard let user = await googleSession.restorePreviousSignIn() else {
                dropLinkAndFallBackToGuest()
                return
            }
            // Refresh the display fields; the identifier is what identifies.
            let refreshed = LinkedAccount(
                provider: .google,
                userIdentifier: user.userIdentifier,
                displayName: user.displayName ?? stored.displayName,
                email: user.email ?? stored.email
            )
            linkedAccountStore.save(refreshed)
            state = .signedIn(refreshed.session)

        case .guest:
            // Guest is the absence of a link; nothing to restore.
            dropLinkAndFallBackToGuest()
        }
    }

    // MARK: - Unlinking

    /// Detaches the provider identity from this device and returns to guest.
    ///
    /// This is *not* account deletion and *not* data deletion: there is no
    /// server account to delete, and every workout, routine, session, gym and
    /// health entry stays exactly where it was.
    func unlinkAccount() {
        if linkedAccountStore.linkedAccount?.provider == .google {
            googleSession.signOut()
        }
        dropLinkAndFallBackToGuest()
    }

    private func dropLinkAndFallBackToGuest() {
        linkedAccountStore.clear()
        state = .guest
    }
}
