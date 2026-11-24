//
//  StepExerciseIdMigrationTests.swift
//  Pulse CueTests
//
//  Real on-disk V3 → V4 migration proof for `Step.exerciseId: String?`.
//
//  The seed store is built with the V3 schema ONLY (no plan), so it is
//  genuinely stamped V3 and — crucially — its `Step` entity is the
//  version-specific legacy `PulseCueSchemaV1.Step`, which has NO
//  `exerciseId` column. That is what makes this a real additive-column
//  migration test rather than a false positive: the column truly does not
//  exist in the seed store, and V4 must add it as nil.
//
//  Guardrails (mirroring CustomMachineMigrationTests):
//    - seed with V3 schema only → real V3 stamp, legacy column-less Step,
//    - release the V3 container before opening V4 at the same URL,
//    - reuse the same store URL,
//    - V4 open goes through PulseCueMigrationPlan (runs V3→V4),
//    - assertions check preserved data + exerciseId == nil, never "opened
//      empty".
//

import CoreData
import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct StepExerciseIdMigrationTests {

    // MARK: - On-disk store helpers

    private static func withTempStore(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsecue-v4migtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.appendingPathComponent("store.sqlite"))
    }

    /// Opens the store with the V3 schema ONLY (no plan) so it is stamped V3
    /// and its Step entity is the legacy, column-less shape. Released on
    /// return.
    private static func seedV3Store(at url: URL, _ work: (ModelContext) throws -> Void) throws {
        let config = ModelConfiguration(
            schema: Schema(versionedSchema: PulseCueSchemaV3.self),
            url: url
        )
        let container = try ModelContainer(
            for: Schema(versionedSchema: PulseCueSchemaV3.self),
            configurations: config
        )
        let context = ModelContext(container)
        try work(context)
        try context.save()
    }

    private static func seedV1Store(at url: URL, _ work: (ModelContext) throws -> Void) throws {
        let schema = Schema(versionedSchema: PulseCueSchemaV1.self)
        let config = ModelConfiguration(schema: schema, url: url)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)
        try work(context)
        try context.save()
    }

    private static func openV2Store(at url: URL, _ work: (ModelContext) throws -> Void) throws {
        let schema = Schema(versionedSchema: PulseCueSchemaV2.self)
        let config = ModelConfiguration(schema: schema, url: url)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: PulseCueMigrationPlan.self,
            configurations: config
        )
        let context = ModelContext(container)
        try work(context)
        try context.save()
    }

    /// Opens the same store with the V4 schema + migration plan (runs the
    /// V3 → V4 lightweight stage).
    private static func openV4Store(at url: URL, _ work: (ModelContext) throws -> Void) throws {
        let config = ModelConfiguration(
            schema: Schema(versionedSchema: PulseCueSchemaV16.self),
            url: url
        )
        let container = try ModelContainer(
            for: Schema(versionedSchema: PulseCueSchemaV16.self),
            migrationPlan: PulseCueMigrationPlan.self,
            configurations: config
        )
        let context = ModelContext(container)
        try work(context)
        try context.save()
    }

    /// Opens the store with the V4 schema ONLY (no plan) so it is genuinely
    /// stamped V4 — whose `Routine` entity is the origin-less
    /// `PulseCueSchemaV1.Routine`. This is the real pre-V5 on-disk shape.
    private static func seedV4Store(at url: URL, _ work: (ModelContext) throws -> Void) throws {
        let schema = Schema(versionedSchema: PulseCueSchemaV4.self)
        let config = ModelConfiguration(schema: schema, url: url)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)
        try work(context)
        try context.save()
    }

    // MARK: - V4 → V5 origin migration (release blocker regression guard)

    @Test
    func v4RoutinesReadAsUserSavedAfterMigrationToV5() throws {
        try Self.withTempStore { url in
            // Genuine V4-stamped store with an origin-less routine + history.
            try Self.seedV4Store(at: url) { context in
                context.insert(Gym(
                    id: Self.gymId, name: "テストジム", officialUrl: "https://example.com",
                    isActive: true, createdAt: Self.createdAt, updatedAt: Self.updatedAt
                ))
                context.insert(PulseCueSchemaV1.Routine(
                    id: Self.routineId, name: "胸の日",
                    createdAt: Self.createdAt, updatedAt: Self.updatedAt, isPinned: true
                ))
                context.insert(PulseCueSchemaV1.Session(
                    id: Self.sessionId, routineId: Self.routineId, dayDate: Self.createdAt,
                    startedAt: Self.updatedAt, endedAt: Self.endedAt,
                    status: .completed, totalSeconds: 800
                ))
                context.insert(PulseCueSchemaV1.StepResult(
                    id: Self.resultId, sessionId: Self.sessionId, stepId: Self.step0Id,
                    setIndex: 0, done: true, actualReps: 10, memo: "完了"
                ))
            }
            // Open with V5 + full plan → runs the V4 → V5 lightweight stage.
            try Self.openV4Store(at: url) { context in
                let routines = try context.fetch(FetchDescriptor<Routine>())
                #expect(routines.count == 1)
                let routine = try #require(routines.first)
                #expect(routine.id == Self.routineId)
                #expect(routine.name == "胸の日")
                #expect(routine.isPinned)
                #expect(routine.storedOrigin == nil)    // legacy row: no value
                #expect(routine.origin == .userSaved)   // nil reads as library
                // …so it still shows up in the library list, which filters the
                // same way WorkoutView / RoutinePickerSheet do.
                #expect(routines.filter { $0.origin == .userSaved }.count == 1)
                // History / Session survive the migration intact.
                let sessions = try context.fetch(FetchDescriptor<Session>())
                #expect(sessions.count == 1)
                #expect(sessions.first?.routineId == Self.routineId)
                let results = try context.fetch(FetchDescriptor<StepResult>())
                #expect(results.count == 1)
                #expect(results.first?.sessionId == Self.sessionId)
            }
            // Reopen the migrated store: still one userSaved routine, no
            // re-crash. Writing an explicit origin must persist (the setter
            // fills the previously-nil column).
            try Self.openV4Store(at: url) { context in
                let routines = try context.fetch(FetchDescriptor<Routine>())
                #expect(routines.count == 1)
                #expect(routines.first?.origin == .userSaved)
                routines.first?.origin = .workoutGenerated
            }
            try Self.openV4Store(at: url) { context in
                let routine = try #require(try context.fetch(FetchDescriptor<Routine>()).first)
                #expect(routine.storedOrigin == .workoutGenerated)
                #expect(routine.origin == .workoutGenerated)
            }
        }
    }

    // MARK: - Fixed fixture values

    private static let gymId = UUID(uuidString: "51000000-0000-0000-0000-000000000001")!
    private static let machineId = UUID(uuidString: "61000000-0000-0000-0000-000000000001")!
    private static let customMachineId = UUID(uuidString: "71000000-0000-0000-0000-000000000001")!
    private static let routineId = UUID(uuidString: "11000000-0000-0000-0000-000000000001")!
    private static let step0Id = UUID(uuidString: "21000000-0000-0000-0000-000000000001")!
    private static let step1Id = UUID(uuidString: "21000000-0000-0000-0000-000000000002")!
    private static let sessionId = UUID(uuidString: "31000000-0000-0000-0000-000000000001")!
    private static let resultId = UUID(uuidString: "41000000-0000-0000-0000-000000000001")!
    private static let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    private static let updatedAt = Date(timeIntervalSince1970: 1_700_000_100)
    private static let addedAt = Date(timeIntervalSince1970: 1_700_000_500)
    private static let endedAt = Date(timeIntervalSince1970: 1_700_000_900)

    /// Seeds a realistic V3 graph using the LEGACY column-less Step.
    private static func seedRealisticV3(_ context: ModelContext) throws {
        let gym = Gym(
            id: gymId, name: "テストジム", officialUrl: "https://example.com",
            isActive: true, createdAt: createdAt, updatedAt: updatedAt
        )
        context.insert(gym)
        context.insert(GymMachine(
            id: machineId, gymId: gymId, machineId: "chest_press",
            displayName: "チェストプレス", isAvailable: true, addedAt: addedAt
        ))
        context.insert(PulseCueSchemaV1.Routine(
            id: routineId,
            name: "胸の日",
            createdAt: createdAt,
            updatedAt: updatedAt,
            isPinned: true
        ))
        // Legacy Step: no exerciseId column exists at all.
        context.insert(PulseCueSchemaV1.Step(
            id: step0Id, routineId: routineId, order: 0,
            title: "チェストプレス", sets: 3, repsTarget: 10, restSeconds: 90,
            note: "胸の張りを保つ", isWarmup: false
        ))
        context.insert(PulseCueSchemaV1.Step(
            id: step1Id, routineId: routineId, order: 1,
            title: "ウォームアップ", sets: 1, repsTarget: 15, restSeconds: 30,
            note: "", isWarmup: true
        ))
        let session = PulseCueSchemaV1.Session(
            id: sessionId,
            routineId: routineId,
            dayDate: createdAt,
            startedAt: updatedAt,
            endedAt: endedAt,
            status: .completed,
            totalSeconds: 800
        )
        context.insert(session)
        context.insert(PulseCueSchemaV1.StepResult(
            id: resultId,
            sessionId: sessionId,
            stepId: step0Id,
            setIndex: 0,
            done: true,
            actualReps: 10,
            memo: "完了"
        ))
        // V3 introduced CustomMachine; include one to prove it survives.
        context.insert(CustomMachine(
            id: customMachineId,
            gymId: gymId,
            displayName: "自作プレス機",
            bodyParts: ["chest", "arms"],
            equipmentType: "machine",
            notes: "V3 fixture",
            isAvailable: false,
            createdAt: createdAt,
            updatedAt: updatedAt
        ))
    }

    // MARK: - Migration preserves data and adds nil exerciseId

    @Test
    func v3StepsMigrateWithNilExerciseIdAndPreservedFields() throws {
        try Self.withTempStore { url in
            try Self.seedV3Store(at: url) { try Self.seedRealisticV3($0) }

            try Self.openV4Store(at: url) { context in
                let steps = try context.fetch(FetchDescriptor<Step>(
                    sortBy: [SortDescriptor(\.order)]
                ))
                #expect(steps.count == 2)

                let step0 = try #require(steps.first { $0.id == Self.step0Id })
                #expect(step0.exerciseId == nil)          // additive column → nil
                #expect(step0.routineId == Self.routineId)
                #expect(step0.order == 0)
                #expect(step0.title == "チェストプレス")
                #expect(step0.sets == 3)
                #expect(step0.repsTarget == 10)
                #expect(step0.restSeconds == 90)
                #expect(step0.note == "胸の張りを保つ")
                #expect(step0.isWarmup == false)

                let step1 = try #require(steps.first { $0.id == Self.step1Id })
                #expect(step1.exerciseId == nil)
                #expect(step1.routineId == Self.routineId)
                #expect(step1.order == 1)
                #expect(step1.title == "ウォームアップ")
                #expect(step1.sets == 1)
                #expect(step1.repsTarget == 15)
                #expect(step1.restSeconds == 30)
                #expect(step1.note.isEmpty)
                #expect(step1.isWarmup == true)
            }
        }
    }

    @Test
    func v3RelatedRecordsSurviveMigrationUnchanged() throws {
        try Self.withTempStore { url in
            try Self.seedV3Store(at: url) { try Self.seedRealisticV3($0) }
            try Self.openV4Store(at: url) { context in
                let routines = try context.fetch(FetchDescriptor<Routine>())
                #expect(routines.count == 1)
                let routine = try #require(routines.first)
                #expect(routine.id == Self.routineId)
                #expect(routine.name == "胸の日")
                #expect(routine.isPinned)
                #expect(abs(routine.createdAt.timeIntervalSince(Self.createdAt)) < 0.001)
                #expect(abs(routine.updatedAt.timeIntervalSince(Self.updatedAt)) < 0.001)

                let gyms = try context.fetch(FetchDescriptor<Gym>())
                #expect(gyms.count == 1)
                let gym = try #require(gyms.first)
                #expect(gym.id == Self.gymId)
                #expect(gym.name == "テストジム")
                #expect(gym.officialUrl == "https://example.com")
                #expect(gym.isActive)
                #expect(abs(gym.createdAt.timeIntervalSince(Self.createdAt)) < 0.001)
                #expect(abs(gym.updatedAt.timeIntervalSince(Self.updatedAt)) < 0.001)

                let machines = try context.fetch(FetchDescriptor<GymMachine>())
                #expect(machines.count == 1)
                let machine = try #require(machines.first)
                #expect(machine.id == Self.machineId)
                #expect(machine.gymId == Self.gymId)
                #expect(machine.machineId == "chest_press")
                #expect(machine.displayName == "チェストプレス")
                #expect(machine.isAvailable)
                #expect(abs(machine.addedAt.timeIntervalSince(Self.addedAt)) < 0.001)

                let sessions = try context.fetch(FetchDescriptor<Session>())
                let results = try context.fetch(FetchDescriptor<StepResult>())
                #expect(sessions.count == 1)
                let session = try #require(sessions.first)
                #expect(session.id == Self.sessionId)
                #expect(session.routineId == Self.routineId)
                #expect(abs(session.dayDate.timeIntervalSince(Self.createdAt)) < 0.001)
                #expect(abs(session.startedAt.timeIntervalSince(Self.updatedAt)) < 0.001)
                #expect(abs(try #require(session.endedAt).timeIntervalSince(Self.endedAt)) < 0.001)
                #expect(session.status == .completed)
                #expect(session.totalSeconds == 800)

                #expect(results.count == 1)
                let result = try #require(results.first)
                #expect(result.id == Self.resultId)
                #expect(result.sessionId == Self.sessionId)
                #expect(result.stepId == Self.step0Id)
                #expect(result.setIndex == 0)
                #expect(result.done)
                #expect(result.actualReps == 10)
                #expect(result.memo == "完了")

                let customs = try context.fetch(FetchDescriptor<CustomMachine>())
                #expect(customs.count == 1)
                let custom = try #require(customs.first)
                #expect(custom.id == Self.customMachineId)
                #expect(custom.gymId == Self.gymId)
                #expect(custom.displayName == "自作プレス機")
                #expect(custom.resolvedBodyParts == [.chest, .arms])
                #expect(custom.equipmentType == "machine")
                #expect(custom.notes == "V3 fixture")
                #expect(!custom.isAvailable)
                #expect(abs(custom.createdAt.timeIntervalSince(Self.createdAt)) < 0.001)
                #expect(abs(custom.updatedAt.timeIntervalSince(Self.updatedAt)) < 0.001)
            }
        }
    }

    @Test
    func reopeningMigratedStoreDoesNotDuplicateRows() throws {
        try Self.withTempStore { url in
            try Self.seedV3Store(at: url) { try Self.seedRealisticV3($0) }
            try Self.openV4Store(at: url) { context in
                let count = try context.fetch(FetchDescriptor<Step>()).count
                #expect(count == 2)
            }
            try Self.openV4Store(at: url) { context in
                let steps = try context.fetch(FetchDescriptor<Step>())
                let routines = try context.fetch(FetchDescriptor<Routine>())
                let sessions = try context.fetch(FetchDescriptor<Session>())
                let results = try context.fetch(FetchDescriptor<StepResult>())
                let gyms = try context.fetch(FetchDescriptor<Gym>())
                let machines = try context.fetch(FetchDescriptor<GymMachine>())
                let customs = try context.fetch(FetchDescriptor<CustomMachine>())
                #expect(steps.count == 2)
                #expect(routines.count == 1)
                #expect(sessions.count == 1)
                #expect(results.count == 1)
                #expect(gyms.count == 1)
                #expect(machines.count == 1)
                #expect(customs.count == 1)
                // No exerciseId was fabricated for the pre-existing steps.
                #expect(steps.allSatisfy { $0.exerciseId == nil })
            }
        }
    }

    // MARK: - Actual pre-PR #132 source-generated V3 compatibility

    @Test
    func actualPrePR132V3StoreMigratesToV4AndPreservesGraph() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/pre_pr132_v3.sqlite")
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))

        try Self.withTempStore { url in
            try FileManager.default.copyItem(at: sourceURL, to: url)

            try Self.openV4Store(at: url) { context in
                let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
                let updatedAt = Date(timeIntervalSince1970: 1_700_000_100)
                let addedAt = Date(timeIntervalSince1970: 1_700_000_200)
                let endedAt = Date(timeIntervalSince1970: 1_700_000_900)
                let routines = try context.fetch(FetchDescriptor<Routine>())
                let steps = try context.fetch(FetchDescriptor<Step>(
                    sortBy: [SortDescriptor(\.order)]
                ))
                let sessions = try context.fetch(FetchDescriptor<Session>())
                let results = try context.fetch(FetchDescriptor<StepResult>())
                let gyms = try context.fetch(FetchDescriptor<Gym>())
                let machines = try context.fetch(FetchDescriptor<GymMachine>())
                let customs = try context.fetch(FetchDescriptor<CustomMachine>())

                #expect(routines.count == 1)
                #expect(steps.count == 2)
                #expect(sessions.count == 1)
                #expect(results.count == 1)
                #expect(gyms.count == 1)
                #expect(machines.count == 1)
                #expect(customs.count == 1)

                let routine = try #require(routines.first)
                #expect(routine.id == UUID(uuidString: "10000000-0000-0000-0000-000000000001"))
                #expect(routine.name == "旧V3ルーティン")
                #expect(routine.isPinned)
                #expect(abs(routine.createdAt.timeIntervalSince(createdAt)) < 0.001)
                #expect(abs(routine.updatedAt.timeIntervalSince(updatedAt)) < 0.001)

                let first = try #require(steps.first)
                #expect(first.id == UUID(uuidString: "20000000-0000-0000-0000-000000000001"))
                #expect(first.routineId == routine.id)
                #expect(first.order == 0)
                #expect(first.title == "旧チェストプレス")
                #expect(first.sets == 4)
                #expect(first.repsTarget == 8)
                #expect(first.restSeconds == 120)
                #expect(first.note == "肩甲骨を寄せる")
                #expect(!first.isWarmup)
                #expect(first.exerciseId == nil)

                let second = try #require(steps.last)
                #expect(second.id == UUID(uuidString: "20000000-0000-0000-0000-000000000002"))
                #expect(second.routineId == routine.id)
                #expect(second.order == 1)
                #expect(second.title == "旧ウォームアップ")
                #expect(second.sets == 2)
                #expect(second.repsTarget == 15)
                #expect(second.restSeconds == 45)
                #expect(second.note == "軽い重量")
                #expect(second.isWarmup)
                #expect(second.exerciseId == nil)

                let session = try #require(sessions.first)
                #expect(session.id == UUID(uuidString: "30000000-0000-0000-0000-000000000001"))
                #expect(session.routineId == routine.id)
                #expect(abs(session.dayDate.timeIntervalSince(createdAt)) < 0.001)
                #expect(abs(session.startedAt.timeIntervalSince(updatedAt)) < 0.001)
                #expect(abs(try #require(session.endedAt).timeIntervalSince(endedAt)) < 0.001)
                #expect(session.status == .completed)
                #expect(session.totalSeconds == 800)

                let result = try #require(results.first)
                #expect(result.id == UUID(uuidString: "40000000-0000-0000-0000-000000000001"))
                #expect(result.sessionId == session.id)
                #expect(result.stepId == first.id)
                #expect(result.setIndex == 1)
                #expect(result.done)
                #expect(result.actualReps == 7)
                #expect(result.memo == "旧V3結果")

                let gym = try #require(gyms.first)
                #expect(gym.id == UUID(uuidString: "50000000-0000-0000-0000-000000000001"))
                #expect(gym.name == "旧V3ジム")
                #expect(gym.officialUrl == "https://example.com/old-v3")
                #expect(gym.isActive)
                #expect(abs(gym.createdAt.timeIntervalSince(createdAt)) < 0.001)
                #expect(abs(gym.updatedAt.timeIntervalSince(updatedAt)) < 0.001)

                let machine = try #require(machines.first)
                #expect(machine.id == UUID(uuidString: "60000000-0000-0000-0000-000000000001"))
                #expect(machine.gymId == gym.id)
                #expect(machine.machineId == "chest_press")
                #expect(machine.displayName == "旧チェストプレスマシン")
                #expect(!machine.isAvailable)
                #expect(abs(machine.addedAt.timeIntervalSince(addedAt)) < 0.001)

                let custom = try #require(customs.first)
                #expect(custom.id == UUID(uuidString: "70000000-0000-0000-0000-000000000001"))
                #expect(custom.gymId == gym.id)
                #expect(custom.displayName == "旧カスタムマシン")
                #expect(custom.resolvedBodyParts == [.chest, .arms])
                #expect(custom.equipmentType == "machine")
                #expect(custom.notes == "旧V3 fixture")
                #expect(!custom.isAvailable)
                #expect(abs(custom.createdAt.timeIntervalSince(createdAt)) < 0.001)
                #expect(abs(custom.updatedAt.timeIntervalSince(updatedAt)) < 0.001)
            }

            try Self.openV4Store(at: url) { context in
                let routineCount = try context.fetchCount(FetchDescriptor<Routine>())
                let stepCount = try context.fetchCount(FetchDescriptor<Step>())
                let sessionCount = try context.fetchCount(FetchDescriptor<Session>())
                let resultCount = try context.fetchCount(FetchDescriptor<StepResult>())
                let gymCount = try context.fetchCount(FetchDescriptor<Gym>())
                let machineCount = try context.fetchCount(FetchDescriptor<GymMachine>())
                let customCount = try context.fetchCount(FetchDescriptor<CustomMachine>())
                #expect(routineCount == 1)
                #expect(stepCount == 2)
                #expect(sessionCount == 1)
                #expect(resultCount == 1)
                #expect(gymCount == 1)
                #expect(machineCount == 1)
                #expect(customCount == 1)
            }
        }
    }

    // MARK: - Historical V1 → V2 regression

    @Test
    func v1StoreMigratesToV2AndPreservesWorkoutGraph() throws {
        try Self.withTempStore { url in
            try Self.seedV1Store(at: url) { context in
                context.insert(PulseCueSchemaV1.Routine(
                    id: Self.routineId,
                    name: "V1ルーティン",
                    createdAt: Self.createdAt,
                    updatedAt: Self.updatedAt,
                    isPinned: false
                ))
                context.insert(PulseCueSchemaV1.Step(
                    id: Self.step0Id,
                    routineId: Self.routineId,
                    order: 0,
                    title: "V1種目",
                    sets: 3,
                    repsTarget: 12,
                    restSeconds: 60,
                    note: "V1メモ",
                    isWarmup: false
                ))
                context.insert(PulseCueSchemaV1.Session(
                    id: Self.sessionId,
                    routineId: Self.routineId,
                    dayDate: Self.createdAt,
                    status: .completed,
                    totalSeconds: 600
                ))
                context.insert(PulseCueSchemaV1.StepResult(
                    id: Self.resultId,
                    sessionId: Self.sessionId,
                    stepId: Self.step0Id,
                    setIndex: 0,
                    done: true,
                    actualReps: 12
                ))
            }

            try Self.openV2Store(at: url) { context in
                let routines = try context.fetch(FetchDescriptor<PulseCueSchemaV1.Routine>())
                let steps = try context.fetch(FetchDescriptor<PulseCueSchemaV1.Step>())
                // V2's Session / StepResult are the version-specific legacy
                // shapes (no ownerAccountID), as its Routine and Step are.
                let sessions = try context.fetch(FetchDescriptor<PulseCueSchemaV1.Session>())
                let results = try context.fetch(FetchDescriptor<PulseCueSchemaV1.StepResult>())
                #expect(routines.count == 1)
                #expect(steps.count == 1)
                #expect(sessions.count == 1)
                #expect(results.count == 1)
                #expect(routines.first?.id == Self.routineId)
                #expect(routines.first?.name == "V1ルーティン")
                #expect(steps.first?.id == Self.step0Id)
                #expect(steps.first?.routineId == Self.routineId)
                #expect(steps.first?.title == "V1種目")
                #expect(steps.first?.sets == 3)
                #expect(steps.first?.repsTarget == 12)
                #expect(steps.first?.restSeconds == 60)
                #expect(steps.first?.note == "V1メモ")
                #expect(sessions.first?.routineId == Self.routineId)
                #expect(results.first?.sessionId == Self.sessionId)
                #expect(results.first?.stepId == Self.step0Id)
                let gymCount = try context.fetchCount(FetchDescriptor<Gym>())
                let machineCount = try context.fetchCount(FetchDescriptor<GymMachine>())
                #expect(gymCount == 0)
                #expect(machineCount == 0)
            }
        }
    }

    // MARK: - V4 round-trip: known / known-without-guide / custom / unknown

    @Test
    func knownStandardExerciseIdRoundTripsAndResolves() throws {
        try Self.withTempStore { url in
            let id = UUID()
            try Self.seedV3Store(at: url) { _ in }  // establish a real V3 store
            try Self.openV4Store(at: url) { context in
                context.insert(Step(
                    id: id, routineId: Self.routineId, order: 0,
                    title: "チェストプレス", sets: 3, repsTarget: 10, restSeconds: 90,
                    exerciseId: "machine_chest_press"
                ))
            }
            try Self.openV4Store(at: url) { context in
                let step = try #require(try context.fetch(FetchDescriptor<Step>()).first { $0.id == id })
                #expect(step.exerciseId == "machine_chest_press")
                #expect(step.resolvedExercise?.id == "machine_chest_press")
                #expect(step.resolvedGuide != nil)          // MVP guide exists
                #expect(step.hasResolvableGuide)
            }
        }
    }

    @Test
    func knownExerciseWithoutGuideResolvesExerciseButNilGuide() throws {
        try Self.withTempStore { url in
            let id = UUID()
            try Self.seedV3Store(at: url) { _ in }
            try Self.openV4Store(at: url) { context in
                context.insert(Step(
                    id: id, routineId: Self.routineId, order: 0,
                    title: "バーベルベンチプレス", sets: 4, repsTarget: 8, restSeconds: 120,
                    exerciseId: "barbell_bench_press"
                ))
            }
            try Self.openV4Store(at: url) { context in
                let step = try #require(try context.fetch(FetchDescriptor<Step>()).first { $0.id == id })
                #expect(step.exerciseId == "barbell_bench_press")
                #expect(step.resolvedExercise?.id == "barbell_bench_press")
                #expect(step.resolvedGuide == nil)          // no MVP guide for this one
                #expect(!step.hasResolvableGuide)
            }
        }
    }

    @Test
    func customStepPersistsNilExerciseIdAndKeepsTitle() throws {
        try Self.withTempStore { url in
            let id = UUID()
            try Self.seedV3Store(at: url) { _ in }
            try Self.openV4Store(at: url) { context in
                context.insert(Step(
                    id: id, routineId: Self.routineId, order: 0,
                    title: "自作マシン種目", sets: 3, repsTarget: 12, restSeconds: 60,
                    exerciseId: nil
                ))
            }
            try Self.openV4Store(at: url) { context in
                let step = try #require(try context.fetch(FetchDescriptor<Step>()).first { $0.id == id })
                #expect(step.exerciseId == nil)
                #expect(step.title == "自作マシン種目")   // title (runtime value) intact
                #expect(step.sets == 3)
                #expect(step.resolvedExercise == nil)
                #expect(step.resolvedGuide == nil)
            }
        }
    }

    @Test
    func unknownFutureRawIdSurvivesAndResolvesNilWithoutCrash() throws {
        try Self.withTempStore { url in
            let id = UUID()
            try Self.seedV3Store(at: url) { _ in }
            // Persist a raw id NOT present in the current Exercise Library —
            // simulating a store written by a newer app version.
            try Self.openV4Store(at: url) { context in
                context.insert(Step(
                    id: id, routineId: Self.routineId, order: 0,
                    title: "未来の種目", sets: 3, repsTarget: 10, restSeconds: 60,
                    exerciseId: "future_unknown_exercise_v9"
                ))
            }
            try Self.openV4Store(at: url) { context in
                let step = try #require(try context.fetch(FetchDescriptor<Step>()).first { $0.id == id })
                // Raw string survives persistence verbatim (forward-compatible).
                #expect(step.exerciseId == "future_unknown_exercise_v9")
                // But it does not resolve, and nothing crashes.
                #expect(step.resolvedExercise == nil)
                #expect(step.resolvedGuide == nil)
                #expect(step.title == "未来の種目")
            }
        }
    }
}

