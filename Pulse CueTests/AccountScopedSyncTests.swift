//
//  AccountScopedSyncTests.swift
//  Pulse CueTests
//
//  The invariants of `AccountScopedSyncStore`, in the order they would hurt.
//
//  The one these exist for is account-switch isolation: a device holding
//  guest data, account A's data and account B's data must never offer A's
//  rows to B. Everything else here — adoption, the cursor, the outbox —
//  is a way that invariant could be lost, so each is pinned on its own.
//
//  No network is involved and none is stubbed; this PR has no sync client.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct AccountScopedSyncTests {

    // MARK: - Fixture

    private static func makeContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: PulseCueSchemaV6.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @discardableResult
    private static func insertSession(
        _ context: ModelContext,
        owner: UUID?
    ) -> Session {
        let session = Session(
            routineId: UUID(),
            dayDate: Date(),
            ownerAccountID: owner
        )
        context.insert(session)
        return session
    }

    @discardableResult
    private static func insertResult(
        _ context: ModelContext,
        session: Session,
        owner: UUID?
    ) -> StepResult {
        let result = StepResult(
            sessionId: session.id,
            stepId: UUID(),
            setIndex: 0,
            done: true,
            ownerAccountID: owner
        )
        context.insert(result)
        return result
    }

    // MARK: - Account-switch isolation

    @Test("A's rows are never candidates for B, in either direction")
    func syncCandidatesAreScopedToOneAccount() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let b = UUID()

        let guestSession = Self.insertSession(context, owner: nil)
        let aSession = Self.insertSession(context, owner: a)
        let bSession = Self.insertSession(context, owner: b)
        Self.insertResult(context, session: guestSession, owner: nil)
        Self.insertResult(context, session: aSession, owner: a)
        Self.insertResult(context, session: bSession, owner: b)
        try context.save()

        let store = AccountScopedSyncStore()

        let aSessions = try store.syncCandidateSessions(for: a, in: context)
        #expect(aSessions.map(\.id) == [aSession.id])
        let bSessions = try store.syncCandidateSessions(for: b, in: context)
        #expect(bSessions.map(\.id) == [bSession.id])

        // The guest row belongs to neither until somebody adopts it.
        #expect(try store.guestSessions(in: context).map(\.id) == [guestSession.id])

        let aResults = try store.syncCandidateStepResults(for: a, in: context)
        #expect(aResults.allSatisfy { $0.ownerAccountID == a })
        #expect(aResults.count == 1)
    }

    @Test("Adopting as B leaves A's rows with A and takes only the guest rows")
    func adoptionAfterAccountSwitchTakesOnlyGuestRows() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let b = UUID()

        let guestSession = Self.insertSession(context, owner: nil)
        let aSession = Self.insertSession(context, owner: a)
        try context.save()

        let store = AccountScopedSyncStore()
        let summary = try store.adoptGuestWorkoutData(for: b, in: context)

        #expect(summary.adoptedSessions == 1)
        #expect(guestSession.ownerAccountID == b)
        #expect(aSession.ownerAccountID == a)
        #expect(try store.syncCandidateSessions(for: a, in: context).map(\.id) == [aSession.id])
        #expect(try store.syncCandidateSessions(for: b, in: context).map(\.id) == [guestSession.id])
    }

    // MARK: - Guest adoption

    @Test("A guest session and its guest results are adopted together")
    func adoptionKeepsSessionAndResultsConsistent() throws {
        let context = try Self.makeContext()
        let a = UUID()

        let session = Self.insertSession(context, owner: nil)
        let first = Self.insertResult(context, session: session, owner: nil)
        let second = Self.insertResult(context, session: session, owner: nil)
        try context.save()

        let summary = try AccountScopedSyncStore().adoptGuestWorkoutData(for: a, in: context)

        #expect(summary == .init(adoptedSessions: 1, adoptedStepResults: 2))
        #expect(session.ownerAccountID == a)
        #expect(first.ownerAccountID == a)
        #expect(second.ownerAccountID == a)
    }

    @Test("A guest result whose session belongs to somebody else stays unowned")
    func adoptionDoesNotClaimAnOrphanResultIntoAnotherAccountsSession() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let b = UUID()

        let bSession = Self.insertSession(context, owner: b)
        let orphan = Self.insertResult(context, session: bSession, owner: nil)
        try context.save()

        try AccountScopedSyncStore().adoptGuestWorkoutData(for: a, in: context)

        // Uploading it as A's would mean a step result pointing at a session
        // A does not have — which the server's composite foreign key refuses.
        #expect(orphan.ownerAccountID == nil)
        #expect(bSession.ownerAccountID == b)
    }

    @Test("Adopting twice changes nothing and queues nothing new")
    func adoptionIsIdempotent() throws {
        let context = try Self.makeContext()
        let a = UUID()

        let session = Self.insertSession(context, owner: nil)
        Self.insertResult(context, session: session, owner: nil)
        try context.save()

        let store = AccountScopedSyncStore()
        let first = try store.adoptGuestWorkoutData(for: a, in: context)
        let outboxAfterFirst = try store.outboxItems(for: a, in: context).count
        let second = try store.adoptGuestWorkoutData(for: a, in: context)

        #expect(first == .init(adoptedSessions: 1, adoptedStepResults: 1))
        #expect(second == .nothing)
        #expect(try store.outboxItems(for: a, in: context).count == outboxAfterFirst)
        #expect(outboxAfterFirst == 2)
    }

    @Test("A row already owned by B is not adopted by A")
    func adoptionNeverReassignsAnOwnedRow() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let b = UUID()

        let bSession = Self.insertSession(context, owner: b)
        try context.save()

        let summary = try AccountScopedSyncStore().adoptGuestWorkoutData(for: a, in: context)

        #expect(summary == .nothing)
        #expect(bSession.ownerAccountID == b)
    }

    @Test("Adoption queues the adopted rows for the adopting account only")
    func adoptionQueuesOutboxEntriesForTheAdopter() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let b = UUID()

        let session = Self.insertSession(context, owner: nil)
        try context.save()

        let store = AccountScopedSyncStore()
        try store.adoptGuestWorkoutData(for: a, in: context)

        let queued = try store.outboxItems(for: a, in: context)
        #expect(queued.map(\.entityID) == [session.id])
        #expect(queued.first?.mutation == .upsert)
        #expect(queued.first?.entityType == .session)
        #expect(try store.outboxItems(for: b, in: context).isEmpty)
    }

    // MARK: - Cursor

    @Test("Advancing one account's cursor leaves every other account's alone")
    func cursorsAreScopedPerAccount() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let b = UUID()
        let store = AccountScopedSyncStore()

        try store.advanceCursor(for: a, to: 10, in: context)
        try store.advanceCursor(for: b, to: 42, in: context)
        try store.advanceCursor(for: a, to: 11, in: context)

        #expect(try store.cursor(for: a, in: context)?.lastPulledSequence == 11)
        #expect(try store.cursor(for: b, in: context)?.lastPulledSequence == 42)
    }

    @Test("A never-seen account has no cursor")
    func aNewAccountStartsWithoutACursor() throws {
        let context = try Self.makeContext()
        let store = AccountScopedSyncStore()
        try store.advanceCursor(for: UUID(), to: 7, in: context)

        #expect(try store.cursor(for: UUID(), in: context) == nil)
    }

    @Test("A cursor survives a logout and comes back for the same account")
    func cursorSurvivesLogoutAndRelogin() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let store = AccountScopedSyncStore()
        try store.advanceCursor(for: a, to: 21, in: context)

        // Logging out clears the session, never the local ownership record —
        // so signing back in as A finds A's own progress, not a reset.
        #expect(try store.cursor(for: a, in: context)?.lastPulledSequence == 21)
    }

    @Test("A cursor never moves backwards")
    func cursorIsMonotonic() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let store = AccountScopedSyncStore()

        try store.advanceCursor(for: a, to: 30, in: context)
        try store.advanceCursor(for: a, to: 5, in: context)

        #expect(try store.cursor(for: a, in: context)?.lastPulledSequence == 30)
    }

    // MARK: - Outbox

    @Test("An entry recorded for A is invisible to B and keeps its identity")
    func outboxEntriesAreScopedPerAccount() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let b = UUID()
        let entity = UUID()
        let store = AccountScopedSyncStore()

        try store.record(.upsert, .session, entity, for: a, in: context)
        try context.save()

        let aItems = try store.outboxItems(for: a, in: context)
        #expect(aItems.count == 1)
        #expect(aItems.first?.entityID == entity)
        #expect(aItems.first?.entityType == .session)
        #expect(aItems.first?.mutation == .upsert)
        #expect(try store.outboxItems(for: b, in: context).isEmpty)
    }

    @Test("Two accounts can hold an entry for the same entity id, separately")
    func theSameEntityIdIsSeparatePerAccount() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let b = UUID()
        let entity = UUID()
        let store = AccountScopedSyncStore()

        try store.record(.upsert, .session, entity, for: a, in: context)
        try store.record(.delete, .session, entity, for: b, in: context)
        try context.save()

        #expect(try store.outboxItems(for: a, in: context).first?.mutation == .upsert)
        #expect(try store.outboxItems(for: b, in: context).first?.mutation == .delete)
    }

    @Test("Recording the same mutation again is one entry, not two")
    func recordingIsIdempotentPerEntity() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let entity = UUID()
        let store = AccountScopedSyncStore()

        try store.record(.upsert, .session, entity, for: a, in: context)
        try store.record(.upsert, .session, entity, for: a, in: context)
        try store.record(.upsert, .session, entity, for: a, in: context)
        try context.save()

        #expect(try store.outboxItems(for: a, in: context).count == 1)
    }

    @Test("A delete replaces a pending upsert")
    func deleteSupersedesAPendingUpsert() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let entity = UUID()
        let store = AccountScopedSyncStore()

        try store.record(.upsert, .stepResult, entity, for: a, in: context)
        try store.record(.delete, .stepResult, entity, for: a, in: context)
        try context.save()

        let items = try store.outboxItems(for: a, in: context)
        #expect(items.count == 1)
        #expect(items.first?.mutation == .delete)
    }

    @Test("A tombstone is terminal: an upsert after a delete is refused")
    func tombstoneIsTerminal() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let entity = UUID()
        let store = AccountScopedSyncStore()

        try store.record(.delete, .session, entity, for: a, in: context)
        try context.save()

        #expect(throws: AccountScopedSyncError.tombstoneIsTerminal(.session, entity)) {
            try store.record(.upsert, .session, entity, for: a, in: context)
        }
        #expect(try store.outboxItems(for: a, in: context).first?.mutation == .delete)
    }

    @Test("Clearing a sent entry leaves the other account's queue untouched")
    func clearingAnEntryIsScoped() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let b = UUID()
        let entity = UUID()
        let store = AccountScopedSyncStore()

        try store.record(.upsert, .session, entity, for: a, in: context)
        try store.record(.upsert, .session, entity, for: b, in: context)
        try context.save()

        let sent = try #require(try store.outboxItems(for: a, in: context).first)
        store.clear(sent, in: context)
        try context.save()

        #expect(try store.outboxItems(for: a, in: context).isEmpty)
        #expect(try store.outboxItems(for: b, in: context).count == 1)
    }
}
