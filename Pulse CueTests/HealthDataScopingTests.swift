//
//  HealthDataScopingTests.swift
//  Pulse CueTests
//
//  Guest / account A / account B health data — day logs, meals, profile —
//  read, written and adopted through `HealthDataScope`. Adoption tests use an
//  on-disk store so "after reopen" means what it says.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct HealthDataScopingTests {

    private static let accountA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private static let accountB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
    private static let today = DateUtils.startOfDay(Date())
    private static let dayX = DateUtils.startOfDay(Date(timeIntervalSinceReferenceDate: 800_000_000))
    private static let dayY = DateUtils.startOfDay(Date(timeIntervalSinceReferenceDate: 800_259_200))

    private struct CommitFailure: Error {}

    // MARK: - Fixture

    private static func makeContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: PulseCueSchemaV8.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private static func withTempStore(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsecue-healthscope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.appendingPathComponent("store.sqlite"))
    }

    /// A fresh container on `url` each call — a real reopen.
    private static func open(_ url: URL, _ work: (ModelContext) throws -> Void) throws {
        let schema = Schema(versionedSchema: PulseCueSchemaV8.self)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: PulseCueMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: url)
        )
        let context = ModelContext(container)
        try work(context)
    }

    private static func meal(_ kcal: Int, day: Date, owner: UUID?, status: MealStatus = .confirmed) -> MealEntry {
        MealEntry(dayDate: day, slot: .lunch, name: "m\(kcal)", kcal: kcal, status: status, source: .manual, ownerAccountID: owner)
    }

    /// Guest 70kg/400min/500kcal/170cm, A 80/450/1000/180, B 60/300/1500/160.
    private static func seedThreeOwners(_ context: ModelContext) throws {
        let rows: [(UUID?, Double, Int, Int, Int)] = [
            (nil, 70, 400, 500, 170),
            (accountA, 80, 450, 1000, 180),
            (accountB, 60, 300, 1500, 160),
        ]
        for (owner, weight, sleep, kcal, height) in rows {
            context.insert(DayLog(date: today, intakeCalories: kcal, sleepMinutes: sleep, weightKg: weight, ownerAccountID: owner))
            context.insert(meal(kcal, day: today, owner: owner))
            context.insert(UserProfile(heightCm: height, ownerAccountID: owner))
        }
        try context.save()
    }

    private struct Observed: Equatable {
        var weight: Double?
        var sleep: Int?
        var mealTotal: Int
        var height: Int?
    }

    private static func observe(_ scope: HealthDataScope, _ context: ModelContext) throws -> Observed {
        let log = DayLogStore.fetch(date: today, scope: scope, modelContext: context)
        return Observed(
            weight: LatestBodyWeightResolver.latestWeightKg(scope: scope, modelContext: context),
            sleep: log?.sleepMinutes,
            mealTotal: NutritionLedger.confirmedTotal(for: today, scope: scope, modelContext: context),
            height: UserProfileStore.profile(for: scope, modelContext: context)?.heightCm
        )
    }

    private static let guestView = Observed(weight: 70, sleep: 400, mealTotal: 500, height: 170)
    private static let aView = Observed(weight: 80, sleep: 450, mealTotal: 1000, height: 180)
    private static let bView = Observed(weight: 60, sleep: 300, mealTotal: 1500, height: 160)
    private static let nothing = Observed(weight: nil, sleep: nil, mealTotal: 0, height: nil)

    // MARK: - Read isolation

    @Test
    func eachScopeReadsOnlyItsOwnHealthData() throws {
        let context = try Self.makeContext()
        try Self.seedThreeOwners(context)

        #expect(try Self.observe(.guest, context) == Self.guestView)
        #expect(try Self.observe(.account(Self.accountA), context) == Self.aView)
        #expect(try Self.observe(.account(Self.accountB), context) == Self.bView)
        #expect(try Self.observe(.undetermined, context) == Self.nothing)
    }

    @Test
    func viewFiltersShowOnlyTheScopesRows() throws {
        let context = try Self.makeContext()
        try Self.seedThreeOwners(context)
        let logs = try context.fetch(FetchDescriptor<DayLog>())
        let meals = try context.fetch(FetchDescriptor<MealEntry>())
        let profiles = try context.fetch(FetchDescriptor<UserProfile>())

        let a = HealthDataScope.account(Self.accountA)
        #expect(a.visible(logs).map(\.weightKg) == [80])
        #expect(a.visible(meals).map(\.kcal) == [1000])
        #expect(UserProfileStore.select(from: profiles, scope: a)?.heightCm == 180)
        #expect(HealthDataScope.undetermined.visible(logs).isEmpty)
        #expect(HealthDataScope.undetermined.visible(meals).isEmpty)
        #expect(UserProfileStore.select(from: profiles, scope: .undetermined) == nil)
        #expect(DayLogStore.recent(days: 7, scope: .undetermined, modelContext: context).isEmpty)
        #expect(DayLogStore.recent(days: 7, scope: .guest, modelContext: context).map(\.weightKg) == [70])
    }

    // MARK: - Account switch

    @Test
    func switchingAccountsNeverMixesHealthData() throws {
        let context = try Self.makeContext()
        try Self.seedThreeOwners(context)
        let steps: [(HealthDataScope, Observed)] = [
            (.guest, Self.guestView),
            (.account(Self.accountA), Self.aView),
            (.guest, Self.guestView),
            (.account(Self.accountB), Self.bView),
            (.account(Self.accountA), Self.aView),
        ]
        for (scope, expected) in steps {
            #expect(try Self.observe(scope, context) == expected, "\(scope)")
        }
        // Switching never rewrites ownership: every row is still where it was.
        let owners = try context.fetch(FetchDescriptor<DayLog>()).map(\.ownerAccountID)
        #expect(Set(owners) == [nil, Self.accountA, Self.accountB])
    }

    @Test
    func weightSignatureChangesAcrossAccountsWithIdenticalRows() throws {
        let context = try Self.makeContext()
        context.insert(DayLog(date: Self.today, weightKg: 70, ownerAccountID: Self.accountA))
        context.insert(DayLog(date: Self.today, weightKg: 70, ownerAccountID: Self.accountB))
        try context.save()
        let logs = try context.fetch(FetchDescriptor<DayLog>())

        let a = LatestBodyWeightResolver.changeSignature(for: logs, scope: .account(Self.accountA))
        let b = LatestBodyWeightResolver.changeSignature(for: logs, scope: .account(Self.accountB))
        #expect(a != b)
    }

    @Test
    func cachedValueIsUnreadableUnderAnotherScope() {
        let cached = HealthScopedValue<Double?>(scope: .account(Self.accountA), value: 80)
        #expect(cached.value(in: .account(Self.accountA)) == .some(80))
        #expect(cached.value(in: .account(Self.accountB)) == nil)
        #expect(cached.value(in: .guest) == nil)
        #expect(cached.value(in: .undetermined) == nil)
    }

    // MARK: - Write isolation

    @Test
    func dayLogCreationTakesTheScopesOwner() throws {
        let context = try Self.makeContext()
        let guest = try #require(DayLogStore.fetchOrCreate(date: Self.today, scope: .guest, modelContext: context))
        let a = try #require(DayLogStore.fetchOrCreate(date: Self.today, scope: .account(Self.accountA), modelContext: context))
        let b = try #require(DayLogStore.fetchOrCreate(date: Self.today, scope: .account(Self.accountB), modelContext: context))
        #expect(guest.ownerAccountID == nil)
        #expect(a.ownerAccountID == Self.accountA)
        #expect(b.ownerAccountID == Self.accountB)
        #expect(DayLogStore.fetchOrCreate(date: Self.today, scope: .undetermined, modelContext: context) == nil)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<DayLog>()).count == 3)

        // Explicit fetch returns the existing row rather than inserting again.
        let again = DayLogStore.fetchOrCreate(date: Self.today, scope: .account(Self.accountA), modelContext: context)
        #expect(again === a)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<DayLog>()).count == 3)
    }

    @Test
    func profileCreationTakesTheScopesOwnerAndOnlyGuestSeedsFromLegacy() throws {
        let context = try Self.makeContext()
        let defaults = UserDefaults(suiteName: "test.healthscope.\(UUID().uuidString)")!
        defaults.set(155, forKey: "settings.heightCm")

        let guest = try #require(UserProfileStore.fetchOrCreateProfile(for: .guest, modelContext: context, legacyDefaults: defaults))
        let a = try #require(UserProfileStore.fetchOrCreateProfile(for: .account(Self.accountA), modelContext: context, legacyDefaults: defaults))
        #expect(guest.ownerAccountID == nil)
        #expect(guest.heightCm == 155)
        #expect(a.ownerAccountID == Self.accountA)
        #expect(a.heightCm == UserProfile().heightCm)
        #expect(UserProfileStore.fetchOrCreateProfile(for: .undetermined, modelContext: context, legacyDefaults: defaults) == nil)
        #expect(UserProfileStore.fetchOrCreateProfile(for: .account(Self.accountA), modelContext: context) === a)
        #expect(try context.fetch(FetchDescriptor<UserProfile>()).count == 2)
    }

    @Test
    func duplicateProfilesResolveDeterministicallyAndAreKept() throws {
        let context = try Self.makeContext()
        let older = UserProfile(heightCm: 150, updatedAt: Date(timeIntervalSince1970: 100), ownerAccountID: Self.accountA)
        let newer = UserProfile(heightCm: 190, updatedAt: Date(timeIntervalSince1970: 200), ownerAccountID: Self.accountA)
        context.insert(older)
        context.insert(newer)
        try context.save()

        #expect(UserProfileStore.profile(for: .account(Self.accountA), modelContext: context) === newer)
        #expect(UserProfileStore.fetchOrCreateProfile(for: .account(Self.accountA), modelContext: context) === newer)
        #expect(try context.fetch(FetchDescriptor<UserProfile>()).count == 2)
    }

    @Test
    func reviewedMealCarriesTheGivenOwner() {
        let meal = ConfirmedMealEntryFactory.make(
            day: Self.today, slot: .lunch, name: "x", kcalText: "300",
            proteinText: "", carbText: "", fatText: "", note: "",
            source: .barcode, ownerAccountID: Self.accountB
        )
        #expect(meal.ownerAccountID == Self.accountB)
    }

    @Test
    func ledgerSumsAndWritesOnlyTheScopesOwnData() throws {
        let context = try Self.makeContext()
        context.insert(DayLog(date: Self.today, intakeCalories: 123, ownerAccountID: nil))
        context.insert(Self.meal(400, day: Self.today, owner: Self.accountA))
        context.insert(Self.meal(900, day: Self.today, owner: Self.accountB))
        context.insert(Self.meal(50, day: Self.today, owner: nil))

        NutritionLedger.syncDayLogIntake(for: Self.today, scope: .account(Self.accountA), modelContext: context)
        try context.save()

        #expect(DayLogStore.fetch(date: Self.today, scope: .account(Self.accountA), modelContext: context)?.intakeCalories == 400)
        #expect(DayLogStore.fetch(date: Self.today, scope: .guest, modelContext: context)?.intakeCalories == 123)
        #expect(DayLogStore.fetch(date: Self.today, scope: .account(Self.accountB), modelContext: context) == nil)

        NutritionLedger.syncDayLogIntake(for: Self.today, scope: .undetermined, modelContext: context)
        #expect(try context.fetch(FetchDescriptor<DayLog>()).count == 2)
    }

    @Test
    func owningScopeFollowsTheRowsOwner() {
        #expect(HealthDataScope.owning(nil) == .guest)
        #expect(HealthDataScope.owning(Self.accountA) == .account(Self.accountA))
    }

    // MARK: - Adoption: domain operations

    @Test
    func adoptionOnlyMovesGuestRows() throws {
        let context = try Self.makeContext()
        let log = DayLog(date: Self.dayX, weightKg: 70, ownerAccountID: Self.accountA)
        let meal = Self.meal(500, day: Self.dayX, owner: Self.accountA)
        let profile = UserProfile(ownerAccountID: Self.accountA)
        context.insert(log); context.insert(meal); context.insert(profile)
        try context.save()

        #expect(log.adopt(into: Self.accountB) == nil)
        #expect(meal.adopt(into: Self.accountB) == nil)
        #expect(profile.adopt(into: Self.accountB) == nil)
        #expect(log.ownerAccountID == Self.accountA)
        #expect(log.scopedDayKey == DayLog.scopedDayKey(ownerAccountID: Self.accountA, date: Self.dayX))
        #expect(meal.ownerAccountID == Self.accountA)
        #expect(profile.ownerAccountID == Self.accountA)

        // Adopting guest data into B never reaches A's rows.
        try HealthDataAdoptionStore().adoptGuestHealthData(for: Self.accountB, in: context)
        #expect(log.ownerAccountID == Self.accountA)
        #expect(meal.ownerAccountID == Self.accountA)
        #expect(profile.ownerAccountID == Self.accountA)
    }

    @Test
    func dayLogAdoptionRekeysWithTheOwner() {
        let log = DayLog(date: Self.dayX)
        let adoption = log.adopt(into: Self.accountA)
        #expect(adoption != nil)
        #expect(log.ownerAccountID == Self.accountA)
        #expect(log.scopedDayKey == DayLog.scopedDayKey(ownerAccountID: Self.accountA, date: Self.dayX))
    }

    // MARK: - Adoption: plain and merged days

    @Test
    func guestDataWithoutConflictsMovesIntoTheAccount() throws {
        try Self.withTempStore { url in
            try Self.open(url) { context in
                context.insert(DayLog(date: Self.dayY, intakeCalories: 500, sleepMinutes: 400, ownerAccountID: nil))
                context.insert(Self.meal(500, day: Self.dayY, owner: nil))
                context.insert(UserProfile(heightCm: 170, ownerAccountID: nil))
                try context.save()

                let summary = try HealthDataAdoptionStore().adoptGuestHealthData(for: Self.accountA, in: context)
                #expect(summary.adoptedLogs == 1)
                #expect(summary.adoptedMeals == 1)
                #expect(summary.adoptedProfile)
                #expect(summary.conflictingDays.isEmpty)
            }
            try Self.open(url) { context in
                let a = HealthDataScope.account(Self.accountA)
                let log = try #require(DayLogStore.fetch(date: Self.dayY, scope: a, modelContext: context))
                #expect(log.sleepMinutes == 400)
                #expect(log.scopedDayKey == DayLog.scopedDayKey(ownerAccountID: Self.accountA, date: Self.dayY))
                #expect(NutritionLedger.confirmedTotal(for: Self.dayY, scope: a, modelContext: context) == 500)
                #expect(UserProfileStore.profile(for: a, modelContext: context)?.heightCm == 170)
                #expect(DayLogStore.fetch(date: Self.dayY, scope: .guest, modelContext: context) == nil)
                #expect(UserProfileStore.profile(for: .guest, modelContext: context) == nil)
            }
        }
    }

    @Test
    func sameDayWithComplementaryFieldsMergesIntoOneAccountLog() throws {
        try Self.withTempStore { url in
            try Self.open(url) { context in
                context.insert(DayLog(date: Self.dayX, sleepMinutes: 400, note: "same", ownerAccountID: nil))
                context.insert(DayLog(date: Self.dayX, weightKg: 80, note: "same", ownerAccountID: Self.accountA))
                try context.save()

                let summary = try HealthDataAdoptionStore().adoptGuestHealthData(for: Self.accountA, in: context)
                #expect(summary.mergedLogs == 1)
                #expect(summary.conflictingDays.isEmpty)
            }
            try Self.open(url) { context in
                let logs = try context.fetch(FetchDescriptor<DayLog>())
                #expect(logs.count == 1)
                let log = try #require(logs.first)
                #expect(log.ownerAccountID == Self.accountA)
                #expect(log.weightKg == 80)
                #expect(log.sleepMinutes == 400)
                #expect(log.note == "same")
            }
        }
    }

    @Test
    func mergedDayRecomputesIntakeFromBothSidesMeals() throws {
        try Self.withTempStore { url in
            try Self.open(url) { context in
                context.insert(DayLog(date: Self.dayX, intakeCalories: 500, ownerAccountID: nil))
                context.insert(Self.meal(500, day: Self.dayX, owner: nil))
                context.insert(DayLog(date: Self.dayX, intakeCalories: 1000, ownerAccountID: Self.accountA))
                context.insert(Self.meal(1000, day: Self.dayX, owner: Self.accountA))
                context.insert(Self.meal(77, day: Self.dayX, owner: nil, status: .pending))
                try context.save()
                try HealthDataAdoptionStore().adoptGuestHealthData(for: Self.accountA, in: context)
            }
            try Self.open(url) { context in
                let logs = try context.fetch(FetchDescriptor<DayLog>())
                #expect(logs.count == 1)
                #expect(logs.first?.intakeCalories == 1500)
                #expect(try context.fetch(FetchDescriptor<MealEntry>()).allSatisfy { $0.ownerAccountID == Self.accountA })
            }
        }
    }

    // MARK: - Adoption: conflicts

    @Test
    func conflictingDayStaysGuestAndTheAccountDayIsUntouched() throws {
        try Self.withTempStore { url in
            try Self.open(url) { context in
                context.insert(DayLog(date: Self.dayX, weightKg: 70, ownerAccountID: nil))
                context.insert(Self.meal(300, day: Self.dayX, owner: nil, status: .pending))
                context.insert(DayLog(date: Self.dayX, weightKg: 80, ownerAccountID: Self.accountA))
                context.insert(DayLog(date: Self.dayY, sleepMinutes: 420, ownerAccountID: nil))
                try context.save()

                let summary = try HealthDataAdoptionStore().adoptGuestHealthData(for: Self.accountA, in: context)
                #expect(summary.conflictingDays == [Self.dayX])
                #expect(summary.adoptedLogs == 1)
            }
            try Self.open(url) { context in
                let a = HealthDataScope.account(Self.accountA)
                #expect(DayLogStore.fetch(date: Self.dayX, scope: a, modelContext: context)?.weightKg == 80)
                #expect(DayLogStore.fetch(date: Self.dayX, scope: .guest, modelContext: context)?.weightKg == 70)
                #expect(DayLogStore.fetch(date: Self.dayY, scope: a, modelContext: context)?.sleepMinutes == 420)
                let meals = try context.fetch(FetchDescriptor<MealEntry>())
                #expect(meals.map(\.ownerAccountID) == [nil])
                #expect(try context.fetch(FetchDescriptor<DayLog>()).count == 3)
            }
        }
    }

    @Test
    func mealsWouldOverwriteAQuickInputIntakeSoTheDayConflicts() throws {
        let context = try Self.makeContext()
        context.insert(Self.meal(600, day: Self.dayX, owner: nil))
        context.insert(DayLog(date: Self.dayX, intakeCalories: 2000, ownerAccountID: Self.accountA))
        try context.save()

        let summary = try HealthDataAdoptionStore().adoptGuestHealthData(for: Self.accountA, in: context)
        #expect(summary.conflictingDays == [Self.dayX])
        #expect(DayLogStore.fetch(date: Self.dayX, scope: .account(Self.accountA), modelContext: context)?.intakeCalories == 2000)
        #expect(try context.fetch(FetchDescriptor<MealEntry>()).first?.ownerAccountID == nil)
    }

    @Test
    func existingAccountProfileWinsAndGuestProfileIsKept() throws {
        try Self.withTempStore { url in
            try Self.open(url) { context in
                context.insert(UserProfile(heightCm: 170, ownerAccountID: nil))
                context.insert(UserProfile(heightCm: 180, ownerAccountID: Self.accountA))
                try context.save()
                let summary = try HealthDataAdoptionStore().adoptGuestHealthData(for: Self.accountA, in: context)
                #expect(!summary.adoptedProfile)
            }
            try Self.open(url) { context in
                #expect(UserProfileStore.profile(for: .account(Self.accountA), modelContext: context)?.heightCm == 180)
                #expect(UserProfileStore.profile(for: .guest, modelContext: context)?.heightCm == 170)
            }
        }
    }

    @Test
    func emptyLogsAloneAreNotGuestHealthData() throws {
        let context = try Self.makeContext()
        let store = HealthDataAdoptionStore()
        context.insert(DayLog(date: Self.today))
        context.insert(UserProfile())
        try context.save()
        #expect(try !store.hasGuestHealthData(in: context))

        context.insert(DayLog(date: Self.dayX, weightKg: 70, ownerAccountID: Self.accountA))
        #expect(try !store.hasGuestHealthData(in: context))

        context.insert(DayLog(date: Self.dayY, sleepMinutes: 300))
        #expect(try store.hasGuestHealthData(in: context))
    }

    // MARK: - Adoption: failure

    @Test
    func failedCommitRestoresEveryRowExactly() throws {
        try Self.withTempStore { url in
            try Self.open(url) { context in
                // Merged day, plain day, meals-only day, and a profile.
                context.insert(DayLog(date: Self.dayX, sleepMinutes: 400, ownerAccountID: nil))
                context.insert(DayLog(date: Self.dayX, weightKg: 80, ownerAccountID: Self.accountA))
                context.insert(DayLog(date: Self.dayY, weightKg: 70, ownerAccountID: nil))
                context.insert(Self.meal(500, day: Self.today, owner: nil))
                context.insert(UserProfile(heightCm: 170, ownerAccountID: nil))
                try context.save()

                let failing = HealthDataAdoptionStore(commit: { _ in throw CommitFailure() })
                #expect(throws: CommitFailure.self) {
                    try failing.adoptGuestHealthData(for: Self.accountA, in: context)
                }

                Self.expectUnadopted(context)
                // The context is still usable and saves nothing of the attempt.
                try context.save()
                Self.expectUnadopted(context)
            }
            try Self.open(url) { context in
                Self.expectUnadopted(context)
            }
        }
    }

    private static func expectUnadopted(_ context: ModelContext) {
        let a = HealthDataScope.account(accountA)
        let guestX = DayLogStore.fetch(date: dayX, scope: .guest, modelContext: context)
        #expect(guestX?.sleepMinutes == 400)
        #expect(guestX?.scopedDayKey == DayLog.scopedDayKey(ownerAccountID: nil, date: dayX))
        let aX = DayLogStore.fetch(date: dayX, scope: a, modelContext: context)
        #expect(aX?.weightKg == 80)
        #expect(aX?.sleepMinutes == nil)
        let guestY = DayLogStore.fetch(date: dayY, scope: .guest, modelContext: context)
        #expect(guestY?.weightKg == 70)
        #expect(guestY?.scopedDayKey == DayLog.scopedDayKey(ownerAccountID: nil, date: dayY))
        #expect(DayLogStore.fetch(date: dayY, scope: a, modelContext: context) == nil)
        #expect(DayLogStore.fetch(date: today, scope: a, modelContext: context) == nil)
        #expect(NutritionLedger.confirmedTotal(for: today, scope: .guest, modelContext: context) == 500)
        #expect(UserProfileStore.profile(for: .guest, modelContext: context)?.heightCm == 170)
        #expect(UserProfileStore.profile(for: a, modelContext: context) == nil)
        #expect((try? context.fetch(FetchDescriptor<DayLog>()).count) == 3)
    }
}