// MARK: - Schema history lock

/// Locks the persisted shape of every schema version in `PulseCueMigrationPlan`.
///
/// Several historical versions list *live* model types (`Step.self`,
/// `UserProfile.self`, …) rather than frozen copies. Adding a stored property
/// to such a type silently changes every historical version that lists it, and
/// a store written by the old shape is then recognised as no known version
/// ("Cannot use staged migration with an unknown model version"). That is how a
/// development V10 store from 2026-10-29 became unloadable: V10 lists the live
/// `UserProfile`, which gained `profileOnboardingStepRaw` after the store was
/// written.
///
/// IF A FINGERPRINT HERE FAILS, DO NOT JUST UPDATE THE EXPECTED VALUE. A store
/// stamped with that version may already exist on a device. Instead:
///   - add a new schema version (V15, …) for the new shape, and
///   - freeze the old shape as a nested type of the historical version(s) that
///     listed the live type (as `PulseCueSchemaV13.StepResult` does),
/// so every historical fingerprint returns to its locked value. Only update an
/// expected value for a version that has provably never been on `main`.
/// V14 is locked too: it is on `main`, so stores stamped 14.0.0 can exist.
/// V14 lists a frozen `StepResult` since V15 (see `PulseCueSchemaV14.StepResult`).
@MainActor
struct SchemaHistoryLockTests {

