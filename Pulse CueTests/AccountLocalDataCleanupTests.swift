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

    /// A commit that fails `step` and saves every other.
    private static func failing(
        _ step: AccountLocalDataCleanup.Commit
    ) -> (ModelContext, AccountLocalDataCleanup.Commit) throws -> Void {
        { context, current in
            if current == step { throw CommitFailure() }
            try context.save()
        }
    }

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
        let schema = Schema(versionedSchema: PulseCueSchemaV9.self)
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

    /// Everything one owner has, as values — every stored property, so equal
    /// snapshots mean nothing of theirs was deleted or changed.
    private static func rows(of owner: UUID?, _ context: ModelContext) throws -> [String] {
        var out: [String] = []
        out += try context.fetch(FetchDescriptor<Session>()).filter { $0.ownerAccountID == owner }
            .map { row in
                "session \(row.id) \(row.routineId) \(row.dayDate) \(row.startedAt) \(String(describing: row.endedAt)) "
                    + "\(row.status) \(row.totalSeconds)"
            }
        out += try context.fetch(FetchDescriptor<StepResult>()).filter { $0.ownerAccountID == owner }
            .map { row in
                "result \(row.id) \(row.sessionId) \(row.stepId) \(row.setIndex) \(row.done) "
                    + "\(String(describing: row.actualReps)) \(String(describing: row.memo))"
            }
        out += try context.fetch(FetchDescriptor<DayLog>()).filter { $0.ownerAccountID == owner }
            .map { log -> String in
                let values = [log.intakeCalories, log.exerciseCalories, log.sleepMinutes].map { String(describing: $0) }
                return "log \(log.date) \(values) \(String(describing: log.weightKg)) \(String(describing: log.note)) "
                    + "\(String(describing: log.scopedDayKey))"
            }
        out += try context.fetch(FetchDescriptor<MealEntry>()).filter { $0.ownerAccountID == owner }
            .map { meal -> String in
                let grams = [meal.proteinGrams, meal.carbGrams, meal.fatGrams].map { String(describing: $0) }
                return "meal \(meal.id) \(meal.dayDate) \(meal.slotRaw) \(meal.name) \(meal.kcal) \(grams) "
                    + "\(meal.statusRaw) \(meal.sourceRaw) \(String(describing: meal.note)) \(meal.createdAt)"
            }
        out += try context.fetch(FetchDescriptor<UserProfile>()).filter { $0.ownerAccountID == owner }
            .map { profile in
                "profile \(profile.id) \(profile.heightCm) \(profile.ageYears) \(profile.biologicalSexRaw) "
                    + "\(profile.activityFactorRaw) \(profile.goalWeightKg) \(profile.weeklyChangeKg) \(profile.updatedAt)"
            }
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

    /// Records with no owner at all — nothing proves they were A's.
    private static func seedOwnerless(_ context: ModelContext) throws {
        context.insert(Routine(name: "routine", isPinned: true))
        context.insert(Gym(name: "gym", officialUrl: "https://example.com", isActive: true))
        try context.save()
    }

    private static func ownerless(_ context: ModelContext) throws -> [String] {
        let routines = try context.fetch(FetchDescriptor<Routine>()).map { row in
            "routine \(row.id) \(row.name) \(row.createdAt) \(row.updatedAt) \(row.isPinned) \(String(describing: row.storedOrigin))"
        }
        let gyms = try context.fetch(FetchDescriptor<Gym>()).map { row in
            "gym \(row.id) \(row.name) \(String(describing: row.officialUrl)) \(row.isActive) \(row.createdAt) \(row.updatedAt)"
        }
        return (routines + gyms).sorted()
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
            try Self.seedOwnerless(ModelContext(container))

            let seeded = ModelContext(container)
            let ownerlessBefore = try Self.ownerless(seeded)
            #expect(ownerlessBefore.count == 2)
            let guestBefore = try Self.rows(of: nil, seeded)
            let bBefore = try Self.rows(of: Self.accountB, seeded)
            #expect(guestBefore.count == 5)
            #expect(bBefore.count == 8)
            #expect(try Self.rows(of: Self.accountA, seeded).count == 8)
            let defaultsBefore = Self.defaultsSnapshot(defaults, keys: Self.survivingKeys)

            var saves: [AccountLocalDataCleanup.Commit] = []
            let cleanup = AccountLocalDataCleanup(container: container, defaults: defaults, commit: { context, step in
                saves.append(step)
                try context.save()
            })
            try cleanup.run(for: Self.accountA)
            // The marker is its own first and last commit, never part of the rows'.
            #expect(saves == [.recordMarker, .deleteRows, .removeMarker])

            let reopened = ModelContext(try Self.container(url))
            #expect(try Self.rows(of: Self.accountA, reopened).isEmpty)
            #expect(try Self.rows(of: nil, reopened) == guestBefore)
            #expect(try Self.rows(of: Self.accountB, reopened) == bBefore)
            #expect(try Self.ownerless(reopened) == ownerlessBefore)

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
            #expect(try cleanup.pendingIDs().isEmpty)
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

            var saves: [AccountLocalDataCleanup.Commit] = []
            let failing = AccountLocalDataCleanup(container: container, defaults: defaults, commit: { context, step in
                saves.append(step)
                guard step == .deleteRows else { return try context.save() }
                // Everything is staged in the dedicated context at this point,
                // and the marker is not among it.
                #expect(context.deletedModelsArray.count == 8)
                #expect(!context.deletedModelsArray.contains { $0 is PendingAccountLocalCleanup })
                throw CommitFailure()
            })
            #expect(throws: CommitFailure.self) { try failing.run(for: Self.accountA) }
            #expect(saves == [.recordMarker, .deleteRows])

            let reopened = ModelContext(try Self.container(url))
            #expect(try Self.rows(of: Self.accountA, reopened) == aBefore)
            #expect(try Self.rows(of: nil, reopened) == guestBefore)
            #expect(try Self.rows(of: Self.accountB, reopened) == bBefore)
            #expect(Self.defaultsSnapshot(defaults, keys: allKeys) == defaultsBefore)
            #expect(try failing.pendingIDs() == [Self.accountA])

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
            #expect(try failing.pendingIDs().isEmpty)
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

            let failing = AccountLocalDataCleanup(container: container, defaults: defaults, commit: Self.failing(.deleteRows))
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
        #expect(try AccountLocalDataCleanup(container: container, defaults: defaults).pendingIDs().isEmpty)
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

    // MARK: - Unsaved rows in the main context

    @Test
    func theMainContextsUnsavedRowsOfANeverComeBackAndNobodyElsesAreLost() throws {
        try Self.withTempStore { url in
            let defaults = Self.makeDefaults()
            let container = try Self.container(url)
            try Self.seedRows(ModelContext(container))
            let main = container.mainContext
            main.autosaveEnabled = false
            let dayY = Self.dayX.addingTimeInterval(86_400)

            // A: unsaved inserts of every owned type, and an unsaved edit of a saved row.
            main.insert(Session(routineId: UUID(), dayDate: dayY, ownerAccountID: Self.accountA))
            main.insert(StepResult(sessionId: UUID(), stepId: UUID(), setIndex: 9, done: true, ownerAccountID: Self.accountA))
            main.insert(DayLog(date: dayY, sleepMinutes: 1, ownerAccountID: Self.accountA))
            main.insert(MealEntry(
                dayDate: dayY, slot: .dinner, name: "unsaved-A", kcal: 1,
                status: .confirmed, source: .manual, ownerAccountID: Self.accountA
            ))
            let savedA = try main.fetch(FetchDescriptor<MealEntry>()).first { $0.ownerAccountID == Self.accountA }!
            savedA.name = "edited-A"
            // Guest and B: an unsaved insert and an unsaved edit each.
            main.insert(DayLog(date: dayY, sleepMinutes: 2, ownerAccountID: nil))
            main.insert(DayLog(date: dayY, sleepMinutes: 3, ownerAccountID: Self.accountB))
            let logs = try main.fetch(FetchDescriptor<DayLog>())
            logs.first { $0.ownerAccountID == nil && $0.date == Self.dayX }!.note = "edited-G"
            logs.first { $0.ownerAccountID == Self.accountB && $0.date == Self.dayX }!.note = "edited-B"
            // A guest row whose unsaved edit hands it to A is still Guest's on disk.
            let handedOver = try main.fetch(FetchDescriptor<Session>()).first { $0.ownerAccountID == nil }!
            let handedOverID = handedOver.id
            handedOver.ownerAccountID = Self.accountA

            try AccountLocalDataCleanup(container: container, defaults: defaults, mainContext: main).run(for: Self.accountA)
            // The app's next save — the moment a resurrection would happen.
            try main.save()

            let reopened = ModelContext(try Self.container(url))
            let aAfter = try Self.rows(of: Self.accountA, reopened)
            #expect(aAfter.allSatisfy { $0.contains(handedOverID.uuidString) }, "\(aAfter)")
            #expect(aAfter.count == 1)
            let logsAfter = try reopened.fetch(FetchDescriptor<DayLog>())
            #expect(logsAfter.contains { $0.ownerAccountID == nil && $0.sleepMinutes == 2 })
            #expect(logsAfter.contains { $0.ownerAccountID == Self.accountB && $0.sleepMinutes == 3 })
            #expect(logsAfter.contains { $0.ownerAccountID == nil && $0.note == "edited-G" })
            #expect(logsAfter.contains { $0.ownerAccountID == Self.accountB && $0.note == "edited-B" })
            #expect(try Self.rows(of: nil, reopened).count == 5)
            #expect(try Self.rows(of: Self.accountB, reopened).count == 9)
        }
    }

    @Test
    func aFailedSaveLeavesTheMainContextsCopiesOfAForItsOwnSave() throws {
        try Self.withTempStore { url in
            let defaults = Self.makeDefaults()
            let container = try Self.container(url)
            try Self.seedRows(ModelContext(container))
            let main = container.mainContext
            main.autosaveEnabled = false
            let savedA = try main.fetch(FetchDescriptor<MealEntry>()).first { $0.ownerAccountID == Self.accountA }!
            savedA.name = "edited-A"

            let failing = AccountLocalDataCleanup(
                container: container, defaults: defaults, mainContext: main, commit: Self.failing(.deleteRows)
            )
            #expect(throws: CommitFailure.self) { try failing.run(for: Self.accountA) }
            try main.save()

            // Nothing was committed, so the main context's next save must not
            // have removed A's rows either; the pending retry does that.
            let reopened = ModelContext(try Self.container(url))
            let aAfter = try Self.rows(of: Self.accountA, reopened)
            #expect(aAfter.count == 8)
            #expect(aAfter.contains { $0.contains("edited-A") })
            #expect(try failing.pendingIDs() == [Self.accountA])
        }
    }

    // MARK: - Crash matrix around a confirmed deletion
    //
    // A crash leaves only what is on disk. Each test builds that state — by
    // stopping the real code at the point, or by leaving the persisted state
    // that point leaves — and then runs the next launch from a fresh container.

    private struct Crash: Error {}

    private static func tempURL() throws -> (URL, () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pulsecue-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.appendingPathComponent("store.sqlite"), { try? FileManager.default.removeItem(at: dir) })
    }

    /// A store wired the way the app wires it — confirmed deletions recorded
    /// in `container` — with the token store returned so a test can see
    /// whether the session survived. `record` replaces the recording.
    private static func recordingStore(
        deleteResult: Result<AccountDeletionOutcome, Error>,
        container: ModelContainer,
        record: ((String) throws -> Void)? = nil
    ) async -> (ServerAccountStore, InMemoryServerSessionTokenStore, StubAccountAPI) {
        let api = StubAccountAPI()
        api.profileResult = .success(ServerAccountProfile(
            user: .init(id: accountA.uuidString, state: "active", displayName: "A", createdAt: 1),
            linkedProviders: [],
            session: .init(expiresAt: 1_800_000_000)
        ))
        api.deleteResult = deleteResult
        let tokens = InMemoryServerSessionTokenStore(token: "session-token")
        let store = ServerAccountStore(
            api: api,
            tokenStore: tokens,
            deviceName: "iPhone",
            recordConfirmedDeletion: record ?? { try AccountLocalDataCleanup(container: container).recordConfirmedDeletion(of: $0) }
        )
        await store.restore()
        return (store, tokens, api)
    }

    private static func hasToken(_ tokens: InMemoryServerSessionTokenStore) -> Bool {
        if case .token = tokens.read() { return true }
        return false
    }

    /// The next launch: a fresh container on the same file, then resume.
    private static func relaunch(_ url: URL, _ defaults: UserDefaults) throws {
        AccountLocalDataCleanup(container: try container(url), defaults: defaults).resumePending()
    }

    private static func expectAGoneAndOthersKept(
        _ url: URL, _ defaults: UserDefaults, guest: [String], b: [String]
    ) throws {
        let after = ModelContext(try container(url))
        #expect(try rows(of: accountA, after).isEmpty)
        #expect(try rows(of: nil, after) == guest)
        #expect(try rows(of: accountB, after) == b)
        for key in keys(of: .account(accountA)) {
            #expect(defaults.object(forKey: key) == nil, "\(key)")
        }
        #expect(answered(defaults).answeredWorkout(accountB))
        #expect(try AccountLocalDataCleanup(container: try container(url), defaults: defaults).pendingIDs().isEmpty)
    }

    // 1. / D: 200/202 → marker saved → only then is the session cleared.
    @Test(arguments: [AccountDeletionOutcome.deleted, .pending])
    func theMarkerIsSavedBeforeTheSessionIsCleared(_ outcome: AccountDeletionOutcome) async throws {
        let (url, cleanup) = try Self.tempURL()
        defer { cleanup() }
        let container = try Self.container(url)
        var tokenWhenSaved: Bool?
        var tokens: InMemoryServerSessionTokenStore?
        let (store, held, _) = await Self.recordingStore(deleteResult: .success(outcome), container: container) { id in
            try AccountLocalDataCleanup(container: container).recordConfirmedDeletion(of: id)
            // Saved: visible to a fresh container, i.e. on disk.
            #expect(try AccountLocalDataCleanup(container: try Self.container(url)).pendingIDs() == [Self.accountA])
            tokenWhenSaved = tokens.map(Self.hasToken)
        }
        tokens = held
        #expect(await store.deleteAccount() == (outcome == .pending ? .pending : .deleted))
        #expect(tokenWhenSaved == true)
        #expect(!Self.hasToken(held))
        #expect(try AccountLocalDataCleanup(container: try Self.container(url)).pendingIDs() == [Self.accountA])
    }

    // 2. / C / 7: the marker save fails → the session stays, nothing is claimed.
    @Test
    func aFailedMarkerSaveKeepsTheSessionAndClaimsNothing() async throws {
        let (url, cleanup) = try Self.tempURL()
        defer { cleanup() }
        let defaults = Self.makeDefaults()
        let container = try Self.seededA(url, defaults)
        let aBefore = try Self.rows(of: Self.accountA, ModelContext(container))
        let failingRecord = AccountLocalDataCleanup(container: container, defaults: defaults, commit: Self.failing(.recordMarker))
        let (store, tokens, _) = await Self.recordingStore(deleteResult: .success(.deleted), container: container) {
            try failingRecord.recordConfirmedDeletion(of: $0)
        }

        let section = ServerAccountSettingsSection(
            store: store,
            localDataCleanup: AccountLocalDataCleanup(container: container, defaults: defaults)
        )
        await section.deleteAccount()
        #expect(Self.hasToken(tokens))
        #expect(store.state.isAuthenticated)

        try Self.relaunch(url, defaults)
        #expect(try AccountLocalDataCleanup(container: try Self.container(url)).pendingIDs().isEmpty)
        #expect(try Self.rows(of: Self.accountA, ModelContext(try Self.container(url))) == aBefore)
        #expect(defaults.object(forKey: Self.keys(of: .account(Self.accountA))[0]) != nil)
    }

    @Test
    func aFailedMarkerSaveIsReportedAsNotConfirmed() async throws {
        let (url, cleanup) = try Self.tempURL()
        defer { cleanup() }
        let (store, _, _) = await Self.recordingStore(deleteResult: .success(.deleted), container: try Self.container(url)) { _ in
            throw CommitFailure()
        }
        #expect(await store.deleteAccount() == .notConfirmed(.confirmationNotRecorded))
    }

    // 3. / D: marker saved, crash before the session is cleared.
    @Test
    func aCrashAfterTheMarkerSaveIsFinishedAtTheNextLaunch() async throws {
        let (url, cleanup) = try Self.tempURL()
        defer { cleanup() }
        let defaults = Self.makeDefaults()
        let container = try Self.seededA(url, defaults)
        let guestBefore = try Self.rows(of: nil, ModelContext(container))
        let bBefore = try Self.rows(of: Self.accountB, ModelContext(container))
        let (store, tokens, _) = await Self.recordingStore(deleteResult: .success(.deleted), container: container) {
            try AccountLocalDataCleanup(container: container).recordConfirmedDeletion(of: $0)
            throw Crash()
        }
        _ = await store.deleteAccount()
        #expect(Self.hasToken(tokens))

        try Self.relaunch(url, defaults)
        try Self.expectAGoneAndOthersKept(url, defaults, guest: guestBefore, b: bBefore)
    }

    // E: session cleared, crash before any cleanup.
    @Test(arguments: [AccountDeletionOutcome.deleted, .pending])
    func aCrashAfterTheSessionIsClearedIsFinishedAtTheNextLaunch(_ outcome: AccountDeletionOutcome) async throws {
        let (url, cleanup) = try Self.tempURL()
        defer { cleanup() }
        let defaults = Self.makeDefaults()
        let container = try Self.seededA(url, defaults)
        let guestBefore = try Self.rows(of: nil, ModelContext(container))
        let bBefore = try Self.rows(of: Self.accountB, ModelContext(container))

        // The store on its own: the UI never gets to run the cleanup.
        let (store, tokens, _) = await Self.recordingStore(deleteResult: .success(outcome), container: container)
        _ = await store.deleteAccount()
        #expect(!Self.hasToken(tokens))
        #expect(try Self.rows(of: Self.accountA, ModelContext(try Self.container(url))).count == 8)

        try Self.relaunch(url, defaults)
        try Self.expectAGoneAndOthersKept(url, defaults, guest: guestBefore, b: bBefore)
    }

    // 4. / F: rows committed, crash before the UserDefaults.
    @Test
    func aCrashAfterTheRowsCommitIsFinishedAtTheNextLaunch() throws {
        let (url, cleanup) = try Self.tempURL()
        defer { cleanup() }
        let defaults = Self.makeDefaults()
        let container = try Self.seededA(url, defaults)
        let guestBefore = try Self.rows(of: nil, ModelContext(container))
        let bBefore = try Self.rows(of: Self.accountB, ModelContext(container))
        try AccountLocalDataCleanup(container: container, defaults: defaults).recordConfirmedDeletion(of: Self.accountA.uuidString)

        // The commit that ends the rows' step is where the process dies.
        let crashing = AccountLocalDataCleanup(container: container, defaults: defaults, commit: { context, step in
            try context.save()
            if step == .deleteRows { throw Crash() }
        })
        #expect(throws: Crash.self) { try crashing.run(for: Self.accountA) }
        #expect(try Self.rows(of: Self.accountA, ModelContext(try Self.container(url))).isEmpty)
        #expect(defaults.object(forKey: Self.keys(of: .account(Self.accountA))[0]) != nil)
        #expect(try crashing.pendingIDs() == [Self.accountA])

        try Self.relaunch(url, defaults)
        try Self.expectAGoneAndOthersKept(url, defaults, guest: guestBefore, b: bBefore)
    }

    // 5. / G and 6. / 8: everything done but the marker's removal.
    @Test(arguments: [false, true])
    func aCrashOrFailureBeforeTheMarkerIsRemovedIsFinishedAtTheNextLaunch(_ saveFails: Bool) throws {
        let (url, cleanup) = try Self.tempURL()
        defer { cleanup() }
        let defaults = Self.makeDefaults()
        let container = try Self.seededA(url, defaults)
        let guestBefore = try Self.rows(of: nil, ModelContext(container))
        let bBefore = try Self.rows(of: Self.accountB, ModelContext(container))
        let defaultsBefore = Self.defaultsSnapshot(defaults, keys: Self.survivingKeys)

        let stopping = AccountLocalDataCleanup(container: container, defaults: defaults, commit: { context, step in
            guard step == .removeMarker else { return try context.save() }
            // A crash never saves; a failed save throws. Either way, no removal.
            throw saveFails ? CommitFailure() as Error : Crash() as Error
        })
        #expect(throws: (any Error).self) { try stopping.run(for: Self.accountA) }
        #expect(try stopping.pendingIDs() == [Self.accountA])
        #expect(try Self.rows(of: Self.accountA, ModelContext(try Self.container(url))).isEmpty)
        #expect(defaults.object(forKey: Self.keys(of: .account(Self.accountA))[0]) == nil)

        // The retry repeats every step — all idempotent — and acknowledges.
        try Self.relaunch(url, defaults)
        try Self.expectAGoneAndOthersKept(url, defaults, guest: guestBefore, b: bBefore)
        #expect(Self.defaultsSnapshot(defaults, keys: Self.survivingKeys) == defaultsBefore)
    }

    // 7. / H: a finished cleanup leaves no marker, and a later launch is a no-op.
    @Test
    func aFinishedCleanupLeavesNoMarkerAndALaterLaunchChangesNothing() throws {
        let (url, cleanup) = try Self.tempURL()
        defer { cleanup() }
        let defaults = Self.makeDefaults()
        let container = try Self.seededA(url, defaults)
        try AccountLocalDataCleanup(container: container, defaults: defaults).run(for: Self.accountA)
        #expect(try AccountLocalDataCleanup(container: container).pendingIDs().isEmpty)
        let guestAfter = try Self.rows(of: nil, ModelContext(try Self.container(url)))
        let bAfter = try Self.rows(of: Self.accountB, ModelContext(try Self.container(url)))

        try Self.relaunch(url, defaults)
        #expect(try Self.rows(of: nil, ModelContext(try Self.container(url))) == guestAfter)
        #expect(try Self.rows(of: Self.accountB, ModelContext(try Self.container(url))) == bAfter)
    }

    // A / B / 9: no answer, or no request — no marker, and nothing deleted.
    @Test(arguments: [AccountAPIError.unavailable, AccountAPIError.invalidCredentials])
    func anUnknownOutcomeIsNeverRecordedSoTheNextLaunchDeletesNothing(_ error: AccountAPIError) async throws {
        let (url, cleanup) = try Self.tempURL()
        defer { cleanup() }
        let defaults = Self.makeDefaults()
        let container = try Self.seededA(url, defaults)
        let aBefore = try Self.rows(of: Self.accountA, ModelContext(container))

        let (store, _, _) = await Self.recordingStore(deleteResult: .failure(error), container: container)
        _ = await store.deleteAccount()
        try Self.relaunch(url, defaults)

        #expect(try AccountLocalDataCleanup(container: try Self.container(url)).pendingIDs().isEmpty)
        #expect(try Self.rows(of: Self.accountA, ModelContext(try Self.container(url))) == aBefore)
    }

    @Test
    func noRequestMeansNoMarker() async throws {
        let (url, cleanup) = try Self.tempURL()
        defer { cleanup() }
        let container = try Self.container(url)
        let (store, tokens, _) = await Self.recordingStore(deleteResult: .success(.deleted), container: container)
        #expect(tokens.delete() == .removed)
        #expect(await store.deleteAccount() == .notAttempted(.notSignedIn))
        #expect(try AccountLocalDataCleanup(container: container).pendingIDs().isEmpty)
    }

    // 10.
    @Test
    func logoutLeavesNoMarker() async throws {
        let (url, cleanup) = try Self.tempURL()
        defer { cleanup() }
        let container = try Self.container(url)
        let (store, _, _) = await Self.recordingStore(deleteResult: .success(.deleted), container: container)
        _ = await store.logout()
        #expect(try AccountLocalDataCleanup(container: container).pendingIDs().isEmpty)
    }

    /// The pre-V9 UserDefaults list (never released) is not a source of truth.
    @Test
    func theRetiredUserDefaultsListIsNotRead() throws {
        let (url, cleanup) = try Self.tempURL()
        defer { cleanup() }
        let defaults = Self.makeDefaults()
        let container = try Self.seededA(url, defaults)
        let aBefore = try Self.rows(of: Self.accountA, ModelContext(container))
        defaults.set(Self.accountA.uuidString, forKey: "account.pendingLocalCleanupIDs")

        try Self.relaunch(url, defaults)
        #expect(try Self.rows(of: Self.accountA, ModelContext(try Self.container(url))) == aBefore)
    }

    /// A's marker resumed while B is signed in touches nothing of B's.
    @Test
    func resumingAWhileBIsSignedInLeavesB() throws {
        let (url, cleanup) = try Self.tempURL()
        defer { cleanup() }
        let defaults = Self.makeDefaults()
        let container = try Self.seededA(url, defaults)
        defaults.set(Self.accountB.uuidString, forKey: WorkoutDataScopeResolver.lastConfirmedAccountKey)
        let guestBefore = try Self.rows(of: nil, ModelContext(container))
        let bBefore = try Self.rows(of: Self.accountB, ModelContext(container))
        try AccountLocalDataCleanup(container: container).recordConfirmedDeletion(of: Self.accountA.uuidString)

        try Self.relaunch(url, defaults)
        try Self.expectAGoneAndOthersKept(url, defaults, guest: guestBefore, b: bBefore)
        #expect(defaults.string(forKey: WorkoutDataScopeResolver.lastConfirmedAccountKey) == Self.accountB.uuidString)
    }

    // MARK: - V9 migration

    /// Stamps a store at `version` (no plan), with one health row of each kind.
    private static func seedHistorical(_ version: Int, at url: URL) throws {
        let schemas: [Int: any VersionedSchema.Type] = [
            1: PulseCueSchemaV1.self, 5: PulseCueSchemaV5.self, 6: PulseCueSchemaV6.self,
            7: PulseCueSchemaV7.self, 8: PulseCueSchemaV8.self,
        ]
        let schema = Schema(versionedSchema: try #require(schemas[version]))
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = ModelContext(container)
        if version == 8 {
            context.insert(DayLog(date: dayX, sleepMinutes: 400, ownerAccountID: accountB))
            context.insert(Session(routineId: UUID(), dayDate: dayX, ownerAccountID: accountB))
        } else {
            context.insert(PulseCueSchemaV1.DayLog(date: dayX, sleepMinutes: 400))
        }
        try context.save()
    }

    @Test(arguments: [1, 5, 6, 7, 8])
    func historicalStoresOpenAtV9WithNoMarkersAndTheirRowsIntact(version: Int) throws {
        try Self.withTempStore { url in
            try Self.seedHistorical(version, at: url)
            let container = try Self.container(url)
            try PulseCueSchemaV8.backfillScopedDayKeys(in: ModelContext(container))
            let context = ModelContext(container)

            let logs = try context.fetch(FetchDescriptor<DayLog>())
            #expect(logs.map(\.sleepMinutes) == [400])
            #expect(logs.first?.ownerAccountID == (version == 8 ? Self.accountB : nil))
            #expect(logs.first?.scopedDayKey != nil)
            if version == 8 {
                #expect(try context.fetch(FetchDescriptor<Session>()).map(\.ownerAccountID) == [Self.accountB])
            }
            #expect(try AccountLocalDataCleanup(container: container).pendingIDs().isEmpty)

            // The new entity works on a migrated store, across a reopen.
            try AccountLocalDataCleanup(container: container).recordConfirmedDeletion(of: Self.accountA.uuidString)
            #expect(try AccountLocalDataCleanup(container: try Self.container(url)).pendingIDs() == [Self.accountA])
        }
    }

    @Test
    func theShippedV3FixtureOpensAtV9() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/pre_pr132_v3.sqlite")
        try Self.withTempStore { url in
            try FileManager.default.copyItem(at: source, to: url)
            let context = ModelContext(try Self.container(url))
            #expect(try context.fetchCount(FetchDescriptor<Routine>()) == 1)
            #expect(try context.fetchCount(FetchDescriptor<Session>()) == 1)
            #expect(try context.fetchCount(FetchDescriptor<PendingAccountLocalCleanup>()) == 0)
        }
    }

    @Test
    func v9OnlyAddsTheMarker() {
        let v8 = Set(PulseCueSchemaV8.models.map { ObjectIdentifier($0) })
        let v9 = Set(PulseCueSchemaV9.models.map { ObjectIdentifier($0) })
        #expect(v9.subtracting(v8) == [ObjectIdentifier(PendingAccountLocalCleanup.self)])
        #expect(v8.isSubset(of: v9))
        #expect(PulseCueMigrationPlan.schemas.last == PulseCueSchemaV9.self)
    }
}
