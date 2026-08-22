//
//  GoogleSDKSessionOwnership.swift
//  Pulse Cue
//
//  Which authorization flow created the Google SDK's current session.
//
//  This exists because two things that look like the same question are not:
//
//    "is a Google sign-in running right now?"   → the active permit
//    "whose Google account is the SDK on?"      → this
//
//  The permit ends when its flow ends. The SDK's session does not: `GIDSignIn`
//  keeps the selected account after the flow that selected it has finished, is
//  released, and is long forgotten. Reading `activePermit == nil` as "nobody
//  owns the Google session" is therefore wrong, and wrong in an expensive
//  direction — it was enough to make a stale flow's cleanup sign the user out
//  of an account a *newer, successful* sign-in had just established.
//
//  So ownership is tracked separately and by identity:
//
//    flow A authorizes    → A owns the SDK session
//    A goes stale, cleans up while it still owns  → sign out, owner cleared
//    flow B authorizes    → B owns it
//    B succeeds, B's permit is released           → **B still owns it**
//    A finally unwinds and tries to clean up      → not the owner, no-op
//
//  What is deliberately *not* used as the ownership key: the Google user id,
//  the email, the subject. Those identify a person; this identifies a local
//  attempt. Keying on identity would make two sign-ins of the same account
//  indistinguishable, which is exactly the case that has to be told apart.
//
//  Nothing here restores a previous Google account. The only two outcomes are
//  "sign out of the session my own flow created" and "leave it alone", which
//  is all that is needed and all that can be done safely.
//

import Foundation

@MainActor
final class GoogleSDKSessionOwnership {

    /// Shared because the SDK's session is shared.
    ///
    /// `LoginView` builds a fresh `ProviderSignInCoordinator` for every tap, so
    /// per-coordinator state would forget the owner between attempts — and
    /// forgetting is what the ABA bug was made of.
    static let shared = GoogleSDKSessionOwnership()

    private(set) var owner: ProviderSignInPermit?
    private let signOutSDK: @MainActor () -> Void

    init(
        signOutSDK: @escaping @MainActor () -> Void = {
            GoogleSessionManager.shared.signOut()
        }
    ) {
        self.signOutSDK = signOutSDK
    }

    /// Records that this flow's authorization created the SDK's current session.
    ///
    /// Called as soon as `GIDSignIn` reports success — deliberately *not* after
    /// the backend exchange. By the time the callback returns, the device has
    /// already switched accounts; waiting for the server would leave a window
    /// where the SDK has an owner-less session that no cleanup can attribute.
    func claim(_ permit: ProviderSignInPermit) {
        owner = permit
    }

    /// Signs out of the SDK, but only on behalf of the flow that owns it.
    ///
    /// The guard is the whole point. A late-unwinding stale flow calling an
    /// unconditional `signOut()` would take down whatever session is current,
    /// including one a newer flow legitimately established.
    func signOutIfOwned(by permit: ProviderSignInPermit) {
        guard owner == permit else { return }
        owner = nil
        signOutSDK()
    }

    /// Ends the Google SDK's session whoever established it, and whether or
    /// not this process knows who that was.
    ///
    /// The owner record is in memory only, and it has to be: it identifies a
    /// *local attempt*, and attempts do not survive a relaunch. The SDK's
    /// session does. So after a restart the app can be signed into Google with
    /// `owner == nil`, and a cleanup conditional on having an owner would
    /// quietly do nothing in exactly the case that matters most —
    ///
    ///   launch → Google session restored by the SDK, owner nil
    ///   delete my PulseCue account → server says it is gone
    ///   ...and the device stays signed into the Google account behind it.
    ///
    /// For deliberate, destructive account actions there is no version of
    /// "leave it alone" that is right, so this does not ask who owns it.
    func signOutCurrentSession() {
        owner = nil
        signOutSDK()
    }
}