    /// Canonical, order-independent text of one schema's persisted shape, built
    /// from the public `NSManagedObjectModel` SwiftData derives for it. Includes
    /// each entity's Core Data `versionHash` — the value a store's metadata is
    /// matched against — plus the readable shape, so a failure says what moved.
    static func canonicalShape(_ models: [any PersistentModel.Type]) -> String {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: models) else {
            return "<makeManagedObjectModel failed>"
        }
        return model.entities
            .sorted { ($0.name ?? "") < ($1.name ?? "") }
            .map { entity -> String in
                let hash = entity.versionHash.map { String(format: "%02x", $0) }.joined()
                let attributes = entity.attributesByName.keys.sorted().map { name -> String in
                    let a = entity.attributesByName[name]!
                    return "  attr \(name) type=\(a.attributeType.rawValue) optional=\(a.isOptional) "
                        + "transient=\(a.isTransient) default=\(a.defaultValue != nil) "
                        + "external=\(a.allowsExternalBinaryDataStorage)"
                }
                let relationships = entity.relationshipsByName.keys.sorted().map { name -> String in
                    let r = entity.relationshipsByName[name]!
                    return "  rel \(name) -> \(r.destinationEntity?.name ?? "?") toMany=\(r.isToMany) "
                        + "optional=\(r.isOptional) delete=\(r.deleteRule.rawValue) "
                        + "inverse=\(r.inverseRelationship?.name ?? "-") min=\(r.minCount) max=\(r.maxCount)"
                }
                let unique = entity.uniquenessConstraints
                    .map { $0.map { "\($0)" }.sorted().joined(separator: "+") }
                    .sorted()
                    .joined(separator: ",")
                return (["entity \(entity.name ?? "?") hash=\(hash) unique=[\(unique)]"] + attributes + relationships)
                    .joined(separator: "\n")
            }
            .joined(separator: "\n")
    }

    static func fingerprint(_ models: [any PersistentModel.Type]) -> String {
        SHA256.hash(data: Data(canonicalShape(models).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Fingerprints taken from `main` 713e1cb. See the type comment before
    /// changing any of these.
    static let expectedFingerprints: [String: String] = [
        "1.0.0": "73fc2f0eb4ddb81337c02df62abfba5fa6f82f384e7c0bc9c0b08bea56f41880",
        "2.0.0": "c1150bffb926f085e5942fdfb9407f575c8b0b67e6f042a930ea2c1a4442a8c1",
        "3.0.0": "b8329c9d3c9ca0525a34a8de38ab9062890ca7861337f2cbd8a9e15cb014fa30",
        "4.0.0": "cd7b1f0acaebee399cbc96247b7d16eb71fc4f3caf71a87e754cdaf77b4416f6",
        "5.0.0": "23158aa0a5705eb867cc50824ac3c796e6f8de307e0cffdd88509115bb909261",
        "6.0.0": "076bed29abee084dbe1b4751b919803f0f5d3e1fdd642eff56314292ee5965d2",
        "7.0.0": "7c6bb03847a3b53c4a059b9ff10aa563c9b56416a6ef9c4c827b4b6433f0fe98",
        "8.0.0": "cf769af0edf72c6b66742a748f4f16986b2f2d9effe15e1d4da25db15cf87a9d",
        "9.0.0": "28eef746f66d124ed1700abafd9f1d1be7634f4bdf97475b137726bd528e63bd",
        "10.0.0": "7157d0e30681db9aa7faa0e801f3d992f868f7d006766d8ba754cb07c19b2e4d",
        "11.0.0": "df6b46233e8cd47f1b9228a2be31ffb0c583a1d6aabac771ad6630168ccfb413",
        "12.0.0": "9332d00f4ce56b3a0839b57474c1f248884919b5347a6b65ddeb66cc63b12dc1",
        "13.0.0": "0478f6253031f2fbe4004cea3e45af86f518a01588af0569a5c4d0f007a1938a",
        "14.0.0": "39d69eca8e26d96b54994ba33c4af536d080787d99ca862b43d4da5543eedbaa",
        "15.0.0": "a842c7a807c3efd4252d71b2eed5eb515353fe5800d64ffa1fe5cda97973b9a0",
        "16.0.0": "ad4c604d8d364ca29c5417a4bcc37858b6c05c725ca789850b35616a7a13db35",
    ]

    private static let expectedVersions: [Schema.Version] = (1...16).map { Schema.Version($0, 0, 0) }

    @Test func everyKnownSchemaFingerprintIsLocked() {
        #expect(Set(Self.expectedFingerprints.keys) == Set(Self.expectedVersions.map { "\($0)" }))
        for schema in PulseCueMigrationPlan.schemas {
            let version = "\(schema.versionIdentifier)"
            #expect(Self.expectedFingerprints[version] == Self.fingerprint(schema.models),
                    "Schema \(version) changed shape:\n\(Self.canonicalShape(schema.models))")
        }
    }

    @Test func fingerprintsAreDeterministic() {
        for schema in PulseCueMigrationPlan.schemas {
            let forward = Self.fingerprint(schema.models)
            #expect(Self.fingerprint(schema.models.reversed()) == forward)
            #expect(Self.fingerprint(schema.models) == forward)
        }
    }

    @Test func everySchemaVersionIdentifierIsLocked() {
        #expect(PulseCueSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(PulseCueSchemaV2.versionIdentifier == Schema.Version(2, 0, 0))
        #expect(PulseCueSchemaV3.versionIdentifier == Schema.Version(3, 0, 0))
        #expect(PulseCueSchemaV4.versionIdentifier == Schema.Version(4, 0, 0))
        #expect(PulseCueSchemaV5.versionIdentifier == Schema.Version(5, 0, 0))
        #expect(PulseCueSchemaV6.versionIdentifier == Schema.Version(6, 0, 0))
        #expect(PulseCueSchemaV7.versionIdentifier == Schema.Version(7, 0, 0))
        #expect(PulseCueSchemaV8.versionIdentifier == Schema.Version(8, 0, 0))
        #expect(PulseCueSchemaV9.versionIdentifier == Schema.Version(9, 0, 0))
        #expect(PulseCueSchemaV10.versionIdentifier == Schema.Version(10, 0, 0))
        #expect(PulseCueSchemaV11.versionIdentifier == Schema.Version(11, 0, 0))
        #expect(PulseCueSchemaV12.versionIdentifier == Schema.Version(12, 0, 0))
        #expect(PulseCueSchemaV13.versionIdentifier == Schema.Version(13, 0, 0))
        #expect(PulseCueSchemaV14.versionIdentifier == Schema.Version(14, 0, 0))
        #expect(PulseCueSchemaV15.versionIdentifier == Schema.Version(15, 0, 0))
        #expect(PulseCueSchemaV16.versionIdentifier == Schema.Version(16, 0, 0))
    }

    @Test func migrationPlanListsEveryKnownSchemaInOrder() {
        #expect(PulseCueMigrationPlan.schemas.map { $0.versionIdentifier } == Self.expectedVersions)
    }

    @Test func migrationStagesConnectEachAdjacentPair() {
        let schemas = PulseCueMigrationPlan.schemas
        let stages = PulseCueMigrationPlan.stages
        #expect(stages.count == schemas.count - 1)
        for (index, stage) in stages.enumerated() {
            guard case let .lightweight(from, to) = stage else {
                Issue.record("Stage \(index) is not lightweight")
                continue
            }
            #expect(from.versionIdentifier == schemas[index].versionIdentifier)
            #expect(to.versionIdentifier == schemas[index + 1].versionIdentifier)
        }
    }

    /// The 2026-10-29 failure, conceptually: V10 lists the live `UserProfile`,
    /// so any change to that type's stored shape changes V10's fingerprint.
    /// Swapping in another `UserProfile` shape (V8's frozen one) stands in for
    /// a property added to the live type.
    @Test func aChangedLiveUserProfileWouldChangeTheV10Fingerprint() {
        let v10 = PulseCueSchemaV10.models
        #expect(v10.contains { ObjectIdentifier($0) == ObjectIdentifier(UserProfile.self) })
        let altered = v10.map {
            ObjectIdentifier($0) == ObjectIdentifier(UserProfile.self) ? PulseCueSchemaV8.UserProfile.self : $0
        }
        #expect(Self.fingerprint(altered) != Self.expectedFingerprints["10.0.0"])
    }

    /// V13 keeps its frozen `StepResult`. Pointing it back at the live
    /// `StepResult` would make V13 the V14 shape, which this lock rejects.
    @Test func v13KeepsItsFrozenStepResult() {
        let v13 = PulseCueSchemaV13.models
        #expect(v13.contains { ObjectIdentifier($0) == ObjectIdentifier(PulseCueSchemaV13.StepResult.self) })
        #expect(!v13.contains { ObjectIdentifier($0) == ObjectIdentifier(StepResult.self) })
        let unfrozen = v13.map {
            ObjectIdentifier($0) == ObjectIdentifier(PulseCueSchemaV13.StepResult.self) ? StepResult.self : $0
        }
        #expect(Self.fingerprint(unfrozen) != Self.expectedFingerprints["13.0.0"])
        #expect(Self.expectedFingerprints["13.0.0"] != Self.expectedFingerprints["14.0.0"])
    }

    /// V14 keeps its frozen `StepResult` once V15 adds a field to the live one.
    @Test func v14KeepsItsFrozenStepResult() {
        let v14 = PulseCueSchemaV14.models
        #expect(v14.contains { ObjectIdentifier($0) == ObjectIdentifier(PulseCueSchemaV14.StepResult.self) })
        #expect(!v14.contains { ObjectIdentifier($0) == ObjectIdentifier(StepResult.self) })
        let unfrozen = v14.map {
            ObjectIdentifier($0) == ObjectIdentifier(PulseCueSchemaV14.StepResult.self) ? StepResult.self : $0
        }
        #expect(Self.fingerprint(unfrozen) != Self.expectedFingerprints["14.0.0"])
        #expect(Self.expectedFingerprints["14.0.0"] != Self.expectedFingerprints["15.0.0"])
    }

    /// V15 keeps its frozen `StepResult` once V16 adds `repsInReserve` to the
    /// live one; V16 is the only version that lists the live type.
    @Test func v15KeepsItsFrozenStepResult() {
        let v15 = PulseCueSchemaV15.models
        #expect(v15.contains { ObjectIdentifier($0) == ObjectIdentifier(PulseCueSchemaV15.StepResult.self) })
        #expect(!v15.contains { ObjectIdentifier($0) == ObjectIdentifier(StepResult.self) })
        let unfrozen = v15.map {
            ObjectIdentifier($0) == ObjectIdentifier(PulseCueSchemaV15.StepResult.self) ? StepResult.self : $0
        }
        #expect(Self.fingerprint(unfrozen) != Self.expectedFingerprints["15.0.0"])
        #expect(Self.fingerprint(unfrozen) == Self.expectedFingerprints["16.0.0"])
        #expect(PulseCueSchemaV16.models.contains { ObjectIdentifier($0) == ObjectIdentifier(StepResult.self) })
        #expect(PulseCueMigrationPlan.schemas.last == PulseCueSchemaV16.self)
    }
}
