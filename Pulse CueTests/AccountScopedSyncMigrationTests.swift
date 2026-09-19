//
//  AccountScopedSyncMigrationTests.swift
//  Pulse CueTests
//
//  Real on-disk V5 → V6 migration proof for `Session.ownerAccountID` and
//  `StepResult.ownerAccountID`.
//
//  The seed store is built with the V5 schema ONLY (no plan), so it is
//  genuinely stamped V5 and its `Session` / `StepResult` entities are the
//  version-specific legacy `PulseCueSchemaV1.Session` /
//  `PulseCueSchemaV1.StepResult`, which have NO owner column. That is what
//  makes this a real additive-column migration rather than a false positive.
//
//  The assertion that matters is not "it opened". It is that a workout
//  recorded before this version comes through as **guest** — owner nil —
//  rather than as the property of whoever happens to be signed in. An upgrade
//  that quietly stamped existing history with an account id would be the exact
//  failure this whole foundation exists to prevent, and it would be invisible
//  until somebody's training showed up in somebody else's account.
//
//  Guardrails mirror StepExerciseIdMigrationTests:
//    - seed with V5 schema only → real V5 stamp, column-less entities,
//    - release the V5 container before opening V6 at the same URL,
//    - reuse the same store URL,
//    - V6 open goes through PulseCueMigrationPlan (runs V5→V6),
//    - assertions check preserved data + owner == nil, never "opened empty".
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct AccountScopedSyncMigrationTests {

    private static func withTempStore(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsecue-v6migtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.appendingPathComponent("store.sqlite"))
    }

    /// Opens the store with the V5 schema ONLY (no plan), so it is stamped V5
    /// and its Session/StepResult entities are the owner-less legacy shape.
    /// Released on return.
    private static func seedV5Store(at url: URL, _ work: (ModelContext) throws -> Void) throws {
        let schema = Schema(versionedSchema: PulseCueSchemaV5.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, url: url)
        )
        let context = ModelContext(container)
        try work(context)
        try context.save()
    }

    /// Opens the same store with V6 + the migration plan, running V5 → V6.
    private static func openV6Store(at url: URL, _ work: (ModelContext) throws -> Void) throws {
        let schema = Schema(versionedSchema: PulseCueSchemaV6.self)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: PulseCueMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: url)
        )
        let context = ModelContext(container)
        try work(context)
        try context.save()
    }

    @Test("V5 → V6 keeps every pre-existing workout and leaves it unowned")
    func migrationPreservesHistoryAsGuestData() throws {
        let sessionID = UUID()
        let resultID = UUID()
        let routineID = UUID()
        let started = Date(timeIntervalSince1970: 1_700_000_000)

        try Self.withTempStore { url in
            try Self.seedV5Store(at: url) { context in
                let session = PulseCueSchemaV1.Session(
                    id: sessionID,
                    routineId: routineID,
                    dayDate: started,
                    startedAt: started,
                    status: .completed,
                    totalSeconds: 1234
                )
                context.insert(session)
                context.insert(
                    PulseCueSchemaV1.StepResult(
                        id: resultID,
                        sessionId: sessionID,
                        stepId: UUID(),
                        setIndex: 2,
                        done: true,
                        actualReps: 8,
                        memo: "before the upgrade"
                    )
                )
            }

            try Self.openV6Store(at: url) { context in
                let sessions = try context.fetch(FetchDescriptor<Session>())
                let migrated = try #require(sessions.first { $0.id == sessionID })
                #expect(sessions.count == 1)
                #expect(migrated.routineId == routineID)
                #expect(migrated.totalSeconds == 1234)
                #expect(migrated.status == .completed)
                // The point of the test.
                #expect(migrated.ownerAccountID == nil)

                let results = try context.fetch(FetchDescriptor<StepResult>())
                let result = try #require(results.first { $0.id == resultID })
                #expect(results.count == 1)
                #expect(result.sessionId == sessionID)
                #expect(result.actualReps == 8)
                #expect(result.memo == "before the upgrade")
                #expect(result.ownerAccountID == nil)
            }
        }
    }

    @Test("Migrated history is adoptable, and adoption is what assigns it")
    func migratedHistoryBecomesOwnedOnlyThroughAdoption() throws {
        let account = UUID()
        let sessionID = UUID()

        try Self.withTempStore { url in
            try Self.seedV5Store(at: url) { context in
                context.insert(
                    PulseCueSchemaV1.Session(
                        id: sessionID,
                        routineId: UUID(),
                        dayDate: Date(),
                        status: .completed
                    )
                )
            }

            try Self.openV6Store(at: url) { context in
                let store = AccountScopedSyncStore()
                // Nothing is a sync candidate for anyone until it is adopted.
                #expect(try store.syncCandidateSessions(for: account, in: context).isEmpty)

                try store.adoptGuestWorkoutData(for: account, in: context)

                #expect(
                    try store.syncCandidateSessions(for: account, in: context).map(\.id)
                        == [sessionID]
                )
            }
        }
    }

    @Test("The new sync entities are usable on a store migrated from V5")
    func migratedStoreCarriesCursorAndOutbox() throws {
        let account = UUID()

        try Self.withTempStore { url in
            try Self.seedV5Store(at: url) { _ in }

            try Self.openV6Store(at: url) { context in
                let store = AccountScopedSyncStore()
                let session = Session(
                    routineId: UUID(),
                    dayDate: Date(),
                    ownerAccountID: account
                )
                context.insert(session)
                try store.advanceCursor(for: account, to: 9, in: context)
                try store.recordSessionMutation(.upsert, session, for: account, in: context)
                try context.save()

                #expect(try store.cursor(for: account, in: context)?.lastPulledSequence == 9)
                #expect(try store.outboxItems(for: account, in: context).count == 1)
            }
        }
    }
}
