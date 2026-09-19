//
//  AccountDataPolicyTests.swift
//  Pulse CueTests
//
//  The account boundary as the app actually enforces it: what gets created,
//  what gets shown, what can be resumed, what may be sent, and what stays
//  deleted.
//
//  Every test here is a way somebody else's training could end up attributed
//  to, shown to, or uploaded by the wrong account.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct AccountDataPolicyTests {

    // MARK: - Fixture

    private static func makeContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: PulseCueSchemaV7.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @discardableResult
    private static func session(
        _ context: ModelContext,
        owner: UUID?,
        status: SessionStatus = .completed
    ) -> Session {
        let session = Session(
            routineId: UUID(),
            dayDate: Date(),
            status: status,
            ownerAccountID: owner
        )
        context.insert(session)
        return session
    }

    @discardableResult
    private static func result(
        _ context: ModelContext,
        of session: Session,
        owner: UUID?
    ) -> StepResult {
        let result = StepResult(
            sessionId: session.id,
            stepId: UUID(),
            setIndex: 0,
            done: true,
            ownerAccountID: owner
        )
        context.insert(result)
        return result
    }

    // MARK: - Creation ownership

    @Test("A workout started as guest is unowned")
    func guestCreationIsUnowned() {
        #expect(WorkoutDataScope.guest.creationOwnerAccountID == nil)
    }

    @Test("A workout started while signed in belongs to that account")
    func authenticatedCreationCarriesTheAccount() {
        let a = UUID()
        #expect(WorkoutDataScope.account(a).creationOwnerAccountID == a)
    }

    @Test("An unreadable account id blocks creation instead of writing guest data")
    func undeterminedScopeRefusesCreation() {
        // Whether this is a launch mid-restore or an account id the app could
        // not read, quietly writing a guest row would make the workout
        // invisible and unsyncable the moment the scope resolves.
        #expect(!WorkoutDataScope.undetermined.canCreateWorkouts)
        #expect(WorkoutDataScope.undetermined.creationOwnerAccountID == nil)
    }

    // MARK: - Visibility

    @Test("Each scope sees only its own history, and the rest stays in the store")
    func visibilityIsScopedAndNonDestructive() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let b = UUID()
        let guest = Self.session(context, owner: nil)
        let aSession = Self.session(context, owner: a)
        let bSession = Self.session(context, owner: b)
        Self.result(context, of: guest, owner: nil)
        Self.result(context, of: aSession, owner: a)
        Self.result(context, of: bSession, owner: b)
        try context.save()

        let all = try context.fetch(FetchDescriptor<Session>())
        let allResults = try context.fetch(FetchDescriptor<StepResult>())

        #expect(WorkoutDataScope.guest.visible(all).map(\.id) == [guest.id])
        #expect(WorkoutDataScope.account(a).visible(all).map(\.id) == [aSession.id])
        #expect(WorkoutDataScope.account(b).visible(all).map(\.id) == [bSession.id])
        #expect(WorkoutDataScope.undetermined.visible(all).isEmpty)

        #expect(WorkoutDataScope.account(a).visible(allResults).count == 1)
        #expect(WorkoutDataScope.guest.visible(allResults).count == 1)

        // Filtering is a presentation decision, not a deletion.
        #expect(all.count == 3)
        #expect(allResults.count == 3)
    }

    // MARK: - Account switching

    @Test("Guest → A → logout → B → A never leaks a scope and never rewrites an owner")
    func accountSwitchingKeepsEveryScopeSeparate() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let b = UUID()
        let guest = Self.session(context, owner: nil)
        let aSession = Self.session(context, owner: a)
        let bSession = Self.session(context, owner: b)
        try context.save()

        let all = try context.fetch(FetchDescriptor<Session>())
        let store = AccountScopedSyncStore()

        for (scope, expected) in [
            (WorkoutDataScope.guest, [guest.id]),
            (.account(a), [aSession.id]),
            (.guest, [guest.id]),
            (.account(b), [bSession.id]),
            (.account(a), [aSession.id])
        ] as [(WorkoutDataScope, [UUID])] {
            #expect(scope.visible(all).map(\.id) == expected)
        }

        // Owners are untouched by any amount of switching.
        #expect(guest.ownerAccountID == nil)
        #expect(aSession.ownerAccountID == a)
        #expect(bSession.ownerAccountID == b)
        #expect(try store.syncCandidateSessions(for: a, in: context).map(\.id) == [aSession.id])
        #expect(try store.syncCandidateSessions(for: b, in: context).map(\.id) == [bSession.id])
    }

    // MARK: - Runner isolation

    @Test("An account's in-progress workout is resumable by it and by nobody else")
    func resumeIsScopedToTheOwningAccount() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let b = UUID()
        let running = Self.session(context, owner: a, status: .inProgress)
        try context.save()

        #expect(WorkoutDataScope.account(a).matches(ownerAccountID: running.ownerAccountID))
        #expect(!WorkoutDataScope.account(b).matches(ownerAccountID: running.ownerAccountID))
        #expect(!WorkoutDataScope.guest.matches(ownerAccountID: running.ownerAccountID))
        #expect(!WorkoutDataScope.undetermined.matches(ownerAccountID: running.ownerAccountID))
    }

    // MARK: - Adoption

    @Test("Accepting adoption moves the guest rows and only those")
    func acceptingAdoptionMovesGuestRowsOnly() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let b = UUID()
        let guest = Self.session(context, owner: nil)
        let guestResult = Self.result(context, of: guest, owner: nil)
        let bSession = Self.session(context, owner: b)
        let bResult = Self.result(context, of: bSession, owner: b)
        try context.save()

        let summary = try AccountScopedSyncStore().adoptGuestWorkoutData(for: a, in: context)

        #expect(summary == .init(adoptedSessions: 1, adoptedStepResults: 1))
        #expect(guest.ownerAccountID == a)
        #expect(guestResult.ownerAccountID == a)
        #expect(bSession.ownerAccountID == b)
        #expect(bResult.ownerAccountID == b)
    }

    @Test("Declining leaves the guest rows unowned")
    func decliningChangesNothing() throws {
        let context = try Self.makeContext()
        let guest = Self.session(context, owner: nil)
        try context.save()

        // Declining is the absence of the call, which is the point: there is
        // no "adopt later anyway" path for the app to take on its own.
        #expect(guest.ownerAccountID == nil)
        #expect(try AccountScopedSyncStore().guestSessions(in: context).count == 1)
    }

    @Test("Adopting twice queues no second copy of anything")
    func repeatedAdoptionIsIdempotent() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let guest = Self.session(context, owner: nil)
        Self.result(context, of: guest, owner: nil)
        try context.save()

        let store = AccountScopedSyncStore()
        try store.adoptGuestWorkoutData(for: a, in: context)
        let afterFirst = try store.outboxItems(for: a, in: context).count
        let second = try store.adoptGuestWorkoutData(for: a, in: context)

        #expect(second == .nothing)
        #expect(afterFirst == 2)
        #expect(try store.outboxItems(for: a, in: context).count == afterFirst)
    }

    // MARK: - Send boundary

    @Test("A session may only be queued by the account that owns it")
    func sessionSendChecksTheRowRatherThanTheCaller() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let b = UUID()
        let aSession = Self.session(context, owner: a)
        try context.save()
        let store = AccountScopedSyncStore()

        try store.recordSessionMutation(.upsert, aSession, for: a, in: context)
        try context.save()
        #expect(try store.outboxItems(for: a, in: context).count == 1)

        #expect(throws: AccountScopedSyncError.ownerMismatch(.session, aSession.id)) {
            try store.recordSessionMutation(.upsert, aSession, for: b, in: context)
        }
        #expect(try store.outboxItems(for: b, in: context).isEmpty)
    }

    @Test("A step result may only be queued with its parent session agreeing")
    func stepResultSendChecksTheParent() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let b = UUID()
        let aSession = Self.session(context, owner: a)
        let bSession = Self.session(context, owner: b)
        let good = Self.result(context, of: aSession, owner: a)
        // The pair the server's composite foreign key makes unrepresentable.
        let crossOwner = Self.result(context, of: bSession, owner: a)
        let childOfB = Self.result(context, of: aSession, owner: b)
        let orphanParent = Self.result(context, of: Self.session(context, owner: nil), owner: a)
        try context.save()
        let store = AccountScopedSyncStore()

        try store.recordStepResultMutation(.upsert, good, for: a, in: context)
        try context.save()
        #expect(try store.outboxItems(for: a, in: context).count == 1)

        #expect(throws: AccountScopedSyncError.parentOwnerMismatch(crossOwner.id)) {
            try store.recordStepResultMutation(.upsert, crossOwner, for: a, in: context)
        }
        #expect(throws: AccountScopedSyncError.ownerMismatch(.stepResult, childOfB.id)) {
            try store.recordStepResultMutation(.upsert, childOfB, for: a, in: context)
        }
        #expect(throws: AccountScopedSyncError.parentOwnerMismatch(orphanParent.id)) {
            try store.recordStepResultMutation(.upsert, orphanParent, for: a, in: context)
        }
        #expect(try store.outboxItems(for: a, in: context).count == 1)
    }

    @Test("A step result whose session is not in the store is refused")
    func stepResultWithNoParentIsRefused() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let detached = StepResult(
            sessionId: UUID(),
            stepId: UUID(),
            setIndex: 0,
            done: true,
            ownerAccountID: a
        )
        context.insert(detached)
        try context.save()

        #expect(throws: AccountScopedSyncError.unknownParentSession(detached.id)) {
            try AccountScopedSyncStore()
                .recordStepResultMutation(.upsert, detached, for: a, in: context)
        }
    }

    // MARK: - Progress cache scope (same row counts)

    /// Two accounts with identical row *counts* and different training.
    ///
    /// This is the shape the count-based cache could not see: ten sessions
    /// before the switch, ten after, so nothing "changed" and the previous
    /// account's totals stayed on screen.
    private static func seedSameShapedHistory(
        _ context: ModelContext,
        owner: UUID?,
        routine: Routine,
        sessionCount: Int,
        secondsEach: Int
    ) {
        for _ in 0..<sessionCount {
            let session = Session(
                routineId: routine.id,
                dayDate: Date(),
                startedAt: Date(),
                endedAt: Date(),
                status: .completed,
                totalSeconds: secondsEach,
                ownerAccountID: owner
            )
            context.insert(session)
            context.insert(
                StepResult(
                    sessionId: session.id,
                    stepId: UUID(),
                    setIndex: 0,
                    done: true,
                    ownerAccountID: owner
                )
            )
        }
    }

    @Test("Switching between two accounts with the same row counts recomputes progress")
    func progressSignatureChangesOnAccountSwitchWithEqualCounts() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let b = UUID()
        let routine = Routine(name: "胸の日")
        context.insert(routine)
        Self.seedSameShapedHistory(
            context, owner: a, routine: routine, sessionCount: 10, secondsEach: 600
        )
        Self.seedSameShapedHistory(
            context, owner: b, routine: routine, sessionCount: 10, secondsEach: 1_200
        )
        try context.save()

        let allSessions = try context.fetch(FetchDescriptor<Session>())
        let allResults = try context.fetch(FetchDescriptor<StepResult>())
        let routines = [routine]

        func signature(_ scope: WorkoutDataScope) -> ScopedProgressSignature {
            ScopedProgressSignature(
                scope: scope,
                allSessions: allSessions,
                allResults: allResults,
                routines: routines
            )
        }
        func summary(_ scope: WorkoutDataScope) -> HomeProgressSummary {
            HomeProgressSummary.make(
                sessions: scope.visible(allSessions),
                results: scope.visible(allResults),
                routines: routines
            )
        }

        // The counts really are identical — otherwise this test would pass for
        // the wrong reason.
        #expect(WorkoutDataScope.account(a).visible(allSessions).count
            == WorkoutDataScope.account(b).visible(allSessions).count)
        #expect(WorkoutDataScope.account(a).visible(allResults).count
            == WorkoutDataScope.account(b).visible(allResults).count)

        #expect(signature(.account(a)) != signature(.account(b)))
        #expect(summary(.account(a)).weeklyDurationSeconds == 6_000)
        #expect(summary(.account(b)).weeklyDurationSeconds == 12_000)

        // A → B → A: the value comes back, and the signature moves each way.
        #expect(signature(.account(b)) != signature(.account(a)))
        #expect(summary(.account(a)).weeklyDurationSeconds == 6_000)
    }

    @Test("Guest and an account with identical histories still have different signatures")
    func progressSignatureSeparatesGuestFromAnAccount() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let routine = Routine(name: "背中の日")
        context.insert(routine)
        Self.seedSameShapedHistory(
            context, owner: nil, routine: routine, sessionCount: 3, secondsEach: 300
        )
        Self.seedSameShapedHistory(
            context, owner: a, routine: routine, sessionCount: 3, secondsEach: 300
        )
        try context.save()

        let allSessions = try context.fetch(FetchDescriptor<Session>())
        let allResults = try context.fetch(FetchDescriptor<StepResult>())
        let guest = ScopedProgressSignature(
            scope: .guest, allSessions: allSessions, allResults: allResults, routines: [routine]
        )
        let account = ScopedProgressSignature(
            scope: .account(a), allSessions: allSessions, allResults: allResults, routines: [routine]
        )

        // Same counts, same durations, different people.
        #expect(guest != account)
    }

    /// One completed session, one step, one recorded set — the smallest
    /// fixture the exercise insights will actually read.
    private static func seedOneSetOfHistory(
        _ context: ModelContext,
        owner: UUID?,
        routine: Routine
    ) -> (session: Session, step: Step, result: StepResult) {
        let step = Step(
            routineId: routine.id,
            order: 0,
            title: "ベンチプレス",
            sets: 1,
            repsTarget: 10,
            restSeconds: 60,
            exerciseId: "barbell-bench-press"
        )
        context.insert(step)
        let session = Session(
            routineId: routine.id,
            dayDate: Date(),
            startedAt: Date(),
            endedAt: Date(),
            status: .completed,
            totalSeconds: 600,
            ownerAccountID: owner
        )
        context.insert(session)
        let result = StepResult(
            sessionId: session.id,
            stepId: step.id,
            setIndex: 0,
            done: true,
            actualReps: 10,
            ownerAccountID: owner
        )
        context.insert(result)
        return (session, step, result)
    }

    /// Signature + insights over the same fixture, always in step.
    private static func insightState(
        _ context: ModelContext,
        scope: WorkoutDataScope,
        routines: [Routine]
    ) throws -> (signature: ScopedProgressSignature, insights: [ExerciseProgressInsight]) {
        let allSessions = try context.fetch(FetchDescriptor<Session>())
        let allResults = try context.fetch(FetchDescriptor<StepResult>())
        let allSteps = try context.fetch(FetchDescriptor<Step>())
        return (
            ScopedProgressSignature(
                scope: scope,
                allSessions: allSessions,
                allResults: allResults,
                routines: routines,
                allSteps: allSteps
            ),
            WorkoutProgressQuery.exerciseInsights(
                steps: allSteps,
                sessions: scope.visible(allSessions),
                results: scope.visible(allResults)
            )
        )
    }

    @Test("Editing a rep count changes the signature, with the row count unchanged")
    func signatureTracksActualReps() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let routine = Routine(name: "胸の日")
        context.insert(routine)
        let seeded = Self.seedOneSetOfHistory(context, owner: a, routine: routine)
        try context.save()

        let before = try Self.insightState(context, scope: .account(a), routines: [routine])
        seeded.result.actualReps = 12
        try context.save()
        let after = try Self.insightState(context, scope: .account(a), routines: [routine])

        // Same number of rows throughout — only the value changed.
        #expect(try context.fetchCount(FetchDescriptor<StepResult>()) == 1)
        #expect(before.insights.first?.latestReps == [10])
        #expect(after.insights.first?.latestReps == [12])
        #expect(before.signature != after.signature)
    }

    @Test("Changing which exercise a step is changes the signature")
    func signatureTracksExerciseIdentity() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let routine = Routine(name: "胸の日")
        context.insert(routine)
        let seeded = Self.seedOneSetOfHistory(context, owner: a, routine: routine)
        try context.save()

        let before = try Self.insightState(context, scope: .account(a), routines: [routine])
        seeded.step.exerciseId = "dumbbell-bench-press"
        seeded.step.title = "ダンベルベンチプレス"
        try context.save()
        let after = try Self.insightState(context, scope: .account(a), routines: [routine])

        #expect(before.insights.first?.exerciseId == "barbell-bench-press")
        #expect(after.insights.first?.exerciseId == "dumbbell-bench-press")
        #expect(before.signature != after.signature)
    }

    @Test("Moving a set to another step or position changes the signature")
    func signatureTracksStepIdAndSetIndex() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let routine = Routine(name: "胸の日")
        context.insert(routine)
        let seeded = Self.seedOneSetOfHistory(context, owner: a, routine: routine)
        let otherStep = Step(
            routineId: routine.id,
            order: 1,
            title: "インクラインプレス",
            sets: 1,
            repsTarget: 10,
            restSeconds: 60,
            exerciseId: "incline-bench-press"
        )
        context.insert(otherStep)
        try context.save()

        let start = try Self.insightState(context, scope: .account(a), routines: [routine])
        seeded.result.setIndex = 1
        try context.save()
        let movedPosition = try Self.insightState(context, scope: .account(a), routines: [routine])
        seeded.result.stepId = otherStep.id
        try context.save()
        let movedStep = try Self.insightState(context, scope: .account(a), routines: [routine])

        #expect(start.signature != movedPosition.signature)
        #expect(movedPosition.signature != movedStep.signature)
        #expect(movedStep.insights.first?.exerciseId == "incline-bench-press")
    }

    @Test("Adding a step nobody trained does not invalidate the insights cache")
    func signatureIgnoresFieldsTheInsightsNeverRead() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let routine = Routine(name: "胸の日")
        context.insert(routine)
        let seeded = Self.seedOneSetOfHistory(context, owner: a, routine: routine)
        try context.save()

        let before = try Self.insightState(context, scope: .account(a), routines: [routine])
        // Rest and notes reach no figure on this screen.
        seeded.step.restSeconds = 120
        seeded.step.note = "フォーム注意"
        try context.save()
        let after = try Self.insightState(context, scope: .account(a), routines: [routine])

        #expect(before.signature == after.signature)
    }

    @Test("The insight inputs do not disturb the account-scope guarantee")
    func insightSignatureKeepsScopeSeparation() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let b = UUID()
        let routine = Routine(name: "胸の日")
        context.insert(routine)
        Self.seedOneSetOfHistory(context, owner: a, routine: routine)
        Self.seedOneSetOfHistory(context, owner: b, routine: routine)
        try context.save()

        let forA = try Self.insightState(context, scope: .account(a), routines: [routine])
        let forB = try Self.insightState(context, scope: .account(b), routines: [routine])

        #expect(forA.signature != forB.signature)
    }

    // MARK: - Adoption is all or nothing

    @Test("A refused adoption leaves no row half-adopted, then or later")
    func failedAdoptionMutatesNothing() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let first = Self.session(context, owner: nil)
        let second = Self.session(context, owner: nil)
        let firstResult = Self.result(context, of: first, owner: nil)
        try context.save()

        let store = AccountScopedSyncStore()
        // A real refusal from an existing boundary: one of the guest rows
        // carries an id this account has already deleted for good, which the
        // server would answer with 409 and the store refuses locally.
        try store.confirmDeletion(.session, second.id, for: a, in: context)
        try context.save()

        #expect(throws: AccountScopedSyncError.tombstoneIsTerminal(.session, second.id)) {
            try store.adoptGuestWorkoutData(for: a, in: context)
        }

        // Nothing moved — including the row the old code would have reassigned
        // before reaching the one that threw.
        #expect(first.ownerAccountID == nil)
        #expect(second.ownerAccountID == nil)
        #expect(firstResult.ownerAccountID == nil)
        #expect(try store.outboxItems(for: a, in: context).isEmpty)

        // The part that matters: an unrelated save on the same context must not
        // commit a partial adoption left dirty behind the throw.
        let unrelated = Self.session(context, owner: nil)
        try context.save()

        #expect(first.ownerAccountID == nil)
        #expect(second.ownerAccountID == nil)
        #expect(firstResult.ownerAccountID == nil)
        #expect(unrelated.ownerAccountID == nil)
        #expect(try store.outboxItems(for: a, in: context).isEmpty)
        #expect(try store.guestSessions(in: context).count == 3)
    }

    /// A store whose commit always fails, so the *write* phase can be reached
    /// and its restore proven.
    ///
    /// The earlier atomicity test never got this far: it was refused during
    /// preflight, which proves the checks run early and nothing about what
    /// happens once rows have actually been reassigned.
    private struct CommitFailure: Error {}

    private static var failingCommitStore: AccountScopedSyncStore {
        AccountScopedSyncStore { _ in throw CommitFailure() }
    }

    @Test("A commit that fails after the owners are set leaves none of them set")
    func writePhaseFailureRestoresEveryOwner() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let session = Self.session(context, owner: nil)
        let other = Self.session(context, owner: nil)
        let result = Self.result(context, of: session, owner: nil)
        try context.save()

        #expect(throws: CommitFailure.self) {
            try Self.failingCommitStore.adoptGuestWorkoutData(for: a, in: context)
        }

        #expect(session.ownerAccountID == nil)
        #expect(other.ownerAccountID == nil)
        #expect(result.ownerAccountID == nil)
        #expect(try AccountScopedSyncStore().outboxItems(for: a, in: context).isEmpty)
    }

    @Test("Nothing from a failed write phase survives a later unrelated save")
    func writePhaseFailureSurvivesASubsequentSave() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let session = Self.session(context, owner: nil)
        let result = Self.result(context, of: session, owner: nil)
        try context.save()

        #expect(throws: CommitFailure.self) {
            try Self.failingCommitStore.adoptGuestWorkoutData(for: a, in: context)
        }

        // The failure mode this exists for: dirty objects left in the context
        // get committed by whatever saves next.
        let unrelated = Self.session(context, owner: nil)
        try context.save()

        let store = AccountScopedSyncStore()
        #expect(session.ownerAccountID == nil)
        #expect(result.ownerAccountID == nil)
        #expect(unrelated.ownerAccountID == nil)
        #expect(try store.outboxItems(for: a, in: context).isEmpty)
        #expect(try store.guestSessions(in: context).count == 2)
        #expect(try store.syncCandidateSessions(for: a, in: context).isEmpty)

        // And it really is gone from the store, not just from these objects.
        let reread = try context.fetch(FetchDescriptor<Session>())
        #expect(reread.allSatisfy { $0.ownerAccountID == nil })
        #expect(try context.fetchCount(FetchDescriptor<SyncOutboxItem>()) == 0)
    }

    @Test("A failed write phase restores a pre-existing queue entry rather than deleting it")
    func writePhaseFailureRestoresExistingOutboxEntries() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let guest = Self.session(context, owner: nil)
        // An entry this account already owed the server for the same id, and
        // an unrelated one that must not be touched either.
        let stamped = Date(timeIntervalSince1970: 1_000)
        let relevant = SyncOutboxItem(
            identity: SyncOutboxItem.identity(accountID: a, entityType: .session, entityID: guest.id),
            accountID: a,
            entityType: .session,
            entityID: guest.id,
            mutation: .upsert,
            createdAt: stamped,
            updatedAt: stamped
        )
        let unrelatedID = UUID()
        let unrelated = SyncOutboxItem(
            identity: SyncOutboxItem.identity(accountID: a, entityType: .stepResult, entityID: unrelatedID),
            accountID: a,
            entityType: .stepResult,
            entityID: unrelatedID,
            mutation: .upsert,
            createdAt: stamped,
            updatedAt: stamped
        )
        context.insert(relevant)
        context.insert(unrelated)
        try context.save()

        #expect(throws: CommitFailure.self) {
            try Self.failingCommitStore
                .adoptGuestWorkoutData(for: a, in: context, now: Date(timeIntervalSince1970: 9_000))
        }
        try context.save()

        // Deleting it as "cleanup" would drop a mutation still owed to the
        // server, which is worse than the partial adoption it was cleaning up.
        let queued = try AccountScopedSyncStore().outboxItems(for: a, in: context)
        #expect(queued.count == 2)
        let restored = try #require(queued.first { $0.entityID == guest.id })
        #expect(restored.mutation == .upsert)
        #expect(restored.updatedAt == stamped)
        #expect(restored.createdAt == stamped)
        let untouched = try #require(queued.first { $0.entityID == unrelatedID })
        #expect(untouched.updatedAt == stamped)
        #expect(guest.ownerAccountID == nil)
    }

    @Test("A successful adoption still commits everything")
    func successfulAdoptionIsUnaffectedByTheRestorePath() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let session = Self.session(context, owner: nil)
        let result = Self.result(context, of: session, owner: nil)
        try context.save()

        let store = AccountScopedSyncStore()
        let first = try store.adoptGuestWorkoutData(for: a, in: context)
        #expect(first == .init(adoptedSessions: 1, adoptedStepResults: 1))
        #expect(session.ownerAccountID == a)
        #expect(result.ownerAccountID == a)
        #expect(try store.outboxItems(for: a, in: context).count == 2)

        // Idempotency is unchanged by the rewrite.
        let second = try store.adoptGuestWorkoutData(for: a, in: context)
        #expect(second == .nothing)
        #expect(try store.outboxItems(for: a, in: context).count == 2)
        #expect(session.ownerAccountID == a)
    }

    @Test("A refused adoption can be retried once the obstacle is gone")
    func adoptionAfterARefusalStillWorks() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let b = UUID()
        let guest = Self.session(context, owner: nil)
        try context.save()
        let store = AccountScopedSyncStore()

        try store.confirmDeletion(.session, guest.id, for: a, in: context)
        try context.save()
        #expect(throws: AccountScopedSyncError.tombstoneIsTerminal(.session, guest.id)) {
            try store.adoptGuestWorkoutData(for: a, in: context)
        }

        // B has no such history with this id, so B's adoption is unaffected.
        let summary = try store.adoptGuestWorkoutData(for: b, in: context)
        #expect(summary == .init(adoptedSessions: 1, adoptedStepResults: 0))
        #expect(guest.ownerAccountID == b)
    }

    // MARK: - Step result candidates

    @Test("A step result is a candidate only when its session agrees")
    func stepResultCandidatesRequireAnOwnedParent() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let b = UUID()
        let aSession = Self.session(context, owner: a)
        let bSession = Self.session(context, owner: b)
        let guestSession = Self.session(context, owner: nil)

        let good = Self.result(context, of: aSession, owner: a)
        let resultAParentB = Self.result(context, of: bSession, owner: a)
        let resultBParentA = Self.result(context, of: aSession, owner: b)
        let guestResultParentA = Self.result(context, of: aSession, owner: nil)
        let resultAGuestParent = Self.result(context, of: guestSession, owner: a)
        // No SwiftData relationship backs `sessionId`, so a result pointing at
        // a session that is not in the store is representable — and is the
        // case a composite foreign key would reject outright.
        let orphan = StepResult(
            sessionId: UUID(),
            stepId: UUID(),
            setIndex: 0,
            done: true,
            ownerAccountID: a
        )
        context.insert(orphan)
        try context.save()

        let candidates = try AccountScopedSyncStore()
            .syncCandidateStepResults(for: a, in: context)

        #expect(candidates.map(\.id) == [good.id])
        for excluded in [resultAParentB, resultBParentA, guestResultParentA, resultAGuestParent, orphan] {
            #expect(!candidates.contains { $0.id == excluded.id })
        }
    }

    @Test("Adopting a guest session brings its results into the candidate list")
    func adoptionMakesGuestResultsCandidates() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let session = Self.session(context, owner: nil)
        let result = Self.result(context, of: session, owner: nil)
        try context.save()
        let store = AccountScopedSyncStore()

        #expect(try store.syncCandidateStepResults(for: a, in: context).isEmpty)
        try store.adoptGuestWorkoutData(for: a, in: context)
        #expect(try store.syncCandidateStepResults(for: a, in: context).map(\.id) == [result.id])
    }

    // MARK: - Terminal tombstone

    @Test("An acknowledged delete outlives the queue entry that carried it")
    func confirmedDeletionIsRememberedAfterTheOutboxIsCleared() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let session = Self.session(context, owner: a)
        try context.save()
        let store = AccountScopedSyncStore()

        try store.recordSessionMutation(.delete, session, for: a, in: context)
        try context.save()
        try store.confirmDeletion(.session, session.id, for: a, in: context)
        try context.save()

        // The queue is empty — and that is exactly when the old design forgot.
        #expect(try store.outboxItems(for: a, in: context).isEmpty)
        #expect(try store.isTombstoned(.session, session.id, for: a, in: context))
    }

    @Test("An upsert after an acknowledged delete is refused")
    func tombstonedEntitiesCannotComeBack() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let session = Self.session(context, owner: a)
        try context.save()
        let store = AccountScopedSyncStore()

        try store.confirmDeletion(.session, session.id, for: a, in: context)
        try context.save()

        #expect(throws: AccountScopedSyncError.tombstoneIsTerminal(.session, session.id)) {
            try store.recordSessionMutation(.upsert, session, for: a, in: context)
        }
        #expect(try store.outboxItems(for: a, in: context).isEmpty)
    }

    @Test("Acknowledging the same delete twice keeps one tombstone, unchanged")
    func duplicateDeleteAcknowledgementIsIdempotent() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let entity = UUID()
        let store = AccountScopedSyncStore()
        let first = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)

        try store.confirmDeletion(.stepResult, entity, for: a, in: context, now: first)
        try context.save()
        try store.confirmDeletion(.stepResult, entity, for: a, in: context, now: later)
        try context.save()

        let tombstones = try context.fetch(FetchDescriptor<SyncTombstone>())
        #expect(tombstones.count == 1)
        // A duplicate ACK says nothing new; re-stamping would move a terminal
        // fact forward in time.
        #expect(tombstones.first?.deletedAt == first)
    }

    @Test("One account's tombstone says nothing about another's")
    func tombstonesAreScopedPerAccount() throws {
        let context = try Self.makeContext()
        let a = UUID()
        let b = UUID()
        let bSession = Self.session(context, owner: b)
        try context.save()
        let store = AccountScopedSyncStore()

        try store.confirmDeletion(.session, bSession.id, for: a, in: context)
        try context.save()

        // Same entity id, different account: B's row is untouched and still
        // perfectly sendable.
        let tombstonedForA = try store.isTombstoned(.session, bSession.id, for: a, in: context)
        let tombstonedForB = try store.isTombstoned(.session, bSession.id, for: b, in: context)
        #expect(tombstonedForA)
        #expect(!tombstonedForB)
        try store.recordSessionMutation(.upsert, bSession, for: b, in: context)
        try context.save()
        #expect(try store.outboxItems(for: b, in: context).count == 1)
    }

    // MARK: - Runner resume, per scope

    private static func resumeState(step: Int) -> RunnerPersistentState {
        RunnerPersistentState(
            sessionId: UUID(),
            routineId: UUID(),
            phase: .exercise,
            stepIndex: step,
            setIndex: 0,
            currentReps: 10,
            restDeadline: nil,
            lastUpdatedAt: Date()
        )
    }

    @Test("Guest, A and B each keep their own place in a workout")
    func resumeStateIsHeldPerScope() {
        let a = UUID()
        let b = UUID()
        RunnerPersistence.clear(scope: .guest)
        defer {
            RunnerPersistence.clear(scope: .guest)
            RunnerPersistence.clear(scope: .account(a))
            RunnerPersistence.clear(scope: .account(b))
        }

        RunnerPersistence.save(Self.resumeState(step: 2), scope: .guest)
        RunnerPersistence.save(Self.resumeState(step: 3), scope: .account(a))
        // B starting a workout used to overwrite the one device-wide slot, so
        // A came back to a session with nowhere to resume from.
        RunnerPersistence.save(Self.resumeState(step: 7), scope: .account(b))

        #expect(RunnerPersistence.load(scope: .account(a))?.stepIndex == 3)
        #expect(RunnerPersistence.load(scope: .account(b))?.stepIndex == 7)
        #expect(RunnerPersistence.load(scope: .guest)?.stepIndex == 2)

        // Back and forth: each slot is still its own.
        #expect(RunnerPersistence.load(scope: .account(a))?.stepIndex == 3)
        #expect(RunnerPersistence.load(scope: .account(b))?.stepIndex == 7)
    }

    @Test("Finishing one account's workout clears that slot and no other")
    func clearingResumeStateIsScoped() {
        let a = UUID()
        let b = UUID()
        RunnerPersistence.clear(scope: .guest)
        defer {
            RunnerPersistence.clear(scope: .guest)
            RunnerPersistence.clear(scope: .account(a))
            RunnerPersistence.clear(scope: .account(b))
        }

        RunnerPersistence.save(Self.resumeState(step: 2), scope: .guest)
        RunnerPersistence.save(Self.resumeState(step: 3), scope: .account(a))
        RunnerPersistence.save(Self.resumeState(step: 7), scope: .account(b))

        RunnerPersistence.clear(scope: .account(a))

        #expect(RunnerPersistence.load(scope: .account(a)) == nil)
        #expect(RunnerPersistence.load(scope: .account(b))?.stepIndex == 7)
        #expect(RunnerPersistence.load(scope: .guest)?.stepIndex == 2)
    }

    @Test("Resume state written before accounts existed reads back as guest")
    func legacyResumeStateBelongsToGuest() {
        let a = UUID()
        RunnerPersistence.clear(scope: .guest)
        defer {
            RunnerPersistence.clear(scope: .guest)
            RunnerPersistence.clear(scope: .account(a))
        }

        // The pre-account key is the guest slot, so an upgrade loses no
        // in-progress workout — and hands none to whoever signs in next.
        #expect(RunnerPersistence.key(for: .guest) == "runner.persistent.state")
        RunnerPersistence.save(Self.resumeState(step: 4), scope: .guest)

        #expect(RunnerPersistence.load(scope: .guest)?.stepIndex == 4)
        #expect(RunnerPersistence.load(scope: .account(a)) == nil)
    }

    @Test("An unknown scope has no slot to read or write")
    func undeterminedScopeHasNoResumeSlot() {
        RunnerPersistence.clear(scope: .guest)
        defer { RunnerPersistence.clear(scope: .guest) }

        RunnerPersistence.save(Self.resumeState(step: 5), scope: .undetermined)

        #expect(RunnerPersistence.key(for: .undetermined) == nil)
        #expect(RunnerPersistence.load(scope: .undetermined) == nil)
        // And nothing leaked into the guest slot on the way.
        #expect(RunnerPersistence.load(scope: .guest) == nil)
    }

    @Test("Account slots are keyed by the server account UUID alone")
    func resumeKeysCarryOnlyTheAccountUUID() {
        let a = UUID()
        let b = UUID()
        let key = try? #require(RunnerPersistence.key(for: .account(a)))

        #expect(key == "runner.persistent.state.\(a.uuidString)")
        #expect(RunnerPersistence.key(for: .account(a)) != RunnerPersistence.key(for: .account(b)))
        #expect(RunnerPersistence.key(for: .account(a)) != RunnerPersistence.key(for: .guest))
    }
}
