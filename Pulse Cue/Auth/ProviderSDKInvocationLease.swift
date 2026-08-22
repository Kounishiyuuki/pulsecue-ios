//
//  ProviderSDKInvocationLease.swift
//  Pulse Cue
//
//  A provider SDK call that has been started and has not come back yet.
//
//  This is the third and last thing in this layer that looks like the other
//  two and is not:
//
//    ProviderSignInPermit      — may this flow act on the account?
//    GoogleSDKSessionOwnership — whose account is the SDK signed into?
//    this                      — is an SDK call still outstanding?
//
//  The permit can be revoked at any moment: a logout retires it immediately,
//  because PulseCue decides who owns the account. An outstanding SDK call
//  cannot be revoked like that. `GIDSignIn.signIn` has been handed to Google,
//  the sheet is up, and the callback will arrive when it arrives — retiring
//  the permit does nothing to the call itself.
//
//  Conflating those two allowed the callbacks to arrive out of order:
//
//      A starts GIDSignIn.signIn      (still pending)
//      logout retires permit A
//      B starts GIDSignIn.signIn      ← allowed, because A had no permit
//      B completes, signs in, done
//      A's callback finally returns   ← now mutates the SDK behind B
//
//  By then A's completion has already moved the SDK's own state onto A's
//  account, before any check PulseCue could run — so no amount of "is A
//  stale?" testing afterwards can prevent it. The only fix is to not let B
//  start while A is outstanding, which is what this enforces.
//
//  Leases are per provider. Apple's flow has no persistent client-side
//  session and no need of this, and blocking it behind Google's would be an
//  unrelated regression.
//

import Foundation

@MainActor
final class ProviderSDKInvocationLease {

    /// Shared because the SDKs are process-wide singletons.
    ///
    /// `LoginView` builds a coordinator per tap, so a per-coordinator lease
    /// would not see the outstanding call it exists to wait for.
    static let shared = ProviderSDKInvocationLease()

    /// Proof that this flow holds the lease for one provider.
    ///
    /// Identity-bearing so a late release cannot free a lease somebody else
    /// has since taken — the same hazard the permit's `id` guards against.
    struct Ticket: Equatable {
        fileprivate let id: UInt64
        let provider: AuthProviderKind
    }

    private var holders: [AuthProviderKind: Ticket] = [:]
    private var nextID: UInt64 = 0

    /// Takes the lease, or returns nil if this provider's SDK is mid-call.
    func acquire(_ provider: AuthProviderKind) -> Ticket? {
        guard holders[provider] == nil else { return nil }
        nextID &+= 1
        let ticket = Ticket(id: nextID, provider: provider)
        holders[provider] = ticket
        return ticket
    }

    /// Releases the lease, only for its actual holder.
    ///
    /// Idempotent on purpose: the flow releases explicitly once its callback
    /// has been dealt with, and a `defer` releases again on every abnormal
    /// exit. The second call must not free a lease a later flow now holds.
    func release(_ ticket: Ticket) {
        guard holders[ticket.provider] == ticket else { return }
        holders[ticket.provider] = nil
    }

    /// Whether an SDK call for this provider is still outstanding.
    func isBusy(_ provider: AuthProviderKind) -> Bool {
        holders[provider] != nil
    }
}
