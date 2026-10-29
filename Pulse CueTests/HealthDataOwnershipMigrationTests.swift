//
//  HealthDataOwnershipMigrationTests.swift
//  Pulse CueTests
//
//  Real on-disk V7 → V8 migration proof for health-data ownership:
//  `DayLog` / `MealEntry` / `UserProfile` gain `ownerAccountID`, and
//  `DayLog` uniqueness moves from the global `date` to the per-owner
//  `scopedDayKey`.
//
//  Seeds are built with an old schema ONLY (no plan), so the store is genuinely
//  stamped with that version and holds the owner-less pinned
//  `PulseCueSchemaV1.DayLog` / `.MealEntry` / `.UserProfile`. The V8 open goes
//  through `PulseCueMigrationPlan`. Assertions check preserved values and
//  owner == nil — never just "it opened".
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct HealthDataOwnershipMigrationTests {

    private static func withTempStore(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsecue-v8migtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.appendingPathComponent("store.sqlite"))
    }

    /// Opens the store with `version` ONLY (no plan), so it is stamped with
    /// that version. Released on return.
    private static func seed(
        _ version: any VersionedSchema.Type,
        at url: URL,
        _ work: (ModelContext) throws -> Void
    ) throws {
        let schema = Schema(versionedSchema: version)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, url: url)
        )
        let context = ModelContext(container)
        try work(context)
        try context.save()
    }

    /// Opens the same store the way the app does: the current schema + the
    /// migration plan, then the scoped-key backfill.
    private static func openV8Store(at url: URL, _ work: (ModelContext) throws -> Void) throws {
        let schema = Schema(versionedSchema: PulseCueSchemaV10.self)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: PulseCueMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: url)
        )
        try PulseCueSchemaV8.backfillScopedDayKeys(in: ModelContext(container))
        let context = ModelContext(container)
        try work(context)
        try context.save()
    }

    private static let dayX = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let dayY = Date(timeIntervalSinceReferenceDate: 800_086_400)
    private static let dayZ = Date(timeIntervalSinceReferenceDate: 800_172_800)

    // MARK: - V7 → V8

    @Test("V7 → V8 keeps every health row, value for value, as guest data")
    func v7StoreMigratesHealthRowsAsGuest() throws {
        let mealID = UUID()
        let profileID = UUID()
        let owner = UUID()
        let ownedSessionID = UUID()
        let guestSessionID = UUID()
        let resultID = UUID()
        let created = Date(timeIntervalSinceReferenceDate: 800_010_000)
        let updated = Date(timeIntervalSinceReferenceDate: 800_020_000)

        try Self.withTempStore { url in
            try Self.seed(PulseCueSchemaV7.self, at: url) { context in
                context.insert(PulseCueSchemaV1.DayLog(
                    date: Self.dayX, intakeCalories: 2100, exerciseCalories: 450,
                    sleepMinutes: 420, weightKg: 68.4, note: "day X"
                ))
                context.insert(PulseCueSchemaV1.DayLog(date: Self.dayY, weightKg: 68.1))
                context.insert(PulseCueSchemaV1.DayLog(date: Self.dayZ))
                context.insert(PulseCueSchemaV1.MealEntry(
                    id: mealID, dayDate: Self.dayX, slotRaw: "lunch", name: "定食",
                    kcal: 780, proteinGrams: 32, carbGrams: 95, fatGrams: 24,
                    statusRaw: "confirmed", sourceRaw: "barcode", note: "meal note",
                    createdAt: created
                ))
                context.insert(PulseCueSchemaV1.UserProfile(
                    id: profileID, heightCm: 172, ageYears: 41, biologicalSexRaw: "male",
                    activityFactorRaw: "light", goalWeightKg: 64.5, weeklyChangeKg: -0.25,
                    updatedAt: updated
                ))
                context.insert(Session(
                    id: ownedSessionID, routineId: UUID(), dayDate: Self.dayX,
                    status: .completed, totalSeconds: 900, ownerAccountID: owner
                ))
                context.insert(Session(
                    id: guestSessionID, routineId: UUID(), dayDate: Self.dayX, status: .completed
                ))
                context.insert(StepResult(
                    id: resultID, sessionId: ownedSessionID, stepId: UUID(), setIndex: 1,
                    done: true, actualReps: 10, memo: "set", ownerAccountID: owner
                ))
            }

            try Self.openV8Store(at: url) { context in
                let logs = try context.fetch(FetchDescriptor<DayLog>(sortBy: [SortDescriptor(\.date)]))
                #expect(logs.map(\.date) == [Self.dayX, Self.dayY, Self.dayZ])
                #expect(logs.allSatisfy { $0.ownerAccountID == nil })
                #expect(logs.map(\.scopedDayKey) == [Self.dayX, Self.dayY, Self.dayZ].map {
                    DayLog.scopedDayKey(ownerAccountID: nil, date: $0)
                })
                let x = logs[0]
                #expect(x.intakeCalories == 2100)
                #expect(x.exerciseCalories == 450)
                #expect(x.sleepMinutes == 420)
                #expect(x.weightKg == 68.4)
                #expect(x.note == "day X")
                #expect(logs[1].weightKg == 68.1)
                #expect(logs[1].intakeCalories == nil)

                let meals = try context.fetch(FetchDescriptor<MealEntry>())
                #expect(meals.count == 1)
                let meal = try #require(meals.first)
                #expect(meal.id == mealID)
                #expect(meal.dayDate == Self.dayX)
                #expect(meal.slotRaw == "lunch")
                #expect(meal.name == "定食")
                #expect(meal.kcal == 780)
                #expect(meal.proteinGrams == 32)
                #expect(meal.carbGrams == 95)
                #expect(meal.fatGrams == 24)
                #expect(meal.statusRaw == "confirmed")
                #expect(meal.sourceRaw == "barcode")
                #expect(meal.note == "meal note")
                #expect(meal.createdAt == created)
                #expect(meal.ownerAccountID == nil)

                let profiles = try context.fetch(FetchDescriptor<UserProfile>())
                #expect(profiles.count == 1)
                let profile = try #require(profiles.first)
                #expect(profile.id == profileID)
                #expect(profile.heightCm == 172)
                #expect(profile.ageYears == 41)
                #expect(profile.biologicalSexRaw == "male")
                #expect(profile.activityFactorRaw == "light")
                #expect(profile.goalWeightKg == 64.5)
                #expect(profile.weeklyChangeKg == -0.25)
                #expect(profile.updatedAt == updated)
                #expect(profile.ownerAccountID == nil)

                // Workout ownership from V6 is untouched by the health migration.
                let sessions = try context.fetch(FetchDescriptor<Session>())
                #expect(sessions.count == 2)
                #expect(sessions.first { $0.id == ownedSessionID }?.ownerAccountID == owner)
                #expect(sessions.first { $0.id == ownedSessionID }?.totalSeconds == 900)
                #expect(sessions.first { $0.id == guestSessionID }?.ownerAccountID == nil)
                let results = try context.fetch(FetchDescriptor<StepResult>())
                #expect(results.count == 1)
                #expect(results.first?.ownerAccountID == owner)
                #expect(results.first?.actualReps == 10)
            }
        }
    }

    @Test("A migrated guest DayLog still upserts a new guest log for the same day")
    func migratedGuestLogKeepsItsDayUniqueness() throws {
        try Self.withTempStore { url in
            try Self.seed(PulseCueSchemaV7.self, at: url) { context in
                context.insert(PulseCueSchemaV1.DayLog(date: Self.dayX, intakeCalories: 1500))
            }

            try Self.openV8Store(at: url) { context in
                context.insert(DayLog(date: Self.dayX, intakeCalories: 1800))
                try context.save()
                let logs = try context.fetch(FetchDescriptor<DayLog>())
                #expect(logs.count == 1)
                #expect(logs.first?.ownerAccountID == nil)
            }
        }
    }

    @Test("After V7 → V8 the old global UNIQUE(date) is gone: A and B join a migrated guest day")
    func migratedStoreAcceptsAccountsOnAGuestDay() throws {
        let a = UUID()
        let b = UUID()

        try Self.withTempStore { url in
            try Self.seed(PulseCueSchemaV7.self, at: url) { context in
                context.insert(PulseCueSchemaV1.DayLog(date: Self.dayX, intakeCalories: 1000))
            }

            try Self.openV8Store(at: url) { context in
                context.insert(DayLog(date: Self.dayX, intakeCalories: 2000, ownerAccountID: a))
                context.insert(DayLog(date: Self.dayX, intakeCalories: 3000, ownerAccountID: b))
            }

            try Self.openV8Store(at: url) { context in
                let logs = try context.fetch(FetchDescriptor<DayLog>())
                #expect(logs.count == 3)
                #expect(logs.allSatisfy { $0.date == Self.dayX })
                #expect(logs.first { $0.ownerAccountID == nil }?.intakeCalories == 1000)
                #expect(logs.first { $0.ownerAccountID == a }?.intakeCalories == 2000)
                #expect(logs.first { $0.ownerAccountID == b }?.intakeCalories == 3000)
            }
        }
    }

    // MARK: - DayLog per-owner uniqueness

    @Test("Guest, A and B each keep their own DayLog for the same date")
    func guestAndTwoAccountsCoexistOnOneDay() throws {
        let a = UUID()
        let b = UUID()

        try Self.withTempStore { url in
            try Self.openV8Store(at: url) { context in
                context.insert(DayLog(date: Self.dayX, intakeCalories: 1000))
                context.insert(DayLog(date: Self.dayX, intakeCalories: 2000, ownerAccountID: a))
                context.insert(DayLog(date: Self.dayX, intakeCalories: 3000, ownerAccountID: b))
            }

            try Self.openV8Store(at: url) { context in
                let logs = try context.fetch(FetchDescriptor<DayLog>())
                #expect(logs.count == 3)
                #expect(logs.first { $0.ownerAccountID == nil }?.intakeCalories == 1000)
                #expect(logs.first { $0.ownerAccountID == a }?.intakeCalories == 2000)
                #expect(logs.first { $0.ownerAccountID == b }?.intakeCalories == 3000)
                #expect(Set(logs.map(\.scopedDayKey)).count == 3)
                // `date` has a private setter; SwiftData still restores it.
                #expect(logs.allSatisfy { $0.date == Self.dayX })
            }
        }
    }

    @Test("A second DayLog for the same owner and date does not become a second row")
    func sameOwnerSameDayCollapsesToOneRow() throws {
        let a = UUID()

        try Self.withTempStore { url in
            try Self.openV8Store(at: url) { context in
                context.insert(DayLog(date: Self.dayX, intakeCalories: 2000, ownerAccountID: a))
                try context.save()
                context.insert(DayLog(date: Self.dayX, intakeCalories: 2500, ownerAccountID: a))
            }

            try Self.openV8Store(at: url) { context in
                let logs = try context.fetch(FetchDescriptor<DayLog>())
                #expect(logs.count == 1)
                #expect(logs.first?.ownerAccountID == a)
            }
        }
    }

    @Test("The scoped day key is deterministic and independent of locale and timezone")
    func scopedDayKeyIsStable() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let key = DayLog.scopedDayKey(ownerAccountID: a, date: Self.dayX)
        #expect(key == DayLog.scopedDayKey(ownerAccountID: a, date: Self.dayX))
        #expect(key == "00000000-0000-0000-0000-0000000000AA|41c7d78400000000")
        #expect(DayLog.scopedDayKey(ownerAccountID: nil, date: Self.dayX) == "guest|41c7d78400000000")
        #expect(key != DayLog.scopedDayKey(ownerAccountID: a, date: Self.dayY))
    }

    @Test("+0.0 and -0.0 are one instant, so they get one key")
    func signedZeroSharesOneKey() {
        let positive = Date(timeIntervalSinceReferenceDate: 0.0)
        let negative = Date(timeIntervalSinceReferenceDate: -0.0)
        let a = UUID()
        #expect(DayLog.scopedDayKey(ownerAccountID: a, date: positive)
            == DayLog.scopedDayKey(ownerAccountID: a, date: negative))
        #expect(DayLog.scopedDayKey(ownerAccountID: nil, date: negative) == "guest|0")
    }

    // MARK: - MealEntry / UserProfile ownership

    @Test("MealEntry and UserProfile owners survive a reopen")
    func mealAndProfileOwnersPersist() throws {
        let a = UUID()
        let b = UUID()

        try Self.withTempStore { url in
            try Self.openV8Store(at: url) { context in
                context.insert(MealEntry(
                    dayDate: Self.dayX, slot: .lunch, name: "A", kcal: 500,
                    status: .confirmed, source: .manual, ownerAccountID: a
                ))
                context.insert(MealEntry(
                    dayDate: Self.dayX, slot: .lunch, name: "guest", kcal: 400,
                    status: .confirmed, source: .manual
                ))
                context.insert(UserProfile(heightCm: 160, ownerAccountID: a))
                context.insert(UserProfile(heightCm: 180, ownerAccountID: b))
                context.insert(UserProfile(heightCm: 170))
            }

            try Self.openV8Store(at: url) { context in
                let meals = try context.fetch(FetchDescriptor<MealEntry>())
                #expect(meals.count == 2)
                #expect(meals.first { $0.name == "A" }?.ownerAccountID == a)
                #expect(meals.first { $0.name == "guest" }?.ownerAccountID == nil)

                let profiles = try context.fetch(FetchDescriptor<UserProfile>())
                #expect(profiles.count == 3)
                #expect(profiles.first { $0.ownerAccountID == a }?.heightCm == 160)
                #expect(profiles.first { $0.ownerAccountID == b }?.heightCm == 180)
                #expect(profiles.first { $0.ownerAccountID == nil }?.heightCm == 170)
            }
        }
    }

    // MARK: - Historical schema preservation

    @Test("V1–V7 keep the pinned owner-less health models; V8+ carry owners, V10 the current profile")
    func historicalSchemasStayPinned() {
        let current: Set<ObjectIdentifier> = [
            ObjectIdentifier(DayLog.self),
            ObjectIdentifier(MealEntry.self),
            ObjectIdentifier(UserProfile.self)
        ]
        let pinned: Set<ObjectIdentifier> = [
            ObjectIdentifier(PulseCueSchemaV1.DayLog.self),
            ObjectIdentifier(PulseCueSchemaV1.MealEntry.self),
            ObjectIdentifier(PulseCueSchemaV1.UserProfile.self)
        ]
        let historical: [any VersionedSchema.Type] = [
            PulseCueSchemaV1.self, PulseCueSchemaV2.self, PulseCueSchemaV3.self,
            PulseCueSchemaV4.self, PulseCueSchemaV5.self, PulseCueSchemaV6.self,
            PulseCueSchemaV7.self
        ]
        for version in historical {
            let ids = Set(version.models.map { ObjectIdentifier($0) })
            #expect(ids.isDisjoint(with: current), "\(version) references a current health model")
            #expect(pinned.isSubset(of: ids), "\(version) lost a pinned health model")

            let entities = Schema(versionedSchema: version).entitiesByName
            for name in ["DayLog", "MealEntry", "UserProfile"] {
                let names = Set(entities[name]?.properties.map(\.name) ?? [])
                #expect(!names.isEmpty, "\(version) has no \(name)")
                #expect(!names.contains("ownerAccountID"), "\(version).\(name) gained an owner")
            }
            let dayLogNames = Set(entities["DayLog"]?.properties.map(\.name) ?? [])
            #expect(!dayLogNames.contains("scopedDayKey"), "\(version).DayLog gained a scoped key")
        }

        // V8 introduced the owner columns; V10 later pinned V8's profile shape
        // so its training fields could not leak back into V8 and V9.
        let v8 = Set(PulseCueSchemaV8.models.map { ObjectIdentifier($0) })
        #expect(v8.isDisjoint(with: pinned))
        #expect(v8.contains(ObjectIdentifier(DayLog.self)))
        #expect(v8.contains(ObjectIdentifier(MealEntry.self)))
        #expect(v8.contains(ObjectIdentifier(PulseCueSchemaV8.UserProfile.self)))
        let v10 = Set(PulseCueSchemaV10.models.map { ObjectIdentifier($0) })
        #expect(current.isSubset(of: v10))
    }

    @Test(
        "Representative V1, V5, V6 and V7 stores with health rows open at V8",
        arguments: [1, 5, 6, 7]
    )
    func historicalStoresReopenAtV8(version: Int) throws {
        let schemas: [Int: any VersionedSchema.Type] = [
            1: PulseCueSchemaV1.self, 5: PulseCueSchemaV5.self,
            6: PulseCueSchemaV6.self, 7: PulseCueSchemaV7.self
        ]
        let mealID = UUID()

        try Self.withTempStore { url in
            try Self.seed(try #require(schemas[version]), at: url) { context in
                context.insert(PulseCueSchemaV1.DayLog(date: Self.dayX, sleepMinutes: 400))
                context.insert(PulseCueSchemaV1.MealEntry(
                    id: mealID, dayDate: Self.dayX, slotRaw: "dinner", name: "v\(version)",
                    kcal: 600, statusRaw: "confirmed", sourceRaw: "manual", createdAt: Self.dayX
                ))
                context.insert(PulseCueSchemaV1.UserProfile(
                    heightCm: 165, ageYears: 30, biologicalSexRaw: "female",
                    activityFactorRaw: "moderate", goalWeightKg: 55, weeklyChangeKg: 0,
                    updatedAt: Self.dayX
                ))
            }

            try Self.openV8Store(at: url) { context in
                let logs = try context.fetch(FetchDescriptor<DayLog>())
                #expect(logs.count == 1)
                #expect(logs.first?.sleepMinutes == 400)
                #expect(logs.first?.ownerAccountID == nil)
                #expect(logs.first?.scopedDayKey == DayLog.scopedDayKey(ownerAccountID: nil, date: Self.dayX))
                let meals = try context.fetch(FetchDescriptor<MealEntry>())
                #expect(meals.map(\.id) == [mealID])
                #expect(meals.first?.name == "v\(version)")
                #expect(meals.first?.ownerAccountID == nil)
                let profiles = try context.fetch(FetchDescriptor<UserProfile>())
                #expect(profiles.count == 1)
                #expect(profiles.first?.heightCm == 165)
                #expect(profiles.first?.ownerAccountID == nil)
            }
        }
    }

    @Test("The actual shipped pre-PR #132 V3 store migrates all the way to V8")
    func shippedV3FixtureOpensAtV8() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/pre_pr132_v3.sqlite")
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))

        try Self.withTempStore { url in
            try FileManager.default.copyItem(at: sourceURL, to: url)
            try Self.openV8Store(at: url) { context in
                #expect(try context.fetchCount(FetchDescriptor<Routine>()) == 1)
                #expect(try context.fetchCount(FetchDescriptor<Session>()) == 1)
                let logs = try context.fetch(FetchDescriptor<DayLog>())
                #expect(logs.allSatisfy { $0.ownerAccountID == nil && $0.scopedDayKey != nil })
            }
        }
    }
}
