//
//  SyncTombstoneMigrationTests.swift
//  Pulse CueTests
//
//  Real on-disk V6 → V7 migration proof for the `SyncTombstone` entity.
//
//  The seed store is built with the V6 schema ONLY (no plan), so it is
//  genuinely stamped V6 and has no tombstone table at all — which is what
//  makes this a real additive-entity migration rather than a false positive.
//
//  What is checked beyond "it opened": the workout data and the ownership
//  added at V6 come through unchanged, and the store is *usable* afterwards —
//  a tombstone written post-migration survives closing and reopening. A
//  terminal state that only lasts as long as the process is not terminal.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct SyncTombstoneMigrationTests {

    private static func withTempStore(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsecue-v7migtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.appendingPathComponent("store.sqlite"))
    }

    /// Opens the store with the V6 schema ONLY (no plan) so it is stamped V6
    /// and holds no tombstone entity. Released on return.
    private static func seedV6Store(at url: URL, _ work: (ModelContext) throws -> Void) throws {
        let schema = Schema(versionedSchema: PulseCueSchemaV6.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, url: url)
        )
        let context = ModelContext(container)
        try work(context)
        try context.save()
    }

    /// Opens the same store with V7 + the migration plan, running V6 → V7.
    private static func openV7Store(at url: URL, _ work: (ModelContext) throws -> Void) throws {
        let schema = Schema(versionedSchema: PulseCueSchemaV7.self)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: PulseCueMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: url)
        )
        let context = ModelContext(container)
        try work(context)
        try context.save()
    }

    @Test("V6 → V7 preserves workouts and their ownership")
    func migrationPreservesOwnedAndGuestWorkouts() throws {
        let owner = UUID()
        let ownedID = UUID()
        let guestID = UUID()

        try Self.withTempStore { url in
            try Self.seedV6Store(at: url) { context in
                context.insert(
                    Session(
                        id: ownedID,
                        routineId: UUID(),
                        dayDate: Date(),
                        status: .completed,
                        totalSeconds: 900,
                        ownerAccountID: owner
                    )
                )
                context.insert(
                    Session(id: guestID, routineId: UUID(), dayDate: Date(), status: .completed)
                )
            }

            try Self.openV7Store(at: url) { context in
                let sessions = try context.fetch(FetchDescriptor<Session>())
                #expect(sessions.count == 2)
                #expect(sessions.first { $0.id == ownedID }?.ownerAccountID == owner)
                #expect(sessions.first { $0.id == ownedID }?.totalSeconds == 900)
                #expect(sessions.first { $0.id == guestID }?.ownerAccountID == nil)
                // Nothing has been uploaded yet, so nothing has been deleted
                // server-side to remember.
                #expect(try context.fetchCount(FetchDescriptor<SyncTombstone>()) == 0)
            }
        }
    }

    @Test("A tombstone written after the migration survives a reopen")
    func tombstonesAreDurableAcrossStoreLifetimes() throws {
        let account = UUID()
        let entity = UUID()

        try Self.withTempStore { url in
            try Self.seedV6Store(at: url) { _ in }

            try Self.openV7Store(at: url) { context in
                try AccountScopedSyncStore()
                    .confirmDeletion(.session, entity, for: account, in: context)
            }

            // A separate container over the same file: the terminal state has
            // to be on disk, not in a process.
            try Self.openV7Store(at: url) { context in
                let store = AccountScopedSyncStore()
                let stillTombstoned = try store.isTombstoned(
                    .session, entity, for: account, in: context
                )
                #expect(stillTombstoned)

                let revived = Session(
                    id: entity,
                    routineId: UUID(),
                    dayDate: Date(),
                    ownerAccountID: account
                )
                context.insert(revived)
                #expect(throws: AccountScopedSyncError.tombstoneIsTerminal(.session, entity)) {
                    try store.recordSessionMutation(.upsert, revived, for: account, in: context)
                }
            }
        }
    }
}
