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
            schema: Schema(versionedSchema: PulseCueSchemaV5.self),
            url: url
        )
        let container = try ModelContainer(
            for: Schema(versionedSchema: PulseCueSchemaV5.self),
            migrationPlan: PulseCueMigrationPlan.self,
            configurations: config
        )
        let context = ModelContext(container)
        try work(context)
        try context.save()
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
        let session = Session(
            id: sessionId,
            routineId: routineId,
            dayDate: createdAt,
            startedAt: updatedAt,
            endedAt: endedAt,
            status: .completed,
            totalSeconds: 800
        )
        context.insert(session)
        context.insert(StepResult(
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
                context.insert(Session(
                    id: Self.sessionId,
                    routineId: Self.routineId,
                    dayDate: Self.createdAt,
                    status: .completed,
                    totalSeconds: 600
                ))
                context.insert(StepResult(
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
                let sessions = try context.fetch(FetchDescriptor<Session>())
                let results = try context.fetch(FetchDescriptor<StepResult>())
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
