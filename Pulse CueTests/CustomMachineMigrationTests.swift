//
//  CustomMachineMigrationTests.swift
//  Pulse CueTests
//
//  The project's first *real on-disk* SwiftData migration tests. Every
//  case here creates an actual V2 store file, inserts realistic V2 data,
//  fully releases that container, then reopens the same file with the V3
//  schema + `PulseCueMigrationPlan` so the V2 -> V3 lightweight stage runs
//  for real. In-memory stores are deliberately NOT used for the migration
//  path (they never exercise the on-disk version stamp / migration).
//
//  Guardrails against the classic false-positive migration test:
//    - the seed store is built with the V2 schema ONLY (no plan), so it is
//      genuinely stamped V2, not V3;
//    - the V2 container is released before the V3 container opens the same
//      URL (separate helper functions, ARC drops the locals on return);
//    - the same `storeURL` is reused for both opens;
//    - the V3 open goes through `PulseCueMigrationPlan`;
//    - assertions check preserved *data*, not just "V3 opened empty".
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct CustomMachineMigrationTests {

    // MARK: - On-disk store helpers

    /// Creates a unique temp directory, hands its store URL to `body`, and
    /// removes the whole directory afterward (including on failure).
    private static func withTempStore(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsecue-migtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.appendingPathComponent("store.sqlite"))
    }

    /// Opens the store at `url` using ONLY the V2 schema (no migration
    /// plan) so it is stamped as a real V2 store, runs `work`, saves, and
    /// releases the container/context before returning.
    private static func seedV2Store(at url: URL, _ work: (ModelContext) throws -> Void) throws {
        let config = ModelConfiguration(
            schema: Schema(versionedSchema: PulseCueSchemaV2.self),
            url: url
        )
        let container = try ModelContainer(
            for: Schema(versionedSchema: PulseCueSchemaV2.self),
            configurations: config
        )
        let context = ModelContext(container)
        try work(context)
        try context.save()
        // `container` and `context` are released when this function returns.
    }

    /// Opens the same store at `url` with the V3 schema + migration plan,
    /// running the V2 -> V3 lightweight stage, then runs `work` and saves.
    private static func openV3Store(at url: URL, _ work: (ModelContext) throws -> Void) throws {
        let config = ModelConfiguration(
            schema: Schema(versionedSchema: PulseCueSchemaV3.self),
            url: url
        )
        let container = try ModelContainer(
            for: Schema(versionedSchema: PulseCueSchemaV3.self),
            migrationPlan: PulseCueMigrationPlan.self,
            configurations: config
        )
        let context = ModelContext(container)
        try work(context)
        try context.save()
    }

    // MARK: - Fixed fixture values (so we can assert exact preservation)

    private static let gymId = UUID()
    private static let machineId = UUID()
    private static let routineId = UUID()
    private static let stepId = UUID()
    private static let sessionId = UUID()
    private static let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    private static let addedAt = Date(timeIntervalSince1970: 1_700_000_500)

    /// Inserts one gym + one standard machine + a routine/step/session/
    /// result graph into a V2 context.
    private static func seedRealisticV2(_ context: ModelContext) throws {
        let gym = Gym(
            id: gymId,
            name: "テストジム",
            officialUrl: "https://example.com",
            isActive: true,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        context.insert(gym)
        context.insert(GymMachine(
            id: machineId,
            gymId: gymId,
            machineId: "lat_pulldown",
            displayName: "ラットプルダウン",
            isAvailable: true,
            addedAt: addedAt
        ))
        let routine = Routine(id: routineId, name: "背中の日")
        context.insert(routine)
        context.insert(Step(
            id: stepId,
            routineId: routineId,
            order: 0,
            title: "ラットプルダウン",
            sets: 3,
            repsTarget: 10,
            restSeconds: 90
        ))
        let session = Session(id: sessionId, routineId: routineId, dayDate: createdAt)
        context.insert(session)
        context.insert(StepResult(
            sessionId: sessionId,
            stepId: stepId,
            setIndex: 0,
            done: true,
            actualReps: 10
        ))
    }

    // MARK: - Migration opens and preserves existing data

    @Test
    func v2StoreMigratesToV3AndPreservesGymAndMachine() throws {
        try Self.withTempStore { url in
            try Self.seedV2Store(at: url) { try Self.seedRealisticV2($0) }

            try Self.openV3Store(at: url) { context in
                let gyms = try context.fetch(FetchDescriptor<Gym>())
                #expect(gyms.count == 1)
                let gym = try #require(gyms.first)
                #expect(gym.id == Self.gymId)
                #expect(gym.name == "テストジム")
                #expect(gym.officialUrl == "https://example.com")
                #expect(gym.isActive == true)
                #expect(abs(gym.createdAt.timeIntervalSince(Self.createdAt)) < 0.001)

                let machines = try context.fetch(FetchDescriptor<GymMachine>())
                #expect(machines.count == 1)
                let machine = try #require(machines.first)
                #expect(machine.id == Self.machineId)
                #expect(machine.gymId == Self.gymId)
                #expect(machine.machineId == "lat_pulldown")
                #expect(machine.displayName == "ラットプルダウン")
                #expect(machine.isAvailable == true)
                #expect(abs(machine.addedAt.timeIntervalSince(Self.addedAt)) < 0.001)
            }
        }
    }

    @Test
    func migrationKeepsRoutineStepSessionResultQueryable() throws {
        try Self.withTempStore { url in
            try Self.seedV2Store(at: url) { try Self.seedRealisticV2($0) }
            try Self.openV3Store(at: url) { context in
                let routines = try context.fetch(FetchDescriptor<Routine>())
                let steps = try context.fetch(FetchDescriptor<Step>())
                let sessions = try context.fetch(FetchDescriptor<Session>())
                let results = try context.fetch(FetchDescriptor<StepResult>())
                #expect(routines.count == 1)
                #expect(steps.count == 1)
                #expect(sessions.count == 1)
                #expect(results.count == 1)
                #expect(results.first?.stepId == Self.stepId)
            }
        }
    }

    @Test
    func migrationDoesNotDuplicateRowsEvenWhenReopenedTwice() throws {
        try Self.withTempStore { url in
            try Self.seedV2Store(at: url) { try Self.seedRealisticV2($0) }
            // First V3 open performs the migration.
            try Self.openV3Store(at: url) { context in
                let gyms = try context.fetch(FetchDescriptor<Gym>())
                let machines = try context.fetch(FetchDescriptor<GymMachine>())
                #expect(gyms.count == 1)
                #expect(machines.count == 1)
            }
            // Reopening the already-migrated store must not duplicate rows.
            try Self.openV3Store(at: url) { context in
                let gyms = try context.fetch(FetchDescriptor<Gym>())
                let machines = try context.fetch(FetchDescriptor<GymMachine>())
                let customs = try context.fetch(FetchDescriptor<CustomMachine>())
                #expect(gyms.count == 1)
                #expect(machines.count == 1)
                // And no custom rows were fabricated by the migration.
                #expect(customs.isEmpty)
            }
        }
    }

    // MARK: - CustomMachine works after migration

    @Test
    func customMachineRoundTripsAcrossReopenAfterMigration() throws {
        try Self.withTempStore { url in
            try Self.seedV2Store(at: url) { try Self.seedRealisticV2($0) }

            var savedId: UUID?
            try Self.openV3Store(at: url) { context in
                let repo = GymRepository(modelContext: context)
                let gym = try #require(try context.fetch(FetchDescriptor<Gym>()).first)
                let created = try repo.addCustomMachine(
                    to: gym,
                    displayName: "自作プレスマシン",
                    bodyParts: [.chest, .arms],
                    equipmentType: .machine,
                    notes: "コーナーの黒いやつ"
                )
                savedId = created.id
            }

            // Reopen a third time; the custom row must persist fully.
            try Self.openV3Store(at: url) { context in
                let customs = try context.fetch(FetchDescriptor<CustomMachine>())
                #expect(customs.count == 1)
                let custom = try #require(customs.first)
                #expect(custom.id == savedId)
                #expect(custom.displayName == "自作プレスマシン")
                #expect(custom.bodyParts == ["chest", "arms"])
                #expect(custom.resolvedBodyParts == [.chest, .arms])
                #expect(custom.equipmentType == "machine")
                #expect(custom.resolvedEquipmentType == .machine)
                #expect(custom.notes == "コーナーの黒いやつ")
                #expect(custom.isAvailable == true)
            }
        }
    }

    @Test
    func bodyPartsPersistDeterministicallyAndTolerateUnknownRawValues() throws {
        try Self.withTempStore { url in
            try Self.seedV2Store(at: url) { try Self.seedRealisticV2($0) }

            // Construct the model directly (bypassing the repository) to force
            // a persisted unknown raw value and a non-normalized order, then
            // prove the read path tolerates it.
            try Self.openV3Store(at: url) { context in
                let custom = CustomMachine(
                    gymId: Self.gymId,
                    displayName: "壊れた部位データ",
                    bodyParts: ["chest", "not_a_real_part", "back"]
                )
                context.insert(custom)
            }

            try Self.openV3Store(at: url) { context in
                let custom = try #require(try context.fetch(FetchDescriptor<CustomMachine>()).first)
                // Raw array is stored verbatim, including the unknown value.
                #expect(custom.bodyParts == ["chest", "not_a_real_part", "back"])
                // Typed conversion silently drops the unknown value, no crash.
                #expect(custom.resolvedBodyParts == [.chest, .back])
            }
        }
    }

    @Test
    func optionalFieldsPersistAsNilAfterMigration() throws {
        try Self.withTempStore { url in
            try Self.seedV2Store(at: url) { try Self.seedRealisticV2($0) }

            try Self.openV3Store(at: url) { context in
                let repo = GymRepository(modelContext: context)
                let gym = try #require(try context.fetch(FetchDescriptor<Gym>()).first)
                _ = try repo.addCustomMachine(
                    to: gym,
                    displayName: "最小マシン",
                    bodyParts: [.core]
                )
            }

            try Self.openV3Store(at: url) { context in
                let custom = try #require(try context.fetch(FetchDescriptor<CustomMachine>()).first)
                #expect(custom.notes == nil)
                #expect(custom.equipmentType == nil)
                #expect(custom.resolvedEquipmentType == nil)
                #expect(custom.bodyParts == ["core"])
            }
        }
    }

    // MARK: - Identity

    @Test
    func customIdentityIsStableAndDistinctAcrossReopen() throws {
        try Self.withTempStore { url in
            try Self.seedV2Store(at: url) { try Self.seedRealisticV2($0) }

            var firstId: UUID?
            var firstRef: String?
            try Self.openV3Store(at: url) { context in
                let repo = GymRepository(modelContext: context)
                let gym = try #require(try context.fetch(FetchDescriptor<Gym>()).first)
                let a = try repo.addCustomMachine(to: gym, displayName: "A", bodyParts: [.chest])
                let b = try repo.addCustomMachine(to: gym, displayName: "B", bodyParts: [.back])
                #expect(a.id != b.id)
                firstId = a.id
                firstRef = a.referenceId
                // Derived id is prefixed + lowercased and cannot collide with a
                // bundled snake_case catalog id.
                #expect(a.referenceId.hasPrefix("custom_"))
                #expect(!MachineCatalog.all.map(\.id).contains(a.referenceId))
            }

            try Self.openV3Store(at: url) { context in
                let repo = GymRepository(modelContext: context)
                let target = try #require(try context.fetch(
                    FetchDescriptor<CustomMachine>()
                ).first { $0.displayName == "A" })
                #expect(target.id == firstId)
                #expect(target.referenceId == firstRef)
                // Editing does not change identity.
                try repo.updateCustomMachine(target, displayName: "A2")
                #expect(target.id == firstId)
                #expect(target.referenceId == firstRef)
            }
        }
    }
}
