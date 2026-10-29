//
//  AccountLocalDataAdoptionTests.swift
//  Pulse CueTests
//
//  The guest-adoption transaction across workouts and health: both domains
//  preflighted before either is applied, one save, and a failed save that
//  leaves every row — and the outbox — exactly as it was, after reopen too.
//  Also the consent contract around it and the passive-profile rule that
//  keeps the guest profile adoptable.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct AccountLocalDataAdoptionTests {

    private static let accountA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-00000000000A")!
    private static let accountB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-00000000000B")!
    private static let dayX = DateUtils.startOfDay(Date(timeIntervalSinceReferenceDate: 800_000_000))
    private static let earlier = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private struct CommitFailure: Error {}

    // MARK: - Fixture

    private static func makeContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: PulseCueSchemaV10.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private static func withTempStore(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsecue-localadoption-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.appendingPathComponent("store.sqlite"))
    }

    /// A fresh container on `url` each call — a real reopen.
    private static func open(_ url: URL, _ work: (ModelContext) throws -> Void) throws {
        let schema = Schema(versionedSchema: PulseCueSchemaV10.self)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: PulseCueMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: url)
        )
        try work(ModelContext(container))
    }

    private struct Seeded {
        let session: UUID
        let result: UUID
        let preexistingOutbox: String
    }

    /// Guest: a session with one result, a pre-existing queue entry for that
    /// session, a day log with a value, a meal, and a profile. Account A has
    /// nothing.
    @discardableResult
    private static func seedGuest(_ context: ModelContext, workout: Bool = true, health: Bool = true) throws -> Seeded {
        let session = Session(routineId: UUID(), dayDate: Date(), ownerAccountID: nil)
        let result = StepResult(sessionId: session.id, stepId: UUID(), setIndex: 0, done: true, ownerAccountID: nil)
        let identity = SyncOutboxItem.identity(accountID: accountA, entityType: .session, entityID: session.id)
        if workout {
            context.insert(session)
            context.insert(result)
            context.insert(SyncOutboxItem(
                identity: identity, accountID: accountA, entityType: .session, entityID: session.id,
                mutation: .upsert, createdAt: earlier, updatedAt: earlier
            ))
        }
        if health {
            context.insert(DayLog(date: dayX, sleepMinutes: 400, ownerAccountID: nil))
            context.insert(MealEntry(dayDate: dayX, slot: .lunch, name: "m", kcal: 500, status: .confirmed, source: .manual, ownerAccountID: nil))
            context.insert(UserProfile(heightCm: 170, ownerAccountID: nil))
        }
        try context.save()
        return Seeded(session: session.id, result: result.id, preexistingOutbox: identity)
    }

    private static func count<T: PersistentModel>(_ type: T.Type, _ context: ModelContext, owner: UUID?) throws -> Int {
        try context.fetch(FetchDescriptor<T>()).filter { row in
            switch row {
            case let s as Session: return s.ownerAccountID == owner
            case let r as StepResult: return r.ownerAccountID == owner
            case let d as DayLog: return d.ownerAccountID == owner
            case let m as MealEntry: return m.ownerAccountID == owner
            case let p as UserProfile: return p.ownerAccountID == owner
            default: return false
            }
        }.count
    }

    /// Every seeded row still guest, the outbox exactly as seeded.
    private static func expectAllGuest(_ context: ModelContext, _ seeded: Seeded) throws {
        #expect(try count(Session.self, context, owner: nil) == 1)
        #expect(try count(StepResult.self, context, owner: nil) == 1)
        #expect(try count(Session.self, context, owner: accountA) == 0)
        #expect(try count(StepResult.self, context, owner: accountA) == 0)
        let outbox = try context.fetch(FetchDescriptor<SyncOutboxItem>())
        #expect(outbox.count == 1)
        #expect(outbox.first?.identity == seeded.preexistingOutbox)
        #expect(outbox.first?.mutation == .upsert)
        #expect(outbox.first?.updatedAt == earlier)

        let log = DayLogStore.fetch(date: dayX, scope: .guest, modelContext: context)
        #expect(log?.sleepMinutes == 400)
        #expect(log?.scopedDayKey == DayLog.scopedDayKey(ownerAccountID: nil, date: dayX))
        #expect(try count(DayLog.self, context, owner: accountA) == 0)
        #expect(try count(MealEntry.self, context, owner: nil) == 1)
        #expect(try count(MealEntry.self, context, owner: accountA) == 0)
        #expect(UserProfileStore.profile(for: .guest, modelContext: context)?.heightCm == 170)
        #expect(UserProfileStore.profile(for: .account(accountA), modelContext: context) == nil)
    }

    // MARK: - Success

    @Test
    func acceptingMovesWorkoutHealthAndProfileWithOneSave() throws {
        try Self.withTempStore { url in
            try Self.open(url) { context in
                try Self.seedGuest(context)
                var saves = 0
                let store = AccountLocalDataAdoptionStore(commit: { saves += 1; try $0.save() })
                let summary = try store.adoptGuestData(workout: true, health: true, for: Self.accountA, in: context)

                #expect(saves == 1)
                #expect(summary.workout.adoptedSessions == 1)
                #expect(summary.workout.adoptedStepResults == 1)
                #expect(summary.health.adoptedLogs == 1)
                #expect(summary.health.adoptedMeals == 1)
                #expect(summary.health.adoptedProfile)
            }
            try Self.open(url) { context in
                #expect(try Self.count(Session.self, context, owner: Self.accountA) == 1)
                #expect(try Self.count(StepResult.self, context, owner: Self.accountA) == 1)
                #expect(try Self.count(Session.self, context, owner: nil) == 0)
                let outbox = try context.fetch(FetchDescriptor<SyncOutboxItem>())
                #expect(outbox.count == 2)
                #expect(outbox.allSatisfy { $0.accountID == Self.accountA && $0.mutation == .upsert })
                let log = DayLogStore.fetch(date: Self.dayX, scope: .account(Self.accountA), modelContext: context)
                #expect(log?.sleepMinutes == 400)
                #expect(log?.scopedDayKey == DayLog.scopedDayKey(ownerAccountID: Self.accountA, date: Self.dayX))
                #expect(try Self.count(MealEntry.self, context, owner: Self.accountA) == 1)
                #expect(UserProfileStore.profile(for: .account(Self.accountA), modelContext: context)?.heightCm == 170)
                #expect(UserProfileStore.profile(for: .guest, modelContext: context) == nil)
            }
        }
    }

    @Test
    func workoutOnlyLeavesHealthAsGuest() throws {
        let context = try Self.makeContext()
        try Self.seedGuest(context)
        var saves = 0
        try AccountLocalDataAdoptionStore(commit: { saves += 1; try $0.save() })
            .adoptGuestData(workout: true, health: false, for: Self.accountA, in: context)

        #expect(saves == 1)
        #expect(try Self.count(Session.self, context, owner: Self.accountA) == 1)
        #expect(try Self.count(DayLog.self, context, owner: nil) == 1)
        #expect(try Self.count(MealEntry.self, context, owner: nil) == 1)
        #expect(UserProfileStore.profile(for: .guest, modelContext: context) != nil)
    }

    @Test
    func healthOnlyLeavesWorkoutsAsGuest() throws {
        let context = try Self.makeContext()
        try Self.seedGuest(context)
        var saves = 0
        try AccountLocalDataAdoptionStore(commit: { saves += 1; try $0.save() })
            .adoptGuestData(workout: false, health: true, for: Self.accountA, in: context)

        #expect(saves == 1)
        #expect(try Self.count(Session.self, context, owner: nil) == 1)
        #expect(try context.fetch(FetchDescriptor<SyncOutboxItem>()).count == 1)
        #expect(try Self.count(DayLog.self, context, owner: Self.accountA) == 1)
        #expect(try Self.count(MealEntry.self, context, owner: Self.accountA) == 1)
        #expect(UserProfileStore.profile(for: .account(Self.accountA), modelContext: context) != nil)
    }

    // MARK: - Atomicity

    /// The acceptance gap Codex named: at the moment of saving, both domains
    /// are applied; a failing save then puts every row back, the context stays
    /// usable, and a reopen shows no partial adoption.
    @Test
    func failedSaveRestoresBothDomainsExactly() throws {
        try Self.withTempStore { url in
            var seeded: Seeded?
            try Self.open(url) { context in
                seeded = try Self.seedGuest(context)
                var sawBothApplied = false
                let store = AccountLocalDataAdoptionStore(commit: { context in
                    let sessions = try context.fetch(FetchDescriptor<Session>())
                    let logs = try context.fetch(FetchDescriptor<DayLog>())
                    let meals = try context.fetch(FetchDescriptor<MealEntry>())
                    let profiles = try context.fetch(FetchDescriptor<UserProfile>())
                    let outbox = try context.fetch(FetchDescriptor<SyncOutboxItem>())
                    sawBothApplied = sessions.allSatisfy { $0.ownerAccountID == Self.accountA }
                        && logs.allSatisfy { $0.ownerAccountID == Self.accountA }
                        && meals.allSatisfy { $0.ownerAccountID == Self.accountA }
                        && profiles.allSatisfy { $0.ownerAccountID == Self.accountA }
                        && outbox.count == 2
                    throw CommitFailure()
                })
                #expect(throws: CommitFailure.self) {
                    try store.adoptGuestData(workout: true, health: true, for: Self.accountA, in: context)
                }
                #expect(sawBothApplied)
                try Self.expectAllGuest(context, try #require(seeded))

                // An unrelated change in the same context saves cleanly and
                // carries nothing of the attempt with it.
                context.insert(DayLog(date: Self.dayX, weightKg: 60, ownerAccountID: Self.accountB))
                try context.save()
                try Self.expectAllGuest(context, try #require(seeded))
            }
            try Self.open(url) { context in
                try Self.expectAllGuest(context, try #require(seeded))
                #expect(DayLogStore.fetch(date: Self.dayX, scope: .account(Self.accountB), modelContext: context)?.weightKg == 60)
            }
        }
    }

    /// A workout preflight refusal (a delete still queued for the session)
    /// arrives before health is touched, and nothing is saved.
    @Test
    func workoutPreflightFailureMutatesNothing() throws {
        let context = try Self.makeContext()
        let seeded = try Self.seedGuest(context)
        let queued = try #require(try context.fetch(FetchDescriptor<SyncOutboxItem>()).first)
        queued.mutation = .delete
        try context.save()

        var saves = 0
        let store = AccountLocalDataAdoptionStore(commit: { saves += 1; try $0.save() })
        #expect(throws: AccountScopedSyncError.tombstoneIsTerminal(.session, seeded.session)) {
            try store.adoptGuestData(workout: true, health: true, for: Self.accountA, in: context)
        }
        #expect(saves == 0)
        #expect(!context.hasChanges)
        #expect(try Self.count(DayLog.self, context, owner: nil) == 1)
        #expect(try Self.count(MealEntry.self, context, owner: nil) == 1)
        #expect(UserProfileStore.profile(for: .guest, modelContext: context) != nil)
        #expect(try Self.count(Session.self, context, owner: nil) == 1)
    }

    // MARK: - Consent

    @Test
    func answersAreRecordedOnlyAfterASuccessfulCommitAndOnlyForAskedHalves() throws {
        let context = try Self.makeContext()
        try Self.seedGuest(context)
        let none = GuestAdoptionConsent.Answers(workoutRaw: "", healthRaw: "")
        let question = try #require(GuestAdoptionConsent.question(for: Self.accountA, answers: none, in: context))
        #expect(question == .init(accountID: Self.accountA, workout: true, health: true, profile: true))
        #expect(question.subject == "トレーニング・食事記録・体重や睡眠・プロフィール")

        var answers = none
        let failing = AccountLocalDataAdoptionStore(commit: { _ in throw CommitFailure() })
        #expect(throws: CommitFailure.self) {
            try GuestAdoptionConsent.accept(question, answers: &answers, in: context, store: failing)
        }
        #expect(answers == none)
        #expect(GuestAdoptionConsent.question(for: Self.accountA, answers: answers, in: context) == question)

        try GuestAdoptionConsent.accept(question, answers: &answers, in: context)
        #expect(answers.answeredWorkout(Self.accountA))
        #expect(answers.answeredHealth(Self.accountA))
        #expect(!answers.answeredWorkout(Self.accountB))
    }

    @Test
    func declineRecordsOnlyTheAskedHalf() {
        let none = GuestAdoptionConsent.Answers(workoutRaw: "", healthRaw: "")
        let workoutOnly = GuestAdoptionConsent.Question(accountID: Self.accountA, workout: true, health: false, profile: true)
        let answers = none.marking(workoutOnly)
        #expect(answers.answeredWorkout(Self.accountA))
        #expect(!answers.answeredHealth(Self.accountA))
    }

    /// A conflicting day stays guest by policy; once answered, A is not asked
    /// again, while B still is.
    @Test
    func leftoverGuestDataDoesNotReAskTheSameAccount() throws {
        let context = try Self.makeContext()
        context.insert(DayLog(date: Self.dayX, sleepMinutes: 400, ownerAccountID: nil))
        context.insert(DayLog(date: Self.dayX, sleepMinutes: 300, ownerAccountID: Self.accountA))
        try context.save()

        var answers = GuestAdoptionConsent.Answers(workoutRaw: "", healthRaw: "")
        let question = try #require(GuestAdoptionConsent.question(for: Self.accountA, answers: answers, in: context))
        try GuestAdoptionConsent.accept(question, answers: &answers, in: context)

        #expect(try Self.count(DayLog.self, context, owner: nil) == 1)
        #expect(GuestAdoptionConsent.question(for: Self.accountA, answers: answers, in: context) == nil)
        #expect(GuestAdoptionConsent.question(for: Self.accountB, answers: answers, in: context) != nil)
    }

    // MARK: - Profile is not created by looking

    /// Home showing account A must not create A's profile; otherwise "the
    /// account already has one" and the guest profile stays behind.
    @Test
    func passiveHomeLeavesGuestProfileAdoptable() throws {
        let context = try Self.makeContext()
        context.insert(UserProfile(heightCm: 170, ownerAccountID: nil))
        context.insert(DayLog(date: Self.dayX, sleepMinutes: 400, ownerAccountID: nil))
        try context.save()

        TodayView.prepareHealthRows(scope: .account(Self.accountA), modelContext: context)
        #expect(UserProfileStore.profile(for: .account(Self.accountA), modelContext: context) == nil)
        #expect(try Self.count(UserProfile.self, context, owner: Self.accountA) == 0)

        var answers = GuestAdoptionConsent.Answers(workoutRaw: "", healthRaw: "")
        let question = try #require(GuestAdoptionConsent.question(for: Self.accountA, answers: answers, in: context))
        #expect(question.profile)
        try GuestAdoptionConsent.accept(question, answers: &answers, in: context)
        #expect(UserProfileStore.profile(for: .account(Self.accountA), modelContext: context)?.heightCm == 170)
    }

    @Test
    func draftProfileIsStoredOnlyWhenPersisted() throws {
        let context = try Self.makeContext()
        let a = HealthDataScope.account(Self.accountA)
        let draft = try #require(UserProfileStore.draftProfile(for: a))
        #expect(draft.ownerAccountID == Self.accountA)
        #expect(try Self.count(UserProfile.self, context, owner: Self.accountA) == 0)
        #expect(UserProfileStore.draftProfile(for: .undetermined) == nil)

        // A draft for A is never stored under B.
        #expect(UserProfileStore.persistDraft(draft, for: .account(Self.accountB), modelContext: context) == nil)
        #expect(UserProfileStore.persistDraft(draft, for: a, modelContext: context) === draft)
        #expect(try Self.count(UserProfile.self, context, owner: Self.accountA) == 1)

        // Once A has a profile, a second draft yields the stored one.
        let second = try #require(UserProfileStore.draftProfile(for: a))
        #expect(UserProfileStore.persistDraft(second, for: a, modelContext: context) === draft)
        #expect(try Self.count(UserProfile.self, context, owner: Self.accountA) == 1)
    }
}
