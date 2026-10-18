//
//  AccountLocalDataCleanupTests.swift
//  Pulse CueTests
//
//  Deleting account A removes every record A owns on this device — workouts,
//  set results, day logs (weight, sleep, intake, exercise), meals, profile,
//  sync bookkeeping, favorites, targets, the runner resume point, adoption
//  answers — and leaves Guest and account B byte-for-byte as they were. A
//  failed save removes nothing, stays pending, and a later run finishes it.
//  Only a confirmed deletion (200/202) triggers it; logout never does.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct AccountLocalDataCleanupTests {

    private static let accountA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-00000000000A")!
    private static let accountB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-00000000000B")!
    private static let dayX = DateUtils.startOfDay(Date(timeIntervalSinceReferenceDate: 800_000_000))

    private struct CommitFailure: Error {}

    // MARK: - Fixture

    private static func makeDefaults(_ label: String = #function) -> UserDefaults {
        let suite = "AccountLocalDataCleanupTests.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static func withTempStore(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsecue-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.appendingPathComponent("store.sqlite"))
    }

    /// A fresh container on `url` each call — a real reopen.
    private static func container(_ url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: PulseCueSchemaV8.self)
        return try ModelContainer(
            for: schema,
            migrationPlan: PulseCueMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: url)
        )
    }

    private static func label(_ owner: UUID?) -> String {
        owner?.uuidString.prefix(1).description ?? "G"
    }

    /// The same full set of records for Guest, A and B, each with values that
    /// say whose they are.
    private static func seedRows(_ context: ModelContext) throws {
        for (index, owner) in [nil, accountA, accountB].enumerated() {
            let name = label(owner)
            let session = Session(routineId: UUID(), dayDate: dayX, ownerAccountID: owner)
            context.insert(session)
            context.insert(StepResult(sessionId: session.id, stepId: UUID(), setIndex: index, done: true, ownerAccountID: owner))
            context.insert(DayLog(
                date: dayX,
                intakeCalories: 2000 + index,
                exerciseCalories: 300 + index,
                sleepMinutes: 400 + index,
                weightKg: 60 + Double(index),
                note: name,
                ownerAccountID: owner
            ))
            context.insert(MealEntry(
                dayDate: dayX, slot: .lunch, name: "meal-\(name)", kcal: 500 + index,
                proteinGrams: 20 + index, carbGrams: 50, fatGrams: 10,
                status: .confirmed, source: .manual, ownerAccountID: owner
            ))
            context.insert(UserProfile(heightCm: 160 + index, ownerAccountID: owner))
        }
        for account in [accountA, accountB] {
            let entity = UUID()
            context.insert(SyncOutboxItem(
                identity: SyncOutboxItem.identity(accountID: account, entityType: .session, entityID: entity),
                accountID: account, entityType: .session, entityID: entity, mutation: .upsert
            ))
            let gone = UUID()
            context.insert(SyncTombstone(
                identity: SyncOutboxItem.identity(accountID: account, entityType: .session, entityID: gone),
                accountID: account, entityType: .session, entityID: gone
            ))
            context.insert(SyncCursor(accountID: account, lastPulledSequence: 7))
        }
        try context.save()
    }

    private static let favoritesKey = FavoriteMealTemplateStore.defaultStorageKey
    private static let targetsKey = HealthTargetStore.defaultStorageKey

    /// Every scoped slot for Guest, A and B, the legacy keys, device settings,
    /// adoption answers for both accounts, and A as the last confirmed account.
    private static func seedDefaults(_ defaults: UserDefaults) {
        for scope in [HealthDataScope.guest, .account(accountA), .account(accountB)] {
            let tag = Data(String(describing: scope).utf8)
            defaults.set(tag, forKey: HealthScopedDefaults.key(favoritesKey, for: scope)!)
            defaults.set(tag, forKey: HealthScopedDefaults.key(targetsKey, for: scope)!)
            defaults.set(tag, forKey: RunnerPersistence.key(for: scope)!)
        }
        defaults.set(Data("legacy".utf8), forKey: favoritesKey)
        defaults.set(Data("legacy".utf8), forKey: targetsKey)
        defaults.set(175, forKey: "settings.heightCm")
        defaults.set(true, forKey: "settings.hasCompletedOnboarding")
        let both = [accountA, accountB].map(\.uuidString).sorted().joined(separator: ",")
        defaults.set(both, forKey: GuestAdoptionConsent.workoutAnsweredKey)
        defaults.set(both, forKey: GuestAdoptionConsent.healthAnsweredKey)
        defaults.set(accountA.uuidString, forKey: WorkoutDataScopeResolver.lastConfirmedAccountKey)
    }

    /// Everything one owner has, as values — equal snapshots mean nothing of
    /// theirs was deleted or changed.
    private static func rows(of owner: UUID?, _ context: ModelContext) throws -> [String] {
        var out: [String] = []
        out += try context.fetch(FetchDescriptor<Session>()).filter { $0.ownerAccountID == owner }
            .map { "session \($0.id) \($0.routineId) \($0.dayDate)" }
        out += try context.fetch(FetchDescriptor<StepResult>()).filter { $0.ownerAccountID == owner }
            .map { "result \($0.id) \($0.sessionId) \($0.setIndex) \($0.done)" }
        out += try context.fetch(FetchDescriptor<DayLog>()).filter { $0.ownerAccountID == owner }
            .map { log -> String in
                let values = [log.intakeCalories, log.exerciseCalories, log.sleepMinutes].map { String(describing: $0) }
                return "log \(log.date) \(values) \(String(describing: log.weightKg)) \(log.note ?? "")"
            }
        out += try context.fetch(FetchDescriptor<MealEntry>()).filter { $0.ownerAccountID == owner }
            .map { "meal \($0.id) \($0.name) \($0.kcal) \(String(describing: $0.proteinGrams))" }
        out += try context.fetch(FetchDescriptor<UserProfile>()).filter { $0.ownerAccountID == owner }
            .map { "profile \($0.heightCm)" }
        if let owner {
            out += try context.fetch(FetchDescriptor<SyncOutboxItem>()).filter { $0.accountID == owner }
                .map { "outbox \($0.identity) \($0.mutation)" }
            out += try context.fetch(FetchDescriptor<SyncTombstone>()).filter { $0.accountID == owner }
                .map { "tombstone \($0.identity)" }
            out += try context.fetch(FetchDescriptor<SyncCursor>()).filter { $0.accountID == owner }
                .map { "cursor \($0.lastPulledSequence)" }
        }
        return out.sorted()
    }

    private static func defaultsSnapshot(_ defaults: UserDefaults, keys: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: keys.map { ($0, String(describing: defaults.object(forKey: $0))) })
    }

    private static func keys(of scope: HealthDataScope) -> [String] {
        [
            HealthScopedDefaults.key(favoritesKey, for: scope)!,
            HealthScopedDefaults.key(targetsKey, for: scope)!,
            RunnerPersistence.key(for: scope)!,
        ]
    }

    /// Keys that are nobody's but Guest's, B's or the device's.
    private static let survivingKeys: [String] =
        keys(of: .guest) + keys(of: .account(accountB))
        + [favoritesKey, targetsKey, "settings.heightCm", "settings.hasCompletedOnboarding"]

    private static func answered(_ defaults: UserDefaults) -> GuestAdoptionConsent.Answers {
        .init(
            workoutRaw: defaults.string(forKey: GuestAdoptionConsent.workoutAnsweredKey) ?? "",
            healthRaw: defaults.string(forKey: GuestAdoptionConsent.healthAnsweredKey) ?? ""
        )
    }

    // MARK: - Success

    @Test
    func removesEverythingAOwnsAndLeavesGuestAndBExactlyAsTheyWere() throws {
        try Self.withTempStore { url in
            let defaults = Self.makeDefaults()
            Self.seedDefaults(defaults)
            let container = try Self.container(url)
            try Self.seedRows(ModelContext(container))

            let seeded = ModelContext(container)
            let guestBefore = try Self.rows(of: nil, seeded)
            let bBefore = try Self.rows(of: Self.accountB, seeded)
            #expect(guestBefore.count == 5)
            #expect(bBefore.count == 8)
            #expect(try Self.rows(of: Self.accountA, seeded).count == 8)
            let defaultsBefore = Self.defaultsSnapshot(defaults, keys: Self.survivingKeys)

            var saves = 0
            let cleanup = AccountLocalDataCleanup(container: container, defaults: defaults, commit: { saves += 1; try $0.save() })
            try cleanup.run(for: Self.accountA)
            #expect(saves == 1)

            let reopened = ModelContext(try Self.container(url))
            #expect(try Self.rows(of: Self.accountA, reopened).isEmpty)
            #expect(try Self.rows(of: nil, reopened) == guestBefore)
            #expect(try Self.rows(of: Self.accountB, reopened) == bBefore)

            for key in Self.keys(of: .account(Self.accountA)) {
                #expect(defaults.object(forKey: key) == nil, "\(key)")
            }
            #expect(Self.defaultsSnapshot(defaults, keys: Self.survivingKeys) == defaultsBefore)
            let answers = Self.answered(defaults)
            #expect(!answers.answeredWorkout(Self.accountA))
            #expect(!answers.answeredHealth(Self.accountA))
            #expect(answers.answeredWorkout(Self.accountB))
            #expect(answers.answeredHealth(Self.accountB))
            #expect(defaults.object(forKey: WorkoutDataScopeResolver.lastConfirmedAccountKey) == nil)
            #expect(cleanup.pendingIDs().isEmpty)
        }
    }

    @Test
    func anotherAccountsLastConfirmedIdIsKept() throws {
        let defaults = Self.makeDefaults()
        defaults.set(Self.accountB.uuidString, forKey: WorkoutDataScopeResolver.lastConfirmedAccountKey)
        try Self.withTempStore { url in
            try AccountLocalDataCleanup(container: try Self.container(url), defaults: defaults).run(for: Self.accountA)
        }
        #expect(defaults.string(forKey: WorkoutDataScopeResolver.lastConfirmedAccountKey) == Self.accountB.uuidString)
    }

    // MARK: - Failure

    @Test
    func failedSaveRemovesNothingStaysPendingAndALaterRunFinishes() throws {
        try Self.withTempStore { url in
            let defaults = Self.makeDefaults()
            Self.seedDefaults(defaults)
            let container = try Self.container(url)
            try Self.seedRows(ModelContext(container))
            let before = ModelContext(container)
            let aBefore = try Self.rows(of: Self.accountA, before)
            let guestBefore = try Self.rows(of: nil, before)
            let bBefore = try Self.rows(of: Self.accountB, before)
            let allKeys = Self.survivingKeys + Self.keys(of: .account(Self.accountA)) + [
                GuestAdoptionConsent.workoutAnsweredKey,
                GuestAdoptionConsent.healthAnsweredKey,
                WorkoutDataScopeResolver.lastConfirmedAccountKey,
            ]
            let defaultsBefore = Self.defaultsSnapshot(defaults, keys: allKeys)

            var saves = 0
            let failing = AccountLocalDataCleanup(container: container, defaults: defaults, commit: { context in
                saves += 1
                // Everything is staged in the dedicated context at this point.
                #expect(context.deletedModelsArray.count == 8)
                throw CommitFailure()
            })
            #expect(throws: CommitFailure.self) { try failing.run(for: Self.accountA) }
            #expect(saves == 1)

            let reopened = ModelContext(try Self.container(url))
            #expect(try Self.rows(of: Self.accountA, reopened) == aBefore)
            #expect(try Self.rows(of: nil, reopened) == guestBefore)
            #expect(try Self.rows(of: Self.accountB, reopened) == bBefore)
            #expect(Self.defaultsSnapshot(defaults, keys: allKeys) == defaultsBefore)
            #expect(failing.pendingIDs() == [Self.accountA])

            // The next launch.
            AccountLocalDataCleanup(container: try Self.container(url), defaults: defaults).resumePending()
            let finished = ModelContext(try Self.container(url))
            #expect(try Self.rows(of: Self.accountA, finished).isEmpty)
            #expect(try Self.rows(of: nil, finished) == guestBefore)
            #expect(try Self.rows(of: Self.accountB, finished) == bBefore)
            for key in Self.keys(of: .account(Self.accountA)) {
                #expect(defaults.object(forKey: key) == nil, "\(key)")
            }
            #expect(!Self.answered(defaults).answeredWorkout(Self.accountA))
            #expect(Self.answered(defaults).answeredWorkout(Self.accountB))
            #expect(failing.pendingIDs().isEmpty)
        }
    }

    @Test
    func failedSaveLeavesTheAppsOwnContextUntouched() throws {
        try Self.withTempStore { url in
            let defaults = Self.makeDefaults()
            let container = try Self.container(url)
            try Self.seedRows(ModelContext(container))
            let main = container.mainContext
            main.insert(DayLog(date: Self.dayX.addingTimeInterval(86_400), sleepMinutes: 1, ownerAccountID: nil))
            #expect(main.hasChanges)

            let failing = AccountLocalDataCleanup(container: container, defaults: defaults, commit: { _ in throw CommitFailure() })
            #expect(throws: CommitFailure.self) { try failing.run(for: Self.accountA) }
            #expect(main.hasChanges)
            #expect(try main.fetch(FetchDescriptor<DayLog>()).count == 4)
        }
    }

    // MARK: - Triggers

    private static func authenticatedStore(
        deleteResult: Result<AccountDeletionOutcome, Error>
    ) async -> (ServerAccountStore, StubAccountAPI) {
        let api = StubAccountAPI()
        api.profileResult = .success(ServerAccountProfile(
            user: .init(id: accountA.uuidString, state: "active", displayName: "A", createdAt: 1),
            linkedProviders: [],
            session: .init(expiresAt: 1_800_000_000)
        ))
        api.deleteResult = deleteResult
        let store = ServerAccountStore(
            api: api,
            tokenStore: InMemoryServerSessionTokenStore(token: "session-token"),
            deviceName: "iPhone"
        )
        await store.restore()
        return (store, api)
    }

    private static func seededA(_ url: URL, _ defaults: UserDefaults) throws -> ModelContainer {
        Self.seedDefaults(defaults)
        let container = try Self.container(url)
        try Self.seedRows(ModelContext(container))
        return container
    }

    @Test(arguments: [AccountDeletionOutcome.deleted, .pending])
    func aConfirmedDeletionCleansUpTheDeletedAccount(_ outcome: AccountDeletionOutcome) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pulsecue-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("store.sqlite")
        let defaults = Self.makeDefaults()
        let container = try Self.seededA(url, defaults)
        let guestBefore = try Self.rows(of: nil, ModelContext(container))
        let bBefore = try Self.rows(of: Self.accountB, ModelContext(container))

        let (store, _) = await Self.authenticatedStore(deleteResult: .success(outcome))
        #expect(store.state.isAuthenticated)
        let section = ServerAccountSettingsSection(
            store: store,
            localDataCleanup: AccountLocalDataCleanup(container: container, defaults: defaults)
        )
        await section.deleteAccount()

        let after = ModelContext(try Self.container(url))
        #expect(try Self.rows(of: Self.accountA, after).isEmpty)
        #expect(try Self.rows(of: nil, after) == guestBefore)
        #expect(try Self.rows(of: Self.accountB, after) == bBefore)
        #expect(defaults.object(forKey: Self.keys(of: .account(Self.accountA))[0]) == nil)
    }

    @Test(arguments: [AccountAPIError.unavailable, AccountAPIError.invalidCredentials])
    func anUnconfirmedDeletionDeletesNothing(_ error: AccountAPIError) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pulsecue-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("store.sqlite")
        let defaults = Self.makeDefaults()
        let container = try Self.seededA(url, defaults)
        let aBefore = try Self.rows(of: Self.accountA, ModelContext(container))
        let aKeys = Self.defaultsSnapshot(defaults, keys: Self.keys(of: .account(Self.accountA)))

        let (store, _) = await Self.authenticatedStore(deleteResult: .failure(error))
        let section = ServerAccountSettingsSection(
            store: store,
            localDataCleanup: AccountLocalDataCleanup(container: container, defaults: defaults)
        )
        await section.deleteAccount()

        #expect(try Self.rows(of: Self.accountA, ModelContext(try Self.container(url))) == aBefore)
        #expect(Self.defaultsSnapshot(defaults, keys: Self.keys(of: .account(Self.accountA))) == aKeys)
        #expect(AccountLocalDataCleanup(container: container, defaults: defaults).pendingIDs().isEmpty)
    }

    @Test
    func logoutDeletesNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pulsecue-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("store.sqlite")
        let defaults = Self.makeDefaults()
        let container = try Self.seededA(url, defaults)
        let aBefore = try Self.rows(of: Self.accountA, ModelContext(container))

        let (store, _) = await Self.authenticatedStore(deleteResult: .success(.deleted))
        _ = await store.logout()

        #expect(try Self.rows(of: Self.accountA, ModelContext(try Self.container(url))) == aBefore)
        #expect(defaults.object(forKey: Self.keys(of: .account(Self.accountA))[0]) != nil)
    }
}
