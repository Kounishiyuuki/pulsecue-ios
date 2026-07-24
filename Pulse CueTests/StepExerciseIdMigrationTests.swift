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

    /// Opens the same store with the V4 schema + migration plan (runs the
    /// V3 → V4 lightweight stage).
    private static func openV4Store(at url: URL, _ work: (ModelContext) throws -> Void) throws {
        let config = ModelConfiguration(
            schema: Schema(versionedSchema: PulseCueSchemaV4.self),
            url: url
        )
        let container = try ModelContainer(
            for: Schema(versionedSchema: PulseCueSchemaV4.self),
            migrationPlan: PulseCueMigrationPlan.self,
            configurations: config
        )
        let context = ModelContext(container)
        try work(context)
        try context.save()
    }

    // MARK: - Fixed fixture values

    private static let gymId = UUID()
    private static let machineId = UUID()
    private static let routineId = UUID()
    private static let step0Id = UUID()
    private static let step1Id = UUID()
    private static let sessionId = UUID()
    private static let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    private static let addedAt = Date(timeIntervalSince1970: 1_700_000_500)

    /// Seeds a realistic V3 graph using the LEGACY column-less Step.
    private static func seedRealisticV3(_ context: ModelContext) throws {
        let gym = Gym(
            id: gymId, name: "テストジム", officialUrl: "https://example.com",
            isActive: true, createdAt: createdAt, updatedAt: createdAt
        )
        context.insert(gym)
        context.insert(GymMachine(
            id: machineId, gymId: gymId, machineId: "chest_press",
            displayName: "チェストプレス", isAvailable: true, addedAt: addedAt
        ))
        context.insert(Routine(id: routineId, name: "胸の日"))
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
        let session = Session(id: sessionId, routineId: routineId, dayDate: createdAt)
        context.insert(session)
        context.insert(StepResult(
            sessionId: sessionId, stepId: step0Id, setIndex: 0, done: true, actualReps: 10
        ))
        // V3 introduced CustomMachine; include one to prove it survives.
        context.insert(CustomMachine(
            gymId: gymId, displayName: "自作プレス機", bodyParts: ["chest", "arms"]
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
                #expect(step1.title == "ウォームアップ")
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
                #expect(routines.first?.id == Self.routineId)
                #expect(routines.first?.name == "胸の日")

                let gyms = try context.fetch(FetchDescriptor<Gym>())
                #expect(gyms.first?.id == Self.gymId)
                #expect(gyms.first?.name == "テストジム")

                let machines = try context.fetch(FetchDescriptor<GymMachine>())
                #expect(machines.first?.machineId == "chest_press")

                let sessions = try context.fetch(FetchDescriptor<Session>())
                let results = try context.fetch(FetchDescriptor<StepResult>())
                #expect(sessions.first?.id == Self.sessionId)
                #expect(results.first?.stepId == Self.step0Id)

                let customs = try context.fetch(FetchDescriptor<CustomMachine>())
                #expect(customs.count == 1)
                #expect(customs.first?.displayName == "自作プレス機")
                #expect(customs.first?.resolvedBodyParts == [.chest, .arms])
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
                let customs = try context.fetch(FetchDescriptor<CustomMachine>())
                #expect(steps.count == 2)
                #expect(routines.count == 1)
                #expect(customs.count == 1)
                // No exerciseId was fabricated for the pre-existing steps.
                #expect(steps.allSatisfy { $0.exerciseId == nil })
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
