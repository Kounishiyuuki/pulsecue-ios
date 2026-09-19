//
//  WorkoutDataScopeTests.swift
//  Pulse CueTests
//
//  The scope policy on its own: given an account state, whose data is this.
//
//  Kept separate from the wiring tests because this is the part that is easy
//  to get subtly wrong and impossible to see going wrong — a state resolving
//  to `.guest` when it should resolve to "not known yet" does not crash, it
//  shows somebody the wrong history for a moment.
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct WorkoutDataScopeTests {

    private static func profile(id: String) -> ServerAccountProfile {
        ServerAccountProfile(
            user: .init(id: id, state: "active", displayName: nil, createdAt: 0),
            linkedProviders: [],
            session: .init(expiresAt: 0)
        )
    }

    // MARK: - matches

    @Test("Guest scope matches unowned rows and nothing else")
    func guestMatchesOnlyUnowned() {
        let a = UUID()
        #expect(WorkoutDataScope.guest.matches(ownerAccountID: nil))
        #expect(!WorkoutDataScope.guest.matches(ownerAccountID: a))
    }

    @Test("Account scope matches its own rows and nothing else")
    func accountMatchesOnlyItsOwn() {
        let a = UUID()
        let b = UUID()
        let scope = WorkoutDataScope.account(a)
        #expect(scope.matches(ownerAccountID: a))
        #expect(!scope.matches(ownerAccountID: b))
        #expect(!scope.matches(ownerAccountID: nil))
    }

    @Test("An undetermined scope matches nothing at all")
    func undeterminedMatchesNothing() {
        let scope = WorkoutDataScope.undetermined
        #expect(!scope.matches(ownerAccountID: nil))
        #expect(!scope.matches(ownerAccountID: UUID()))
        #expect(!scope.canCreateWorkouts)
        #expect(scope.syncAccountID == nil)
    }

    @Test("Guest data is never sync-eligible")
    func guestIsNotSyncEligible() {
        #expect(WorkoutDataScope.guest.syncAccountID == nil)
        #expect(WorkoutDataScope.guest.creationOwnerAccountID == nil)
        #expect(WorkoutDataScope.guest.canCreateWorkouts)
    }

    // MARK: - resolve

    @Test("No session resolves to guest")
    func guestStateResolvesToGuest() {
        #expect(WorkoutDataScope.resolve(state: .guest, lastConfirmedAccountID: nil) == .guest)
        // Even with a remembered account: an explicit sign-out is a fact, and
        // the remembered id is cleared when it happens.
        #expect(WorkoutDataScope.resolve(state: .guest, lastConfirmedAccountID: UUID()) == .guest)
    }

    @Test("A build without the account API is guest, not undetermined")
    func notConfiguredResolvesToGuest() {
        #expect(
            WorkoutDataScope.resolve(state: .notConfigured, lastConfirmedAccountID: nil) == .guest
        )
    }

    @Test("A confirmed account resolves to that account")
    func authenticatedResolvesToTheAccount() {
        let id = UUID()
        let scope = WorkoutDataScope.resolve(
            state: .authenticated(Self.profile(id: id.uuidString)),
            lastConfirmedAccountID: nil
        )
        #expect(scope == .account(id))
    }

    @Test("An account id that is not a UUID fails closed, never to guest")
    func unreadableAccountIdFailsClosed() {
        let scope = WorkoutDataScope.resolve(
            state: .authenticated(Self.profile(id: "not-a-uuid")),
            lastConfirmedAccountID: nil
        )
        // Guest here would hand an authenticated user a different data set and
        // make everything they recorded next unsyncable.
        #expect(scope == .undetermined)
        #expect(!scope.canCreateWorkouts)
    }

    @Test("A stale remembered id does not rescue an unreadable account id")
    func unreadableAccountIdIgnoresTheRememberedAccount() {
        let scope = WorkoutDataScope.resolve(
            state: .authenticated(Self.profile(id: "not-a-uuid")),
            lastConfirmedAccountID: UUID()
        )
        #expect(scope == .undetermined)
    }

    @Test("Offline with a known account stays in that account's scope")
    func unreachableUsesTheLastConfirmedAccount() {
        let id = UUID()
        #expect(
            WorkoutDataScope.resolve(state: .unreachable, lastConfirmedAccountID: id)
                == .account(id)
        )
    }

    @Test("Offline with no known account shows nothing rather than guessing")
    func unreachableWithoutAMemoryIsUndetermined() {
        #expect(
            WorkoutDataScope.resolve(state: .unreachable, lastConfirmedAccountID: nil)
                == .undetermined
        )
    }

    @Test("While confirming a session, the scope is not knowable")
    func transientStatesAreUndetermined() {
        for state in [ServerAccountState.restoring, .signingIn, .localCleanupFailed] {
            #expect(
                WorkoutDataScope.resolve(state: state, lastConfirmedAccountID: UUID())
                    == .undetermined,
                "\(state) must not resolve to a scope"
            )
        }
    }
}
