//
//  RoutineOriginTests.swift
//  Pulse CueTests
//
//  Routine origin semantics: Quick Plan "この内容で開始" creates a
//  `.workoutGenerated` routine (kept out of the library), "保存" creates a
//  `.userSaved` one, and combining the two never duplicates — an explicit save
//  promotes a previously-generated routine. Existing / manually created
//  routines default to `.userSaved`, so the library is unchanged.
//

import Combine
import Foundation
import SwiftData
import Testing
import UIKit
import UserNotifications
@testable import Pulse_Cue

@MainActor
struct RoutineOriginTests {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Routine.self, Step.self, Session.self, StepResult.self, Gym.self, GymMachine.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private func makeViewModel(_ context: ModelContext) -> GeneratedPlanViewModel {
        let repo = GymRepository(modelContext: context)
        let gym = repo.createGym(name: "Test", makeActive: true)
        repo.setMachines(["bench_press", "chest_press", "pec_deck", "dumbbells"], for: gym)
        let vm = GeneratedPlanViewModel(
            gym: gym,
            request: QuickPlanRequest(bodyParts: [.chest], duration: .standardPlus, intensity: .standard)
        )
        vm.configure(modelContext: context)
        return vm
    }

    private func runner() -> RunnerViewModel {
        RunnerViewModel(settings: SettingsStore(defaults: UserDefaults(suiteName: "test.origin.\(UUID().uuidString)")!))
    }

    private func routines(_ context: ModelContext) -> [Routine] {
        (try? context.fetch(FetchDescriptor<Routine>())) ?? []
    }

    @Test
    func newRoutineDefaultsToUserSaved() {
        #expect(Routine(name: "手動").origin == .userSaved)
    }

    @Test
    func quickPlanSaveCreatesOneUserSavedRoutine() throws {
        let context = try makeContext()
        let vm = makeViewModel(context)
        vm.saveAsRoutine()
        let all = routines(context)
        #expect(all.count == 1)
        #expect(all.first?.origin == .userSaved)
    }

    @Test
    func quickPlanStartCreatesGeneratedRoutine() throws {
        let context = try makeContext()
        let vm = makeViewModel(context)
        let r = runner(); r.configure(modelContext: context)
        vm.startWorkout(restStore: RoutineRestPreferenceStore(), appDefaultRestSeconds: 60, runner: r)
        let all = routines(context)
        #expect(all.count == 1)
        #expect(all.first?.origin == .workoutGenerated)
    }

    @Test
    func startThenSavePromotesWithoutDuplicating() throws {
        let context = try makeContext()
        let vm = makeViewModel(context)
        let r = runner(); r.configure(modelContext: context)
        vm.startWorkout(restStore: RoutineRestPreferenceStore(), appDefaultRestSeconds: 60, runner: r)
        vm.saveAsRoutine()
        let all = routines(context)
        #expect(all.count == 1)                       // no duplicate
        #expect(all.first?.origin == .userSaved)      // promoted
    }

    @Test
    func saveThenStartStaysASingleUserSavedRoutine() throws {
        let context = try makeContext()
        let vm = makeViewModel(context)
        let r = runner(); r.configure(modelContext: context)
        vm.saveAsRoutine()
        vm.startWorkout(restStore: RoutineRestPreferenceStore(), appDefaultRestSeconds: 60, runner: r)
        let all = routines(context)
        #expect(all.count == 1)
        #expect(all.first?.origin == .userSaved)
    }

    @Test
    func repeatedQuickPlanStartsDoNotPolluteTheLibrary() throws {
        let context = try makeContext()
        // Two separate Quick Plan previews, each started (not saved).
        for _ in 0..<2 {
            let vm = makeViewModel(context)
            let r = runner(); r.configure(modelContext: context)
            vm.startWorkout(restStore: RoutineRestPreferenceStore(), appDefaultRestSeconds: 60, runner: r)
        }
        let all = routines(context)
        let library = all.filter { $0.origin == .userSaved }
        #expect(all.count == 2)         // both persist for Runner / History
        #expect(library.isEmpty)        // none appear in the routine library
    }
}

// MARK: - Free Workout domain

@MainActor
struct FreeWorkoutSessionTests {

    private let account = UUID()

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Routine.self, Step.self, Session.self, StepResult.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    private func all<T: PersistentModel>(_ type: T.Type, _ context: ModelContext) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }

    private func start(_ context: ModelContext, scope: WorkoutDataScope = .guest, at date: Date = Date()) throws -> FreeWorkoutSession {
        try #require(FreeWorkoutSession.start(in: context, scope: scope, now: date).session)
    }

    /// A routine workout recorded through the Runner's own write path.
    private func routineWorkout(_ context: ModelContext, exerciseId: String, sets: [(reps: Int, kg: Double)],
                                plannedSets: Int, at date: Date, owner: UUID? = nil) {
        let routine = Routine(name: "胸の日")
        let step = Step(routineId: routine.id, order: 0, title: "ベンチプレス", sets: plannedSets, repsTarget: 10,
                        restSeconds: 90, exerciseId: exerciseId)
        let session = Session(routineId: routine.id, dayDate: date, startedAt: date, endedAt: date, status: .completed,
                              ownerAccountID: owner)
        context.insert(routine); context.insert(step); context.insert(session)
        for (index, set) in sets.enumerated() {
            StepResultWriter.record(in: context, sessionId: session.id, ownerAccountID: owner, step: step,
                                    setIndex: index, done: true, actualReps: set.reps, weightKg: set.kg)
        }
    }

    // MARK: creation / ownership

    @Test func startsAnEmptyActiveWorkoutOnAHiddenFreeWorkoutRoutine() throws {
        let context = try makeContext()
        let free = try start(context)
        #expect(free.routine.origin == .freeWorkout)
        #expect(free.routine.name == "フリーワークアウト")
        #expect(free.session.routineId == free.routine.id)
        #expect(free.session.status == .inProgress)
        #expect(free.session.endedAt == nil)
        #expect(free.steps.isEmpty)
        #expect(free.isActive)
        #expect(all(Session.self, context).count == 1)
    }

    @Test func ownerFollowsTheRunnerRuleAndAnUnknownScopeStartsNothing() throws {
        let context = try makeContext()
        #expect(try start(context, scope: .guest).session.ownerAccountID == nil)
        #expect(try start(context, scope: .account(account)).session.ownerAccountID == account)
        #expect(FreeWorkoutSession.start(in: context, scope: .undetermined).session == nil)
        #expect(all(Session.self, context).count == 2)
        #expect(all(Routine.self, context).count == 2)
    }

    @Test func resultsTakeTheSessionOwner() throws {
        let context = try makeContext()
        let free = try start(context, scope: .account(account))
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        #expect(free.completeSet(at: 0, of: step, reps: 10, weightKg: 80)?.ownerAccountID == account)
    }

    @Test func resumeOnlyAttachesToThisScopesFreeWorkouts() throws {
        let context = try makeContext()
        let free = try start(context, scope: .account(account))
        #expect(FreeWorkoutSession.resume(free.session, in: context, scope: .account(account)) != nil)
        #expect(FreeWorkoutSession.resume(free.session, in: context, scope: .guest) == nil)
        let routine = Routine(name: "通常")
        let session = Session(routineId: routine.id, dayDate: Date())
        context.insert(routine); context.insert(session)
        #expect(FreeWorkoutSession.resume(session, in: context, scope: .guest) == nil)
    }

    // MARK: exercises

    @Test func addingExercisesAppendsStepsAndAllowsDuplicates() throws {
        let context = try makeContext()
        let free = try start(context)
        let bench = try #require(ExerciseLibrary.all.first)
        let a = try #require(free.addExercise(bench))
        let b = try #require(free.addExercise(bench))
        #expect(a.id != b.id)
        #expect(free.steps.map(\.order) == [0, 1])
        #expect(a.exerciseId == bench.id.rawValue && a.title == bench.displayName)
        #expect(a.routineId == free.routine.id && a.sets == 1)
    }

    @Test func anUnrecordedExerciseCanBeRemovedButARecordedOneCannot() throws {
        let context = try makeContext()
        let free = try start(context)
        let a = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        let b = try #require(free.addExercise(exerciseId: "incline_chest_press", title: "インクライン"))
        let c = try #require(free.addExercise(exerciseId: "pec_deck_fly", title: "フライ"))
        free.skipSet(at: 0, of: c)

        #expect(free.removeExercise(b))
        #expect(free.steps.map(\.id) == [a.id, c.id])
        #expect(free.steps.map(\.order) == [0, 1])

        #expect(!free.canRemoveExercise(c))
        #expect(!free.removeExercise(c))   // guarded in the domain, not only the UI
        #expect(free.steps.count == 2)
    }

    @Test func reorderingOnlyChangesStepOrder() throws {
        let context = try makeContext()
        let free = try start(context)
        let bench = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        let incline = try #require(free.addExercise(exerciseId: "incline_chest_press", title: "インクライン"))
        let fly = try #require(free.addExercise(exerciseId: "pec_deck_fly", title: "フライ"))
        let result = try #require(free.completeSet(at: 0, of: incline, reps: 10, weightKg: 30))

        #expect(free.moveExercise(from: 2, to: 1))
        #expect(free.steps.map(\.id) == [bench.id, fly.id, incline.id])
        #expect(result.stepId == incline.id)
        #expect(result.exerciseIdAtExecution == "incline_chest_press")
        #expect(result.exerciseTitleAtExecution == "インクライン")
    }

    // MARK: sets

    @Test func plannedSetsFollowTheLiveSetListUpAndDown() throws {
        let context = try makeContext()
        let free = try start(context)
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 3))
        free.completeSet(at: 0, of: step, reps: 10, weightKg: 80)
        free.completeSet(at: 1, of: step, reps: 9, weightKg: 80)
        #expect(free.results(for: step).map(\.plannedSetsAtExecution) == [3, 3])

        #expect(free.addSet(to: step))
        #expect(step.sets == 4)
        #expect(free.results(for: step).map(\.plannedSetsAtExecution) == [4, 4])

        #expect(free.removeSet(at: 3, from: step))   // an unrecorded row
        #expect(free.removeSet(at: 2, from: step))
        #expect(step.sets == 2)
        #expect(free.results(for: step).map(\.plannedSetsAtExecution) == [2, 2])
    }

    @Test func removingARecordedSetShiftsLaterSetsDownAndTouchesNothingElse() throws {
        let context = try makeContext()
        let free = try start(context)
        let bench = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 3))
        let other = try #require(free.addExercise(exerciseId: "pec_deck_fly", title: "フライ", initialSets: 2))
        free.completeSet(at: 0, of: bench, reps: 10, weightKg: 80)
        free.completeSet(at: 1, of: bench, reps: 9, weightKg: 80)
        free.completeSet(at: 2, of: bench, reps: 8, weightKg: 75)
        free.completeSet(at: 1, of: other, reps: 12, weightKg: 20)

        #expect(free.removeSet(at: 1, from: bench))
        let remaining = free.results(for: bench)
        #expect(remaining.map(\.setIndex) == [0, 1])          // dense: History labels by setIndex + 1
        #expect(remaining.map(\.actualReps) == [10, 8])
        #expect(remaining.map(\.plannedSetsAtExecution) == [2, 2])
        #expect(free.results(for: other).map(\.setIndex) == [1])
        #expect(free.results(for: other).map(\.plannedSetsAtExecution) == [2])
    }

    @Test func theLastRowIsClearedNotRemovedAndOutOfRangeIsRefused() throws {
        let context = try makeContext()
        let free = try start(context)
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        free.completeSet(at: 0, of: step, reps: 10, weightKg: 80)
        #expect(free.removeSet(at: 0, from: step))
        #expect(step.sets == 1)
        #expect(free.results(for: step).isEmpty)
        #expect(free.completeSet(at: 1, of: step, reps: 10, weightKg: 80) == nil)
        #expect(!free.removeSet(at: 5, from: step))
    }

    // MARK: snapshots

    @Test func overwritingASetKeepsOneConsistentSnapshot() throws {
        let context = try makeContext()
        let free = try start(context)
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 2))
        free.completeSet(at: 0, of: step, reps: 10, weightKg: 80)
        // A later live edit must not reach results already written.
        step.title = "別名"
        step.exerciseId = "other"
        free.completeSet(at: 1, of: step, reps: 9, weightKg: 80)
        free.completeSet(at: 0, of: step, reps: 8, weightKg: 82.5)   // Back / overwrite

        let results = free.results(for: step)
        #expect(results.count == 2)
        #expect(Set(results.map(\.exerciseIdAtExecution)) == ["bench_press"])
        #expect(Set(results.map(\.exerciseTitleAtExecution)) == ["ベンチプレス"])
        #expect(results.map(\.actualReps) == [8, 9])
        #expect(results.map(\.weightKg) == [82.5, 80])
        #expect(HistoricalExerciseIdentity.resolve(results: results, step: step).source == .snapshot)
    }

    // MARK: finish / discard

    @Test func finishSavesPerformedWorkTrimsUnloggedRowsAndDropsEmptyExercises() throws {
        let context = try makeContext()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let free = try self.start(context, at: start)
        let bench = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 4))
        let empty = try #require(free.addExercise(exerciseId: "pec_deck_fly", title: "フライ", initialSets: 3))
        let incline = try #require(free.addExercise(exerciseId: "incline_chest_press", title: "インクライン", initialSets: 3))
        free.completeSet(at: 0, of: bench, reps: 10, weightKg: 80)
        free.completeSet(at: 2, of: bench, reps: 9, weightKg: 80)    // row 1 and 3 never logged
        free.skipSet(at: 0, of: incline)
        free.completeSet(at: 1, of: incline, reps: 10, weightKg: 30)

        #expect(free.finish(now: start.addingTimeInterval(3600)) == .saved)
        #expect(free.session.status == .completed)
        #expect(free.session.totalSeconds == 3600)
        #expect(free.session.endedAt == start.addingTimeInterval(3600))
        #expect(free.steps.map(\.id) == [bench.id, incline.id])
        #expect(free.steps.map(\.order) == [0, 1])
        #expect(!all(Step.self, context).contains { $0.id == empty.id })
        #expect(bench.sets == 2)
        #expect(free.results(for: bench).map(\.setIndex) == [0, 1])
        #expect(free.results(for: bench).map(\.plannedSetsAtExecution) == [2, 2])
        // A skip is logged, so it stays planned-but-not-done — the record is
        // honestly incomplete rather than a false full one.
        #expect(free.results(for: incline).map(\.plannedSetsAtExecution) == [2, 2])
        #expect(all(Routine.self, context).contains { $0.id == free.routine.id })
        #expect(!free.isActive)
        #expect(free.addExercise(exerciseId: "x", title: "x") == nil)
        #expect(free.finish() == .notActive)
    }

    @Test func anEmptyOrSkipOnlyWorkoutIsDiscardedEntirely() throws {
        for skipOnly in [false, true] {
            let context = try makeContext()
            let free = try start(context)
            let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 2))
            if skipOnly { free.skipSet(at: 0, of: step) }
            #expect(free.finish() == .discarded)
            #expect(all(Session.self, context).isEmpty)
            #expect(all(Routine.self, context).isEmpty)
            #expect(all(Step.self, context).isEmpty)
            #expect(all(StepResult.self, context).isEmpty)
        }
    }

    @Test func discardRemovesOnlyThisWorkout() throws {
        let context = try makeContext()
        routineWorkout(context, exerciseId: "bench_press", sets: [(10, 80)], plannedSets: 1, at: Date())
        let free = try start(context)
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        free.completeSet(at: 0, of: step, reps: 10, weightKg: 80)
        #expect(free.discard())
        #expect(all(Session.self, context).count == 1)
        #expect(all(Routine.self, context).map(\.origin) == [.userSaved])
        #expect(all(StepResult.self, context).count == 1)
        #expect(!free.discard())
    }

    // MARK: previous performance / progression

    @Test func aFreeWorkoutIsTheRoutinesPreviousPerformanceAndViceVersa() throws {
        let context = try makeContext()
        let day1 = Date(timeIntervalSince1970: 1_000_000)
        let free = try start(context, at: day1)
        let bench = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        free.completeSet(at: 0, of: bench, reps: 10, weightKg: 80)
        free.finish(now: day1.addingTimeInterval(1800))

        let previous = try #require(PreviousPerformanceQuery.latest(
            exerciseId: "bench_press", excludingSessionId: nil, expectedSets: 1,
            steps: all(Step.self, context), sessions: all(Session.self, context), results: all(StepResult.self, context)))
        #expect(previous.sets.map(\.reps) == [10])
        #expect(previous.sets.map(\.weightKg) == [80])

        // Routine → a later Free Workout.
        routineWorkout(context, exerciseId: "bench_press", sets: [(8, 85), (8, 85)], plannedSets: 2,
                       at: day1.addingTimeInterval(86_400))
        let next = try start(context, at: day1.addingTimeInterval(2 * 86_400))
        let step = try #require(next.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        step.sets = 2
        let fromRoutine = try #require(next.previousPerformance(for: step))
        #expect(fromRoutine.sets.map(\.weightKg) == [85, 85])
        #expect(next.initialEntry(forSetAt: 0, of: step) == (8, 85))
    }

    // MARK: history scope = the session's own owner

    private func mixedOwnerHistory(_ context: ModelContext, accountB: UUID) {
        let day = Date(timeIntervalSince1970: 500_000)
        routineWorkout(context, exerciseId: "bench_press", sets: [(10, 60)], plannedSets: 1, at: day)
        routineWorkout(context, exerciseId: "bench_press", sets: [(10, 100)], plannedSets: 1,
                       at: day.addingTimeInterval(60), owner: account)
        routineWorkout(context, exerciseId: "bench_press", sets: [(10, 120)], plannedSets: 1,
                       at: day.addingTimeInterval(120), owner: accountB)
    }

    @Test func aGuestFreeWorkoutReadsOnlyGuestHistory() throws {
        let context = try makeContext()
        mixedOwnerHistory(context, accountB: UUID())
        let free = try start(context, scope: .guest)
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        #expect(free.previousPerformance(for: step)?.sets.map(\.weightKg) == [60])
        #expect(free.initialEntry(forSetAt: 0, of: step) == (10, 60))
    }

    @Test func anAccountFreeWorkoutReadsOnlyItsOwnersHistory() throws {
        let context = try makeContext()
        mixedOwnerHistory(context, accountB: UUID())
        let free = try start(context, scope: .account(account))
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        #expect(free.previousPerformance(for: step)?.sets.map(\.weightKg) == [100])
        #expect(free.initialEntry(forSetAt: 0, of: step) == (10, 100))
    }

    /// The scope comes from the session, so a later change of the current
    /// account (here: re-attaching the handle while the app is a guest is
    /// refused, and the original handle keeps reading account A).
    @Test func theHistoryScopeIsFixedByTheSessionOwnerNotTheCurrentAccount() throws {
        let context = try makeContext()
        mixedOwnerHistory(context, accountB: UUID())
        let free = try start(context, scope: .account(account))
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        #expect(FreeWorkoutSession.resume(free.session, in: context, scope: .guest) == nil)
        let reattached = try #require(FreeWorkoutSession.resume(free.session, in: context, scope: .account(account)))
        #expect(reattached.previousPerformance(for: step)?.sets.map(\.weightKg) == [100])
        #expect(free.previousPerformance(for: step)?.sets.map(\.weightKg) == [100])
    }

    @Test func noOwnHistoryNeverFallsBackToAnotherOwner() throws {
        let context = try makeContext()
        routineWorkout(context, exerciseId: "bench_press", sets: [(10, 60)], plannedSets: 1, at: Date())   // guest
        let free = try start(context, scope: .account(account))
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        #expect(free.previousPerformance(for: step) == nil)
        #expect(free.initialEntry(forSetAt: 0, of: step) == (FreeWorkoutSession.defaultRepsTarget, nil))
    }

    // MARK: blank rows vs skips (P2-1)

    @Test func blankRowsAreDraftsNotPlannedSets() throws {
        let context = try makeContext()
        let free = try start(context)
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 4))
        free.completeSet(at: 0, of: step, reps: 10, weightKg: 80)
        free.completeSet(at: 1, of: step, reps: 10, weightKg: 80)
        #expect(free.finish() == .saved)
        #expect(free.results(for: step).count == 2)
        #expect(free.results(for: step).map(\.plannedSetsAtExecution) == [2, 2])
        #expect(step.sets == 2)
    }

    @Test func aSkipIsAPlannedSetThatWasNotPerformed() throws {
        let context = try makeContext()
        let free = try start(context)
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 3))
        free.completeSet(at: 0, of: step, reps: 10, weightKg: 80)
        free.completeSet(at: 1, of: step, reps: 10, weightKg: 80)
        free.skipSet(at: 2, of: step)
        #expect(free.finish() == .saved)
        #expect(free.results(for: step).count == 3)
        #expect(free.results(for: step).map(\.plannedSetsAtExecution) == [3, 3, 3])
        let previous = try #require(PreviousPerformanceQuery.latest(
            exerciseId: "bench_press", excludingSessionId: nil, expectedSets: 3,
            steps: all(Step.self, context), sessions: all(Session.self, context), results: all(StepResult.self, context)))
        #expect(!previous.isComplete(expectedSets: 3))
    }

    @Test func initialEntryPrefersTheSetAboveThenThePreviousWorkout() throws {
        let context = try makeContext()
        let free = try start(context)
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 2))
        #expect(free.initialEntry(forSetAt: 0, of: step) == (10, nil))
        free.completeSet(at: 0, of: step, reps: 9, weightKg: 77.5)
        #expect(free.initialEntry(forSetAt: 1, of: step) == (9, 77.5))
    }

    /// The case `nil` would get wrong: a set added mid-workout makes four,
    /// and a 3-set routine must still see a 4-set record, not a legacy one
    /// judged by today's count.
    @Test func aGrownFreeWorkoutIsReadAsItsFinalStructure() throws {
        let context = try makeContext()
        let free = try start(context)
        let bench = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 3))
        for index in 0..<3 { free.completeSet(at: index, of: bench, reps: 10, weightKg: 80) }
        free.addSet(to: bench)
        free.completeSet(at: 3, of: bench, reps: 10, weightKg: 80)
        _ = free.finish()

        let previous = try #require(PreviousPerformanceQuery.latest(
            exerciseId: "bench_press", excludingSessionId: nil, expectedSets: 3,
            steps: all(Step.self, context), sessions: all(Session.self, context), results: all(StepResult.self, context)))
        #expect(previous.plannedSetCount == 4)
        #expect(!previous.hasInconsistentPlannedSets)
        let suggestion = try #require(ProgressionRule.suggest(
            previous: previous, baselineReps: 10, expectedSets: 3,
            allowsRepProgression: true, allowsWeightProgression: true))
        #expect(suggestion.previousSetCount == 4)
        #expect(suggestion.expectedSetCount == 3)
    }

    @Test func aShrunkOrPartlyLoggedFreeWorkoutNeverUnlocksAProgression() throws {
        let context = try makeContext()
        let free = try start(context)
        let bench = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 3))
        free.completeSet(at: 0, of: bench, reps: 10, weightKg: 80)
        free.completeSet(at: 1, of: bench, reps: 10, weightKg: 80)
        free.skipSet(at: 2, of: bench)
        _ = free.finish()

        let previous = try #require(PreviousPerformanceQuery.latest(
            exerciseId: "bench_press", excludingSessionId: nil, expectedSets: 2,
            steps: all(Step.self, context), sessions: all(Session.self, context), results: all(StepResult.self, context)))
        #expect(previous.plannedSetCount == 3)
        #expect(!previous.isComplete(expectedSets: 2))   // nil would have read 2 done == 2 expected as full
        let suggestion = try #require(ProgressionRule.suggest(
            previous: previous, baselineReps: 10, expectedSets: 2,
            allowsRepProgression: true, allowsWeightProgression: true))
        #expect(suggestion.kind != .increaseWeight && suggestion.kind != .increaseReps)
    }

    // MARK: history / progress / library

    @Test func aFinishedFreeWorkoutReachesHistoryAndProgress() throws {
        let context = try makeContext()
        let free = try start(context)
        let bench = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 2))
        free.completeSet(at: 0, of: bench, reps: 10, weightKg: 80)
        free.completeSet(at: 1, of: bench, reps: 9, weightKg: 80)
        _ = free.finish()

        let groups = SessionHistoryPresentation.groupedResults(results: free.results(for: bench), steps: free.steps)
        #expect(groups.map(\.title) == ["ベンチプレス"])
        #expect(groups.first?.results.map { $0.setIndex + 1 } == [1, 2])

        let insights = WorkoutProgressQuery.exerciseInsights(
            steps: all(Step.self, context), sessions: all(Session.self, context), results: all(StepResult.self, context))
        #expect(insights.map(\.exerciseId) == ["bench_press"])
        #expect(insights.first?.latestReps == [10, 9])
    }

    @Test func theLibraryHidesFreeWorkoutRoutinesOnly() {
        let saved = Routine(name: "保存", origin: .userSaved)
        let generated = Routine(name: "Quick", origin: .workoutGenerated)
        let free = Routine(name: "フリーワークアウト", origin: .freeWorkout)
        #expect(RoutineLibrary.startable(from: [saved, generated, free]).map(\.id) == [saved.id])
        #expect(!RoutineLibrary.hasStartable([generated, free]))
        #expect(RoutineLibrary.hasStartable([free, saved]))
    }
}

// MARK: - Free Workout recovery

@MainActor
struct FreeWorkoutRecoveryTests {

    private let account = UUID()

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Routine.self, Step.self, Session.self, StepResult.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func all<T: PersistentModel>(_ type: T.Type, _ context: ModelContext) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }

    private func start(_ context: ModelContext, scope: WorkoutDataScope = .guest, at date: Date = Date()) throws -> FreeWorkoutSession {
        try #require(FreeWorkoutSession.start(in: context, scope: scope, now: date).session)
    }

    /// An in-progress session on a routine of the given origin, as the Runner
    /// or Quick Plan would leave it — or a leftover second Free Workout, which
    /// `start` itself would now refuse to create.
    @discardableResult
    private func leftover(_ context: ModelContext, origin: RoutineOrigin, owner: UUID? = nil, at date: Date) -> Session {
        let routine = Routine(name: "x", origin: origin)
        let session = Session(routineId: routine.id, dayDate: date, startedAt: date, ownerAccountID: owner)
        context.insert(routine); context.insert(session)
        return session
    }

    // MARK: discovery

    @Test func findsOnlyInProgressFreeWorkoutsOfThisScope() throws {
        let context = ModelContext(try makeContainer())
        #expect(FreeWorkoutRecovery.candidates(in: context, scope: .guest).isEmpty)

        leftover(context, origin: .userSaved, at: Date())
        leftover(context, origin: .workoutGenerated, at: Date())
        leftover(context, origin: .freeWorkout, owner: account, at: Date())
        let finished = try start(context)
        let step = try #require(finished.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        finished.completeSet(at: 0, of: step, reps: 10, weightKg: 80)
        finished.finish()
        #expect(FreeWorkoutRecovery.candidates(in: context, scope: .guest).isEmpty)
        #expect(!FreeWorkoutRecovery.hasActiveFreeWorkout(in: context, scope: .guest))

        let active = try start(context)
        #expect(FreeWorkoutRecovery.candidates(in: context, scope: .guest).map(\.id) == [active.session.id])
        #expect(FreeWorkoutRecovery.candidates(in: context, scope: .account(account)).count == 1)
        #expect(FreeWorkoutRecovery.candidates(in: context, scope: .undetermined).isEmpty)   // fail closed
    }

    @Test func aSessionWhoseRoutineIsGoneIsNotClaimed() throws {
        let context = ModelContext(try makeContainer())
        context.insert(Session(routineId: UUID(), dayDate: Date()))
        #expect(FreeWorkoutRecovery.candidates(in: context, scope: .guest).isEmpty)
    }

    @Test func severalLeftoversAreAllListedNewestFirstAndNoneDeleted() throws {
        let context = ModelContext(try makeContainer())
        let base = Date(timeIntervalSince1970: 1_000_000)
        let old = leftover(context, origin: .freeWorkout, at: base)
        let newer = leftover(context, origin: .freeWorkout, at: base.addingTimeInterval(86_400))
        let candidates = FreeWorkoutRecovery.candidates(in: context, scope: .guest)
        #expect(candidates.map(\.id) == [newer.id, old.id])
        #expect(FreeWorkoutRecovery.latest(in: context, scope: .guest)?.id == newer.id)
        #expect(candidates.last?.startedAt == base)   // a day-old one is still offered, with its start time
        #expect(all(Session.self, context).count == 2)
    }

    // MARK: start guard

    @Test func aSecondStartInTheSameScopeCreatesNothing() throws {
        let context = ModelContext(try makeContainer())
        let first = try start(context)
        guard case let .activeWorkoutExists(existing) = FreeWorkoutSession.start(in: context, scope: .guest) else {
            Issue.record("expected the existing workout"); return
        }
        #expect(existing.map(\.id) == [first.session.id])
        #expect(all(Session.self, context).count == 1)
        #expect(all(Routine.self, context).count == 1)
        // Another owner is not blocked by it.
        #expect(FreeWorkoutSession.start(in: context, scope: .account(account)).session != nil)
        if case .scopeUndetermined = FreeWorkoutSession.start(in: context, scope: .undetermined) {} else {
            Issue.record("expected scopeUndetermined")
        }
    }

    // MARK: resume

    @Test func resumeRefusesWhatItMustNotReattachTo() throws {
        let context = ModelContext(try makeContainer())
        let free = try start(context, scope: .account(account))
        let candidate = try #require(FreeWorkoutRecovery.latest(in: context, scope: .account(account)))
        #expect(FreeWorkoutRecovery.resume(candidate, in: context, scope: .account(account)) != nil)
        #expect(FreeWorkoutRecovery.resume(candidate, in: context, scope: .guest) == nil)

        #expect(FreeWorkoutSession.resume(leftover(context, origin: .userSaved, at: Date()), in: context, scope: .guest) == nil)
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        free.completeSet(at: 0, of: step, reps: 10, weightKg: 80)
        _ = free.finish()
        #expect(FreeWorkoutRecovery.resume(candidate, in: context, scope: .account(account)) == nil)
    }

    @Test func partiallyWrittenDataIsListedNotResumableButDiscardable() throws {
        let context = ModelContext(try makeContainer())
        let free = try start(context)
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        free.completeSet(at: 0, of: step, reps: 10, weightKg: 80)
        context.delete(step)   // a result now points at a step that is gone

        let candidate = try #require(FreeWorkoutRecovery.latest(in: context, scope: .guest))
        #expect(!candidate.isResumable)
        #expect(FreeWorkoutRecovery.resume(candidate, in: context, scope: .guest) == nil)
        #expect(FreeWorkoutRecovery.discard(candidate, in: context, scope: .guest))
        #expect(all(Session.self, context).isEmpty)
        #expect(all(Routine.self, context).isEmpty)
        #expect(all(StepResult.self, context).isEmpty)
    }

    // MARK: discard

    @Test func discardRemovesOnlyThatWorkoutAndNeverAFinishedOne() throws {
        let context = ModelContext(try makeContainer())
        let done = try start(context, scope: .account(account))
        let doneStep = try #require(done.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        done.completeSet(at: 0, of: doneStep, reps: 10, weightKg: 80)
        let staleCandidate = try #require(FreeWorkoutRecovery.latest(in: context, scope: .account(account)))
        done.finish()
        let runner = leftover(context, origin: .userSaved, at: Date())

        let active = try start(context)
        let step = try #require(active.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        active.completeSet(at: 0, of: step, reps: 8, weightKg: 60)
        let candidate = try #require(FreeWorkoutRecovery.latest(in: context, scope: .guest))

        #expect(!FreeWorkoutRecovery.discard(candidate, in: context, scope: .account(account)))   // wrong scope
        #expect(FreeWorkoutRecovery.discard(candidate, in: context, scope: .guest))
        #expect(Set(all(Session.self, context).map(\.id)) == [done.session.id, runner.id])
        #expect(Set(all(Routine.self, context).map(\.origin)) == [.freeWorkout, .userSaved])
        #expect(all(StepResult.self, context).map(\.sessionId) == [done.session.id])
        #expect(all(Step.self, context).map(\.id) == [doneStep.id])

        #expect(!FreeWorkoutRecovery.discard(staleCandidate, in: context, scope: .account(account)))   // finished
        #expect(done.session.status == .completed)
    }

    // MARK: relaunch

    /// Handles dropped, a fresh context on the same store: the workout is
    /// found again, resumed with its data, and stays fully editable.
    @Test func aRelaunchRediscoversResumesAndContinuesTheWorkout() throws {
        let container = try makeContainer()
        let startedAt = Date(timeIntervalSince1970: 1_000_000)
        do {
            let context = ModelContext(container)
            let free = try start(context, at: startedAt)
            let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 2))
            free.completeSet(at: 0, of: step, reps: 10, weightKg: 80)
            try context.save()
        }

        let context = ModelContext(container)
        let candidate = try #require(FreeWorkoutRecovery.latest(in: context, scope: .guest))
        #expect(candidate.stepCount == 1 && candidate.loggedResultCount == 1 && candidate.isResumable)
        let resumed = try #require(FreeWorkoutRecovery.resume(candidate, in: context, scope: .guest))
        let bench = try #require(resumed.steps.first)
        #expect(resumed.results(for: bench).map(\.weightKg) == [80])
        #expect(resumed.elapsedSeconds(now: startedAt.addingTimeInterval(5400)) == 5400)   // closed time counts

        #expect(resumed.addSet(to: bench))
        resumed.completeSet(at: 1, of: bench, reps: 9, weightKg: 80)
        resumed.completeSet(at: 2, of: bench, reps: 8, weightKg: 80)
        let fly = try #require(resumed.addExercise(exerciseId: "pec_deck_fly", title: "フライ"))
        resumed.completeSet(at: 0, of: fly, reps: 12, weightKg: 20)
        #expect(resumed.finish(now: startedAt.addingTimeInterval(5400)) == .saved)
        #expect(resumed.session.totalSeconds == 5400)
        #expect(resumed.results(for: bench).map(\.plannedSetsAtExecution) == [3, 3, 3])
        #expect(FreeWorkoutRecovery.candidates(in: context, scope: .guest).isEmpty)
    }

    // MARK: stale candidates

    @Test func discardingTheSameCandidateTwiceIsASafeNoOp() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let other = try start(context, scope: .account(account))
        let free = try start(context)
        free.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        let candidate = try #require(FreeWorkoutRecovery.latest(in: context, scope: .guest))

        #expect(FreeWorkoutRecovery.discard(candidate, in: context, scope: .guest))
        try context.save()
        #expect(!FreeWorkoutRecovery.discard(candidate, in: context, scope: .guest))   // second tap
        #expect(FreeWorkoutRecovery.resume(candidate, in: context, scope: .guest) == nil)
        #expect(all(Session.self, context).map(\.id) == [other.session.id])
        #expect(all(Routine.self, context).map(\.id) == [other.routine.id])
    }

    @Test func aStaleCandidateCannotResumeOrDiscardAFinishedWorkout() throws {
        let context = ModelContext(try makeContainer())
        let free = try start(context)
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        free.completeSet(at: 0, of: step, reps: 10, weightKg: 80)
        let candidate = try #require(FreeWorkoutRecovery.latest(in: context, scope: .guest))
        _ = free.finish()
        try context.save()

        #expect(FreeWorkoutRecovery.resume(candidate, in: context, scope: .guest) == nil)
        #expect(!FreeWorkoutRecovery.discard(candidate, in: context, scope: .guest))
        #expect(free.session.status == .completed)
        #expect(all(StepResult.self, context).count == 1)
    }

    @Test func aCandidateTakenUnderOneAccountIsRefusedUnderAnother() throws {
        let context = ModelContext(try makeContainer())
        let free = try start(context, scope: .account(account))
        free.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        let candidate = try #require(FreeWorkoutRecovery.latest(in: context, scope: .account(account)))
        for scope in [WorkoutDataScope.guest, .account(UUID()), .undetermined] {
            #expect(FreeWorkoutRecovery.resume(candidate, in: context, scope: scope) == nil)
            #expect(!FreeWorkoutRecovery.discard(candidate, in: context, scope: scope))
        }
        #expect(free.isActive)
        #expect(free.steps.count == 1)
    }

    @Test func resumeJudgesTheStoreNowNotTheCandidatesSnapshot() throws {
        let context = ModelContext(try makeContainer())
        let free = try start(context)
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        free.completeSet(at: 0, of: step, reps: 10, weightKg: 80)
        let candidate = try #require(FreeWorkoutRecovery.latest(in: context, scope: .guest))
        #expect(candidate.isResumable)
        context.delete(step)   // damaged after the card was built
        #expect(FreeWorkoutRecovery.resume(candidate, in: context, scope: .guest) == nil)
    }

    // MARK: normal drafts survive a relaunch

    private func relaunch(_ container: ModelContainer) throws -> FreeWorkoutSession {
        let context = ModelContext(container)
        let candidate = try #require(FreeWorkoutRecovery.latest(in: context, scope: .guest))
        #expect(candidate.isResumable)
        return try #require(FreeWorkoutRecovery.resume(candidate, in: context, scope: .guest))
    }

    @Test func anExerciseWithNothingLoggedResumesAfterARelaunch() throws {
        let container = try makeContainer()
        do {
            let context = ModelContext(container)
            let free = try start(context)
            free.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
            try context.save()
        }
        let resumed = try relaunch(container)
        let bench = try #require(resumed.steps.first)
        #expect(bench.exerciseId == "bench_press")
        #expect(resumed.results(for: bench).isEmpty)
        #expect(resumed.completeSet(at: 0, of: bench, reps: 10, weightKg: 80) != nil)
    }

    @Test func aLoggedExerciseNextToABlankOneResumesAfterARelaunch() throws {
        let container = try makeContainer()
        do {
            let context = ModelContext(container)
            let free = try start(context)
            let bench = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
            free.completeSet(at: 0, of: bench, reps: 10, weightKg: 80)
            free.addExercise(exerciseId: "incline_chest_press", title: "インクライン")
            try context.save()
        }
        let resumed = try relaunch(container)
        let steps = resumed.steps
        #expect(steps.map(\.exerciseId) == ["bench_press", "incline_chest_press"])
        #expect(resumed.results(for: steps[0]).map(\.weightKg) == [80])
        #expect(resumed.results(for: steps[1]).isEmpty)
        #expect(resumed.completeSet(at: 0, of: steps[1], reps: 10, weightKg: 30) != nil)
        #expect(resumed.results(for: steps[1]).map(\.plannedSetsAtExecution) == [1])
    }

    @Test func draftRowsBeyondTheLoggedSetsSurviveARelaunch() throws {
        let container = try makeContainer()
        do {
            let context = ModelContext(container)
            let free = try start(context)
            let bench = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 4))
            free.completeSet(at: 0, of: bench, reps: 10, weightKg: 80)
            free.completeSet(at: 1, of: bench, reps: 9, weightKg: 80)
            try context.save()
        }
        let resumed = try relaunch(container)
        let bench = try #require(resumed.steps.first)
        #expect(bench.sets == 4)                                   // rows 0..<4
        #expect(resumed.results(for: bench).map(\.setIndex) == [0, 1])   // rows 2, 3 are drafts
        #expect(resumed.completeSet(at: 3, of: bench, reps: 8, weightKg: 75) != nil)
    }
}

// MARK: - Free Workout UI state

@MainActor
struct FreeWorkoutViewModelTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Routine.self, Step.self, Session.self, StepResult.self, DayLog.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func all<T: PersistentModel>(_ type: T.Type, _ context: ModelContext) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }

    private func launcher(_ context: ModelContext, scope: WorkoutDataScope = .guest,
                          drafts: FreeWorkoutDraftStore? = nil) -> FreeWorkoutLauncher {
        // A fresh store per test unless one is shared on purpose.
        let launcher = FreeWorkoutLauncher(drafts: drafts ?? FreeWorkoutDraftStore())
        launcher.configure(context: context, scope: scope)
        return launcher
    }

    private func open(_ context: ModelContext) throws -> FreeWorkoutViewModel {
        let launcher = launcher(context)
        launcher.start()
        return try #require(launcher.presented)
    }

    private func key(_ model: FreeWorkoutViewModel, card: Int, set: Int) -> FreeWorkoutViewModel.RowKey {
        model.cards[card].rows[set].key
    }

    // MARK: launcher

    @Test func startOpensAWorkoutAndADoubleTapCreatesNothingMore() throws {
        let context = ModelContext(try makeContainer())
        let launcher = launcher(context)
        launcher.start()
        let first = try #require(launcher.presented)
        launcher.start()
        #expect(launcher.presented === first)
        #expect(launcher.candidates.map(\.id) == [first.id])
        #expect(all(Session.self, context).count == 1)
    }

    @Test func anUnknownScopeStartsNothingAndSaysWhy() throws {
        let context = ModelContext(try makeContainer())
        let launcher = launcher(context, scope: .undetermined)
        launcher.start()
        #expect(launcher.presented == nil)
        #expect(launcher.notice == .scopeUndetermined)
        #expect(all(Session.self, context).isEmpty)
    }

    @Test func leavingTheScreenKeepsTheWorkoutForResumeOrDiscard() throws {
        let context = ModelContext(try makeContainer())
        let launcher = launcher(context)
        launcher.start()
        let model = try #require(launcher.presented)
        model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        launcher.workoutScreenClosed(try #require(launcher.presented))
        #expect(launcher.presented == nil)
        let candidate = try #require(launcher.candidates.first)
        #expect(candidate.stepCount == 1)

        launcher.resume(candidate)
        #expect(launcher.presented?.cards.map(\.title) == ["ベンチプレス"])
        launcher.workoutScreenClosed(try #require(launcher.presented))
        launcher.discard(candidate)
        #expect(launcher.candidates.isEmpty)
        #expect(all(Session.self, context).isEmpty)
    }

    // MARK: rows

    @Test func rowsAreTheStepsSetsWithDraftsForUnloggedOnes() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        let bench = model.cards[0].id
        for _ in 0..<3 { model.addSet(to: bench) }
        model.setWeight(80, for: key(model, card: 0, set: 0))
        model.complete(key(model, card: 0, set: 0))
        model.complete(key(model, card: 0, set: 1))
        #expect(model.cards[0].rows.map(\.state) == [.done, .done, .draft, .draft])
        #expect(model.cards[0].rows.map(\.number) == [1, 2, 3, 4])
        // An untouched draft takes the set above it.
        #expect(model.cards[0].rows[2].weightKg == 80)
        #expect(model.selected == key(model, card: 0, set: 2))
    }

    @Test func editingDraftsPersistsNothingUntilCompleteAndSkipIsLogged() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        model.addSet(to: model.cards[0].id)
        let first = key(model, card: 0, set: 0)
        model.setWeight(60, for: first)
        model.adjustWeight(by: 2.5, for: first)
        model.adjustReps(by: -2, for: first)
        model.setWeight(-5, for: first)          // ignored
        #expect(all(StepResult.self, context).isEmpty)
        #expect(model.row(first)?.weightKg == 62.5)
        #expect(model.row(first)?.reps == 8)

        model.complete(first)
        model.skip(key(model, card: 0, set: 1))
        let results = all(StepResult.self, context).sorted { $0.setIndex < $1.setIndex }
        #expect(results.map(\.done) == [true, false])
        #expect(results.first?.weightKg == 62.5)
        #expect(model.cards[0].rows.map(\.state) == [.done, .skipped])
    }

    @Test func editingALoggedSetOverwritesItInPlace() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        let first = key(model, card: 0, set: 0)
        model.setWeight(80, for: first)
        model.complete(first)
        let id = try #require(all(StepResult.self, context).first?.id)
        model.adjustWeight(by: -2.5, for: first)
        model.setReps(9, for: first)
        let results = all(StepResult.self, context)
        #expect(results.map(\.id) == [id])
        #expect(results.first?.weightKg == 77.5)
        #expect(results.first?.actualReps == 9)
        #expect(results.first?.exerciseIdAtExecution == "bench_press")
    }

    @Test func setsAndExercisesAreAddedRemovedAndReorderedThroughTheDomain() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        model.addExercise(exerciseId: "incline_chest_press", title: "インクライン")
        model.addExercise(exerciseId: "pec_deck_fly", title: "フライ")
        let bench = model.cards[0].id
        model.addSet(to: bench); model.addSet(to: bench)
        model.complete(key(model, card: 0, set: 0))
        model.complete(key(model, card: 0, set: 2))
        model.removeSet(key(model, card: 0, set: 1))   // a draft between two logged
        #expect(model.cards[0].rows.map(\.state) == [.done, .done])

        #expect(!model.cards[0].canRemove)
        model.removeExercise(bench)
        #expect(model.cards.count == 3)                // refused: it has results
        model.removeExercise(model.cards[1].id)
        #expect(model.cards.map(\.title) == ["ベンチプレス", "フライ"])

        model.moveExercises(fromOffsets: IndexSet(integer: 0), toOffset: 2)   // List onMove: bench to the end
        #expect(model.cards.map(\.title) == ["フライ", "ベンチプレス"])
    }

    @Test func elapsedTimeIsReadFromTheSessionsStart() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        #expect(model.elapsedText(now: model.startedAt.addingTimeInterval(65)) == "01:05")
        #expect(model.elapsedText(now: model.startedAt.addingTimeInterval(3725)) == "1:02:05")
        #expect(model.elapsedText(now: model.startedAt.addingTimeInterval(-30)) == "00:00")
    }

    // MARK: finish

    @Test func aBenchWorkoutIsSavedAndReachesProgress() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        let bench = model.cards[0].id
        model.addSet(to: bench); model.addSet(to: bench)
        for (index, set) in [(80.0, 10), (80.0, 9), (75.0, 10)].enumerated() {
            let row = key(model, card: 0, set: index)
            model.setWeight(set.0, for: row)
            model.setReps(set.1, for: row)
            model.complete(row)
        }
        model.finish()
        #expect(model.finishOutcome == .saved)
        #expect(model.completion?.completedSetCount == 3)
        #expect(model.completion?.completedExerciseCount == 1)
        #expect(all(Session.self, context).first?.status == .completed)
        let results = all(StepResult.self, context).sorted { $0.setIndex < $1.setIndex }
        #expect(results.map(\.weightKg) == [80, 80, 75])
        #expect(results.map(\.actualReps) == [10, 9, 10])
        let insights = WorkoutProgressQuery.exerciseInsights(
            steps: all(Step.self, context), sessions: all(Session.self, context), results: results)
        #expect(insights.first?.latestReps == [10, 9, 10])
    }

    @Test func finishingWithNothingPerformedSavesNothing() throws {
        let context = ModelContext(try makeContainer())
        let launcher = launcher(context)
        launcher.start()
        let model = try #require(launcher.presented)
        model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        model.skip(key(model, card: 0, set: 0))
        model.finish()
        #expect(model.finishOutcome == .discarded)
        #expect(model.completion == nil)
        launcher.workoutScreenClosed(try #require(launcher.presented))
        #expect(launcher.notice == .nothingSaved)
        #expect(all(Session.self, context).isEmpty)
    }

    // MARK: recovery

    @Test func aRelaunchedAppResumesTheWorkoutWithItsRows() throws {
        let container = try makeContainer()
        do {
            let model = try open(ModelContext(container))
            model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
            for _ in 0..<3 { model.addSet(to: model.cards[0].id) }
            model.setWeight(80, for: key(model, card: 0, set: 0))
            model.complete(key(model, card: 0, set: 0))
            model.complete(key(model, card: 0, set: 1))
        }
        let context = ModelContext(container)
        let launcher = launcher(context)
        let candidate = try #require(launcher.candidates.first)
        launcher.resume(candidate)
        let model = try #require(launcher.presented)
        #expect(model.cards[0].rows.map(\.state) == [.done, .done, .draft, .draft])
        model.complete(key(model, card: 0, set: 2))
        model.finish()
        #expect(model.completion?.completedSetCount == 3)
        #expect(all(StepResult.self, context).count == 3)
    }

    // MARK: drafts across close / resume (same process)

    /// Opens a workout through a launcher sharing `store`, and a way to close
    /// and resume it as the card does.
    @MainActor
    private struct Flow {
        let launcher: FreeWorkoutLauncher
        var model: FreeWorkoutViewModel { launcher.presented! }
        func closeAndResume() throws {
            launcher.workoutScreenClosed(try #require(launcher.presented))
            let candidate = try #require(launcher.candidates.first)
            launcher.resume(candidate)
        }
    }

    private func flow(_ context: ModelContext, _ store: FreeWorkoutDraftStore) throws -> Flow {
        let launcher = launcher(context, drafts: store)
        launcher.start()
        _ = try #require(launcher.presented)
        return Flow(launcher: launcher)
    }

    @Test func typedDraftsSurviveCloseAndResume() throws {
        let context = ModelContext(try makeContainer())
        let flow = try flow(context, FreeWorkoutDraftStore())
        flow.model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        flow.model.addSet(to: flow.model.cards[0].id)
        let first = key(flow.model, card: 0, set: 0), second = key(flow.model, card: 0, set: 1)
        flow.model.setWeight(70, for: first); flow.model.setReps(10, for: first)
        flow.model.setWeight(65, for: second); flow.model.setReps(12, for: second)

        try flow.closeAndResume()
        #expect(flow.model.row(first)?.weightKg == 70 && flow.model.row(first)?.reps == 10)
        #expect(flow.model.row(second)?.weightKg == 65 && flow.model.row(second)?.reps == 12)
        #expect(all(StepResult.self, context).isEmpty)   // still drafts, never persisted
    }

    @Test func aLoggedSetAndADraftBesideItBothComeBack() throws {
        let context = ModelContext(try makeContainer())
        let flow = try flow(context, FreeWorkoutDraftStore())
        flow.model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        flow.model.addSet(to: flow.model.cards[0].id)
        let first = key(flow.model, card: 0, set: 0), second = key(flow.model, card: 0, set: 1)
        flow.model.setWeight(80, for: first); flow.model.complete(first)
        flow.model.setWeight(70, for: second); flow.model.setReps(10, for: second)

        try flow.closeAndResume()
        #expect(flow.model.row(first)?.state == .done && flow.model.row(first)?.weightKg == 80)
        #expect(flow.model.row(second)?.state == .draft && flow.model.row(second)?.weightKg == 70)
    }

    @Test func aCompletedDraftLeavesNoStaleValueBehind() throws {
        let context = ModelContext(try makeContainer())
        let store = FreeWorkoutDraftStore()
        let flow = try flow(context, store)
        flow.model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        let first = key(flow.model, card: 0, set: 0)
        flow.model.setWeight(70, for: first); flow.model.setReps(10, for: first)
        flow.model.complete(first)
        #expect(store.drafts(for: flow.model.id)[first] == nil)
        // Re-record it lighter, then reopen: the persisted value wins.
        flow.model.setWeight(67.5, for: first)
        try flow.closeAndResume()
        #expect(flow.model.row(first)?.state == .done)
        #expect(flow.model.row(first)?.weightKg == 67.5)
        #expect(all(StepResult.self, context).map(\.weightKg) == [67.5])
    }

    @Test func draftsFollowTheirRowThroughAReindexAndTheirExerciseThroughAReorder() throws {
        let context = ModelContext(try makeContainer())
        let flow = try flow(context, FreeWorkoutDraftStore())
        flow.model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        flow.model.addExercise(exerciseId: "pec_deck_fly", title: "フライ")
        let bench = flow.model.cards[0].id, fly = flow.model.cards[1].id
        flow.model.addSet(to: bench); flow.model.addSet(to: bench)
        flow.model.complete(key(flow.model, card: 0, set: 0))
        flow.model.setWeight(70, for: key(flow.model, card: 0, set: 1)); flow.model.setReps(10, for: key(flow.model, card: 0, set: 1))
        flow.model.setWeight(65, for: key(flow.model, card: 0, set: 2)); flow.model.setReps(12, for: key(flow.model, card: 0, set: 2))
        flow.model.setWeight(20, for: key(flow.model, card: 1, set: 0))

        flow.model.removeSet(key(flow.model, card: 0, set: 0))     // the logged set
        flow.model.moveExercises(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        try flow.closeAndResume()

        #expect(flow.model.cards.map(\.id) == [fly, bench])
        let benchRows = try #require(flow.model.cards.first { $0.id == bench }).rows
        #expect(benchRows.map(\.weightKg) == [70, 65])
        #expect(benchRows.map(\.reps) == [10, 12])
        #expect(flow.model.cards.first { $0.id == fly }?.rows.first?.weightKg == 20)
    }

    @Test func removingAnExerciseDropsOnlyItsDrafts() throws {
        let context = ModelContext(try makeContainer())
        let store = FreeWorkoutDraftStore()
        let flow = try flow(context, store)
        flow.model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        flow.model.addExercise(exerciseId: "pec_deck_fly", title: "フライ")
        let bench = flow.model.cards[0].id, fly = flow.model.cards[1].id
        flow.model.setWeight(70, for: key(flow.model, card: 0, set: 0))
        flow.model.setWeight(20, for: key(flow.model, card: 1, set: 0))
        flow.model.removeExercise(bench)
        let remaining = store.drafts(for: flow.model.id)
        #expect(remaining.keys.allSatisfy { $0.stepId == fly })
        #expect(remaining[FreeWorkoutViewModel.RowKey(stepId: fly, setIndex: 0)]?.weightKg == 20)
    }

    @Test func finishingOrDiscardingClearsThatWorkoutsDrafts() throws {
        for ending in ["finish", "discardInScreen", "discardFromCard", "emptyFinish"] {
            let context = ModelContext(try makeContainer())
            let store = FreeWorkoutDraftStore()
            let flow = try flow(context, store)
            let id = flow.model.id
            flow.model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
            flow.model.addSet(to: flow.model.cards[0].id)
            if ending != "emptyFinish" { flow.model.complete(key(flow.model, card: 0, set: 0)) }
            flow.model.setWeight(70, for: key(flow.model, card: 0, set: 1))
            #expect(store.sessionIds.contains(id))

            switch ending {
            case "finish", "emptyFinish": flow.model.finish()
            case "discardInScreen": flow.model.discard()
            default:
                flow.launcher.workoutScreenClosed(try #require(flow.launcher.presented))
                flow.launcher.discard(try #require(flow.launcher.candidates.first))
            }
            #expect(!store.sessionIds.contains(id), "\(ending)")
        }
    }

    @Test func draftsOfSeparateWorkoutsNeverMix() throws {
        let store = FreeWorkoutDraftStore()
        let guestContext = ModelContext(try makeContainer())
        let guest = try flow(guestContext, store)
        guest.model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        guest.model.setWeight(60, for: key(guest.model, card: 0, set: 0))

        let other = launcher(guestContext, scope: .account(UUID()), drafts: store)
        other.start()
        let account = try #require(other.presented)
        account.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        account.setWeight(100, for: key(account, card: 0, set: 0))

        #expect(store.drafts(for: guest.model.id).values.map(\.weightKg) == [60])
        #expect(store.drafts(for: account.id).values.map(\.weightKg) == [100])
        #expect(guest.model.row(key(guest.model, card: 0, set: 0))?.weightKg == 60)
    }

    @Test func draftsOfAWorkoutGoneElsewhereAreDroppedOnRefresh() throws {
        let context = ModelContext(try makeContainer())
        let store = FreeWorkoutDraftStore()
        let flow = try flow(context, store)
        let id = flow.model.id
        flow.model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        flow.model.setWeight(70, for: key(flow.model, card: 0, set: 0))
        flow.launcher.workoutScreenClosed(try #require(flow.launcher.presented))
        // Discarded through another card (another launcher on the same store).
        let elsewhere = launcher(context, drafts: FreeWorkoutDraftStore())
        _ = FreeWorkoutRecovery.discard(try #require(elsewhere.candidates.first), in: context, scope: .guest)
        flow.launcher.refresh()
        #expect(!store.sessionIds.contains(id))
    }

    /// A relaunch has no store left: rows and logged sets come back from
    /// SwiftData, typed values go back to their defaults — by design.
    @Test func aRelaunchKeepsRowsButNotTypedValues() throws {
        let container = try makeContainer()
        do {
            let flow = try flow(ModelContext(container), FreeWorkoutDraftStore())
            flow.model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
            flow.model.addSet(to: flow.model.cards[0].id)
            flow.model.setWeight(70, for: key(flow.model, card: 0, set: 1))
        }
        let context = ModelContext(container)
        let relaunched = launcher(context, drafts: FreeWorkoutDraftStore())
        relaunched.resume(try #require(relaunched.candidates.first))
        let model = try #require(relaunched.presented)
        #expect(model.cards[0].rows.count == 2)
        #expect(model.cards[0].rows[1].weightKg == nil)
    }
    // MARK: History resume
    //
    // History only knows a session id from a list it drew earlier; the
    // launcher re-checks it against the store and scope at tap time.

    @Test func historyResumesTheSameInProgressFreeWorkout() throws {
        let context = ModelContext(try makeContainer())
        let started = launcher(context)
        started.start()
        let id = try #require(started.presented).id
        started.workoutScreenClosed(try #require(started.presented))

        let history = launcher(context)
        #expect(history.resume(sessionId: id))
        #expect(history.presented?.id == id)
        #expect(all(Session.self, context).count == 1)   // reopened, not restarted
    }

    @Test func historyDoesNotResumeACompletedFreeWorkout() throws {
        let context = ModelContext(try makeContainer())
        let flow = try flow(context, FreeWorkoutDraftStore())
        let id = flow.model.id
        flow.model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        flow.model.complete(key(flow.model, card: 0, set: 0))
        flow.model.finish()
        flow.launcher.workoutScreenClosed(try #require(flow.launcher.presented))
        #expect(all(Session.self, context).first?.status == .completed)

        let history = launcher(context)
        #expect(!history.resume(sessionId: id))
        #expect(history.presented == nil)
        #expect(all(Session.self, context).first?.status == .completed)
    }

    @Test func historyDoesNotTreatARoutineInProgressAsAFreeWorkout() throws {
        let context = ModelContext(try makeContainer())
        let routine = Routine(name: "胸の日")
        let session = Session(routineId: routine.id, dayDate: Date())
        context.insert(routine); context.insert(session)
        try context.save()

        let history = launcher(context)
        #expect(!history.resume(sessionId: session.id))
        #expect(history.presented == nil)
        #expect(session.status == .inProgress)
    }

    @Test func historyRefusesAWorkoutFinishedOrDiscardedAfterTheListWasDrawn() throws {
        for discards in [false, true] {
            let context = ModelContext(try makeContainer())
            let history = launcher(context)
            let flow = try flow(context, FreeWorkoutDraftStore())
            let id = flow.model.id
            flow.model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
            history.refresh()   // the row is drawn while it is in progress
            #expect(history.candidates.map(\.id) == [id])

            if discards {
                flow.model.discard()
            } else {
                flow.model.complete(key(flow.model, card: 0, set: 0))
                flow.model.finish()
            }
            flow.launcher.workoutScreenClosed(try #require(flow.launcher.presented))

            #expect(!history.resume(sessionId: id))
            #expect(history.presented == nil)
        }
    }

    @Test func historyNeverResumesAnotherOwnersWorkout() throws {
        let context = ModelContext(try makeContainer())
        let accountA = UUID()
        let started = launcher(context, scope: .account(accountA))
        started.start()
        let id = try #require(started.presented).id
        started.workoutScreenClosed(try #require(started.presented))

        for scope in [WorkoutDataScope.account(UUID()), .guest, .undetermined] {
            let history = launcher(context, scope: .account(accountA))
            history.configure(context: context, scope: scope)   // the scope changed under the list
            #expect(!history.resume(sessionId: id))
            #expect(history.presented == nil)
        }
        let session = try #require(all(Session.self, context).first)
        #expect(session.status == .inProgress && session.ownerAccountID == accountA)
    }

    @Test func historyResumeKeepsTheDraftsTypedBeforeClosing() throws {
        let context = ModelContext(try makeContainer())
        let store = FreeWorkoutDraftStore()
        let flow = try flow(context, store)
        let id = flow.model.id
        flow.model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        let row = key(flow.model, card: 0, set: 0)
        flow.model.setWeight(72.5, for: row); flow.model.setReps(8, for: row)
        flow.launcher.workoutScreenClosed(try #require(flow.launcher.presented))

        // History has its own launcher, but the same process-wide store.
        let history = launcher(context, drafts: store)
        #expect(history.resume(sessionId: id))
        let model = try #require(history.presented)
        #expect(model.row(row)?.weightKg == 72.5 && model.row(row)?.reps == 8)
    }

    @Test func historyResumesAfterARelaunchFromTheStoreAlone() throws {
        let container = try makeContainer()
        let id: UUID
        do {
            let flow = try flow(ModelContext(container), FreeWorkoutDraftStore())
            id = flow.model.id
            flow.model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
            flow.model.addSet(to: flow.model.cards[0].id)
            let first = key(flow.model, card: 0, set: 0)
            flow.model.setWeight(80, for: first); flow.model.setReps(5, for: first)
            flow.model.complete(first)
            flow.model.setWeight(70, for: key(flow.model, card: 0, set: 1))
        }
        let context = ModelContext(container)
        let history = launcher(context, drafts: FreeWorkoutDraftStore())
        #expect(history.resume(sessionId: id))
        let model = try #require(history.presented)
        #expect(model.cards[0].rows.count == 2)
        #expect(model.cards[0].rows[0].weightKg == 80 && model.cards[0].rows[0].reps == 5)
        // The typed 70 does not outlive the process; the row falls back to
        // its default, which follows the set logged above it.
        #expect(model.cards[0].rows[1].weightKg != 70)
    }

    // MARK: Summary metrics

    /// What History detail computes for a session: the same calculation over
    /// what the store holds.
    private func historySummary(_ context: ModelContext) throws -> WorkoutCompletionSummary {
        let session = try #require(all(Session.self, context).first)
        let steps = all(Step.self, context).filter { $0.routineId == session.routineId }
        let results = all(StepResult.self, context).filter { $0.sessionId == session.id }
        return WorkoutCompletionSummary.make(sessionId: session.id, duration: TimeInterval(session.totalSeconds),
                                             results: results, steps: steps,
                                             bodyWeightKg: WorkoutCalorieEstimator.bodyWeightKg(for: session, modelContext: context))
    }

    private func logBench(_ model: FreeWorkoutViewModel, _ sets: [(Double, Int)]) {
        model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        let card = model.cards.count - 1
        for _ in 1..<sets.count { model.addSet(to: model.cards[card].id) }
        for (index, set) in sets.enumerated() {
            let row = key(model, card: card, set: index)
            model.setWeight(set.0, for: row); model.setReps(set.1, for: row)
            model.complete(row)
        }
    }

    @Test func finishingShowsTheTotalsHistoryShowsToo() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        logBench(model, [(80, 10), (80, 9), (75, 10)])
        model.finish(now: model.startedAt.addingTimeInterval(1_832))

        let summary = try #require(model.completion)
        #expect(summary.duration == 1_832)
        #expect(summary.completedExerciseCount == 1)
        #expect(summary.completedSetCount == 3)
        #expect(summary.totalReps == 29)
        #expect(summary.totalVolumeKg == 2270)
        #expect(try historySummary(context) == summary)
    }

    @Test func finishingEstimatesCaloriesFromTheOwnersWeightAsHistoryDoes() throws {
        let context = ModelContext(try makeContainer())
        context.insert(DayLog(date: DateUtils.startOfDay(Date().addingTimeInterval(-86_400)), weightKg: 80))
        let model = try open(context)
        logBench(model, [(80, 10)])
        model.finish(now: model.startedAt.addingTimeInterval(1_832))

        let summary = try #require(model.completion)
        // Same weight and duration as a Runner workout → the same kcal,
        // whatever the exercises: 3.5 × 3.5 × 80 / 200 × 1832/60 ≈ 149.6
        #expect(summary.estimatedCalories == 150)
        #expect(summary.estimatedCalories == WorkoutCalorieEstimator.estimatedCalories(bodyWeightKg: 80, duration: 1_832))
        #expect(try historySummary(context) == summary)
    }

    @Test func finishingWithoutAWeighInShowsNoCalories() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        model.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミルウォームアップ")
        model.setDuration(DurationEntry(minutes: "10"), for: key(model, card: 0, set: 0))
        model.complete(key(model, card: 0, set: 0))
        model.finish(now: model.startedAt.addingTimeInterval(600))
        #expect(try #require(model.completion).estimatedCalories == nil)
    }

    @Test func aTimedOnlyWorkoutStillGetsTheWorkoutLevelEstimate() throws {
        let context = ModelContext(try makeContainer())
        context.insert(DayLog(date: DateUtils.startOfDay(Date().addingTimeInterval(-86_400)), weightKg: 80))
        let model = try open(context)
        model.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミルウォームアップ")
        model.setDuration(DurationEntry(minutes: "10"), for: key(model, card: 0, set: 0))
        model.complete(key(model, card: 0, set: 0))
        model.finish(now: model.startedAt.addingTimeInterval(600))
        let summary = try #require(model.completion)
        #expect(summary.totalVolumeKg == 0)
        // No running MET for a treadmill: the same 3.5 as any workout.
        #expect(summary.estimatedCalories == WorkoutCalorieEstimator.estimatedCalories(bodyWeightKg: 80, duration: 600))
    }

    @Test func aTimedExerciseRecordsNoRepsYetStillCountsAsPerformed() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        model.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミルウォームアップ")
        let card = try #require(model.cards.first)
        #expect(card.tracksReps == false)
        #expect(card.acceptsWeight == false)
        model.setReps(12, for: key(model, card: 0, set: 0))   // ignored for a timed set
        model.setDuration(DurationEntry(minutes: "10"), for: key(model, card: 0, set: 0))
        model.complete(key(model, card: 0, set: 0))

        let result = try #require(all(StepResult.self, context).first)
        #expect(result.done)
        #expect(result.actualReps == nil)
        model.finish(now: model.startedAt.addingTimeInterval(600))
        #expect(model.finishOutcome == .saved)
        let summary = try #require(model.completion)
        #expect(summary.completedSetCount == 1)
        #expect(summary.totalReps == 0)
        #expect(summary.totalVolumeKg == 0)
    }

    /// Logs one done treadmill set with no duration in a finished Free
    /// Workout — a record from before durations were entered, written through
    /// the domain's duration-free path the screen no longer reaches.
    /// `legacyReps` stands in for an older record that still stored a rep count.
    private func logPastTreadmill(_ context: ModelContext, legacyReps: Int? = nil) throws {
        let past = try open(context)
        past.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミルウォームアップ")
        let step = try #require(past.session.steps.first)
        try #require(past.session.completeSet(at: 0, of: step, reps: nil, weightKg: nil))
        if let legacyReps { all(StepResult.self, context).first?.actualReps = legacyReps }
        past.finish(now: past.startedAt.addingTimeInterval(600))
        #expect(past.finishOutcome == .saved)
    }

    // MARK: timed duration (V15)

    private func openIn(_ context: ModelContext, scope: WorkoutDataScope) throws -> FreeWorkoutViewModel {
        let launcher = launcher(context, scope: scope)
        launcher.start()
        return try #require(launcher.presented)
    }

    /// Finishes a Free Workout of one treadmill set of `seconds` in `scope`.
    private func logPastTimedTreadmill(_ context: ModelContext, seconds: Int, scope: WorkoutDataScope = .guest) throws {
        let past = try openIn(context, scope: scope)
        past.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミルウォームアップ")
        let step = try #require(past.session.steps.first)
        #expect(past.session.completeTimedSet(at: 0, of: step, durationSeconds: seconds) != nil)
        past.finish(now: past.startedAt.addingTimeInterval(900))
        #expect(past.finishOutcome == .saved)
    }

    // MARK: timed duration input (PR-B)

    private func addTreadmill(_ model: FreeWorkoutViewModel) -> FreeWorkoutViewModel.RowKey {
        model.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミルウォームアップ")
        return key(model, card: 0, set: 0)
    }

    @Test func aTypedDurationCompletesTheTimedSet() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        let row = addTreadmill(model)
        #expect(model.row(row)?.duration == DurationEntry())          // no fake default
        model.setDuration(DurationEntry(minutes: "12", seconds: "30"), for: row)
        #expect(model.row(row)?.durationIssue(tracksReps: false) == nil)
        model.complete(row)
        let result = try #require(all(StepResult.self, context).first)
        #expect(result.done)
        #expect(result.actualDurationSeconds == 750)
        #expect(result.actualReps == nil)
        #expect(model.row(row)?.state == .done)
        #expect(model.row(row)?.duration == DurationEntry(minutes: "12", seconds: "30"))
    }

    @Test func aTimedSetCannotBeCompletedWithoutAValidDuration() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        let row = addTreadmill(model)
        let cases: [(DurationEntry, DurationEntry.Issue)] = [
            (DurationEntry(), .empty),
            (DurationEntry(minutes: "0", seconds: "0"), .zero),
            (DurationEntry(minutes: "1", seconds: "60"), .invalidSeconds),
            (DurationEntry(seconds: "90"), .invalidSeconds),
        ]
        for (entry, issue) in cases {
            model.setDuration(entry, for: row)
            #expect(model.row(row)?.duration == entry)               // kept as typed: 90 is not 59 or 1:30
            #expect(model.row(row)?.durationIssue(tracksReps: false) == issue)
            model.complete(row)
            #expect(all(StepResult.self, context).isEmpty)
            #expect(model.row(row)?.state == .draft)
        }
    }

    @Test func aTypedDurationSurvivesCloseAndResume() throws {
        let context = ModelContext(try makeContainer())
        let store = FreeWorkoutDraftStore()
        let flow = try flow(context, store)
        let row = addTreadmill(flow.model)
        flow.model.setDuration(DurationEntry(minutes: "12", seconds: "30"), for: row)
        try flow.closeAndResume()
        #expect(flow.model.row(row)?.duration == DurationEntry(minutes: "12", seconds: "30"))
        // Resumed from History's in-progress entry, too.
        let id = flow.model.id
        flow.launcher.workoutScreenClosed(try #require(flow.launcher.presented))
        #expect(flow.launcher.resume(sessionId: id))
        #expect(flow.model.row(row)?.duration == DurationEntry(minutes: "12", seconds: "30"))
        #expect(all(StepResult.self, context).isEmpty)               // still a draft

        flow.model.complete(row)
        #expect(store.drafts(for: id)[row] == nil)
        #expect(all(StepResult.self, context).first?.actualDurationSeconds == 750)
    }

    @Test func skippingATimedSetStoresNoDurationAndDropsTheDraft() throws {
        let context = ModelContext(try makeContainer())
        let store = FreeWorkoutDraftStore()
        let flow = try flow(context, store)
        let row = addTreadmill(flow.model)
        flow.model.setDuration(DurationEntry(minutes: "5"), for: row)
        flow.model.skip(row)
        let result = try #require(all(StepResult.self, context).first)
        #expect(!result.done)
        #expect(result.actualDurationSeconds == nil)
        #expect(store.drafts(for: flow.model.id)[row] == nil)
        #expect(!SessionHistoryPresentation.isTimedPerformance(result))   // shown as a skip, as before
    }

    @Test func durationDraftsFollowSetDeletionAndExerciseRemoval() throws {
        let context = ModelContext(try makeContainer())
        let store = FreeWorkoutDraftStore()
        let flow = try flow(context, store)
        let first = addTreadmill(flow.model)
        flow.model.addSet(to: first.stepId)
        let second = key(flow.model, card: 0, set: 1)
        flow.model.setDuration(DurationEntry(minutes: "3"), for: first)
        flow.model.setDuration(DurationEntry(minutes: "7", seconds: "30"), for: second)

        flow.model.removeSet(first)
        #expect(flow.model.row(first)?.duration == DurationEntry(minutes: "7", seconds: "30"))
        #expect(flow.model.row(second) == nil)

        flow.model.removeExercise(first.stepId)
        #expect(store.drafts(for: flow.model.id).isEmpty)
    }

    @Test func editingADoneTimedSetReplacesItsDuration() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        let row = addTreadmill(model)
        model.setDuration(DurationEntry(minutes: "12", seconds: "30"), for: row)
        model.complete(row)

        // An invalid edit is shown with its reason and the record is untouched.
        model.setDuration(DurationEntry(minutes: "15", seconds: "75"), for: row)
        #expect(model.row(row)?.durationIssue(tracksReps: false) == .invalidSeconds)
        #expect(all(StepResult.self, context).first?.actualDurationSeconds == 750)

        model.setDuration(DurationEntry(minutes: "15"), for: row)
        let results = all(StepResult.self, context)
        #expect(results.count == 1)
        #expect(results.first?.actualDurationSeconds == 900)
        #expect(model.row(row)?.durationIssue(tracksReps: false) == nil)
    }

    @Test func aDurationTypedInTheScreenReachesHistoryAndPrevious() throws {
        let context = ModelContext(try makeContainer())
        let past = try open(context)
        let row = addTreadmill(past)
        past.setDuration(DurationEntry(minutes: "12", seconds: "30"), for: row)
        past.complete(row)
        past.finish(now: past.startedAt.addingTimeInterval(900))
        #expect(past.finishOutcome == .saved)
        let stored = try #require(all(StepResult.self, context).first)
        #expect(SessionHistoryPresentation.setValueText(stored) == "12分30秒")
        #expect(SessionHistoryPresentation.setAccessibilityLabel(stored) == "セット 1、完了、12分30秒")

        let next = try open(context)
        _ = addTreadmill(next)
        #expect(next.cards.first?.previousText == "12分30秒")
    }

    @Test func aRepExerciseTakesNoDurationFromTheScreen() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        let row = key(model, card: 0, set: 0)
        model.setDuration(DurationEntry(minutes: "5"), for: row)     // ignored
        #expect(model.row(row)?.duration == DurationEntry())
        #expect(model.row(row)?.durationIssue(tracksReps: true) == nil)
        model.setWeight(80, for: row); model.setReps(10, for: row)
        model.complete(row)
        let result = try #require(all(StepResult.self, context).first)
        #expect(result.weightKg == 80 && result.actualReps == 10)
        #expect(result.actualDurationSeconds == nil)
        #expect(SessionHistoryPresentation.setValueText(result) == "80 kg × 10 回")
    }

    @Test func finishingAsksAboutAnUnsavedDurationEditAndCanDropIt() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        let row = addTreadmill(model)
        model.setDuration(DurationEntry(minutes: "12", seconds: "30"), for: row)
        model.complete(row)
        #expect(model.unsavedDurationEdits.isEmpty)

        // A valid edit of a done set is written at once — nothing unsaved.
        model.setDuration(DurationEntry(minutes: "15"), for: row)
        #expect(model.unsavedDurationEdits.isEmpty)
        #expect(all(StepResult.self, context).first?.actualDurationSeconds == 900)

        // An invalid one is held, and Finish has to ask.
        model.setDuration(DurationEntry(minutes: "12", seconds: "90"), for: row)
        #expect(model.unsavedDurationEdits == [row])
        // "編集に戻る": opens the row (as the dialog does), nothing finished,
        // the edit and its reason still there.
        if model.selected != row { model.select(row) }
        #expect(model.selected == row)
        #expect(model.finishOutcome == nil)
        #expect(model.row(row)?.duration == DurationEntry(minutes: "12", seconds: "90"))
        #expect(model.row(row)?.durationIssue(tracksReps: false) == .invalidSeconds)

        // "変更を破棄して終了": the record keeps its value, the edit is gone.
        model.finish(now: model.startedAt.addingTimeInterval(1_200))
        #expect(model.finishOutcome == .saved)
        let stored = try #require(all(StepResult.self, context).first)
        #expect(stored.actualDurationSeconds == 900)
        #expect(SessionHistoryPresentation.setValueText(stored) == "15分")
    }

    @Test func repSetEditsNeverCountAsUnsavedDurations() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        let row = key(model, card: 0, set: 0)
        model.setWeight(80, for: row); model.setReps(10, for: row)
        model.complete(row)
        model.setReps(8, for: row)
        #expect(model.unsavedDurationEdits.isEmpty)
        #expect(all(StepResult.self, context).first?.actualReps == 8)
    }

    @Test func stepsLeaveUnreadableMinutesAsTyped() {
        let unreadable = DurationEntry(minutes: "abc", seconds: "30")
        #expect(unreadable.adjustingMinutes(by: 1) == unreadable)
        #expect(unreadable.adjustingMinutes(by: -1) == unreadable)
        #expect(unreadable.adjustingMinutes(by: 1).issue == .invalidMinutes)
        let tooLong = DurationEntry(minutes: "2000")
        #expect(tooLong.adjustingMinutes(by: 1) == tooLong)        // not pulled back to 1440
        #expect(tooLong.adjustingMinutes(by: -1) == tooLong)

        #expect(DurationEntry(minutes: "12", seconds: "30").adjustingMinutes(by: 1) == DurationEntry(minutes: "13", seconds: "30"))
        #expect(DurationEntry(minutes: "12", seconds: "30").adjustingMinutes(by: -1) == DurationEntry(minutes: "11", seconds: "30"))
        #expect(DurationEntry(minutes: "0", seconds: "30").adjustingMinutes(by: -1) == DurationEntry(minutes: "0", seconds: "30"))
        let badSeconds = DurationEntry(minutes: "12", seconds: "90")
        #expect(badSeconds.adjustingMinutes(by: 1) == DurationEntry(minutes: "13", seconds: "90"))
        #expect(badSeconds.adjustingMinutes(by: 1).issue == .invalidSeconds)
        #expect(DurationEntry(minutes: "1440").adjustingMinutes(by: 1) == DurationEntry(minutes: "1440"))
    }

    @Test func stepsOnAnUnreadableRowLeaveTheFreeWorkoutDraftAlone() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        let row = addTreadmill(model)
        model.setDuration(DurationEntry(minutes: "abc"), for: row)
        let current = try #require(model.row(row)?.duration)
        model.setDuration(current.adjustingMinutes(by: 1), for: row)   // what +1分 sends
        #expect(model.row(row)?.duration == DurationEntry(minutes: "abc"))
        #expect(model.row(row)?.durationIssue(tracksReps: false) == .invalidMinutes)
    }

    @Test func durationEntryParsesWithoutCorrecting() {
        #expect(DurationEntry(minutes: "12", seconds: "30").totalSeconds == 750)
        #expect(DurationEntry(minutes: "5").totalSeconds == 300)
        #expect(DurationEntry(seconds: "45").totalSeconds == 45)
        #expect(DurationEntry(minutes: " 2 ", seconds: "05").totalSeconds == 125)
        #expect(DurationEntry().issue == .empty)
        #expect(DurationEntry(minutes: "0").issue == .zero)
        #expect(DurationEntry(seconds: "60").issue == .invalidSeconds)
        #expect(DurationEntry(seconds: "-5").issue == .invalidSeconds)
        #expect(DurationEntry(minutes: "1.5").issue == .invalidMinutes)
        #expect(DurationEntry(minutes: "abc").issue == .invalidMinutes)
        #expect(DurationEntry(minutes: "\(DurationEntry.maximumMinutes + 1)").issue == .invalidMinutes)
        #expect(DurationEntry(minutes: "１２").issue == .invalidMinutes)  // full-width digits are not read as 12

        #expect(DurationEntry(totalSeconds: 750) == DurationEntry(minutes: "12", seconds: "30"))
        #expect(DurationEntry(totalSeconds: 900) == DurationEntry(minutes: "15"))
        #expect(DurationEntry(totalSeconds: nil) == DurationEntry())
        #expect(DurationEntry(totalSeconds: 0) == DurationEntry())

        #expect(DurationEntry().adjustingMinutes(by: 1) == DurationEntry(minutes: "1"))
        #expect(DurationEntry(minutes: "0", seconds: "30").adjustingMinutes(by: -1) == DurationEntry(minutes: "0", seconds: "30"))
        #expect(DurationEntry(minutes: "12", seconds: "30").adjustingMinutes(by: 1).totalSeconds == 810)

        #expect(DurationEntry().displayText == "未入力")
        #expect(DurationEntry(minutes: "12", seconds: "30").displayText == "12 分 30 秒")
        #expect(DurationEntry(minutes: "5").displayText == "5 分")
    }

    @Test func aTimedSetStoresItsDurationAndNoReps() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        model.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミルウォームアップ")
        let step = try #require(model.session.steps.first)
        let result = try #require(model.session.completeTimedSet(at: 0, of: step, durationSeconds: 750))
        #expect(result.done)
        #expect(result.actualDurationSeconds == 750)
        #expect(result.actualReps == nil)
        #expect(result.exerciseIdAtExecution == "treadmill_warmup")
        #expect(result.plannedSetsAtExecution == step.sets)
    }

    @Test func aTimedSetWithoutAPositiveDurationIsRefused() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        model.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミルウォームアップ")
        let step = try #require(model.session.steps.first)
        #expect(model.session.completeTimedSet(at: 0, of: step, durationSeconds: nil) == nil)
        #expect(model.session.completeTimedSet(at: 0, of: step, durationSeconds: 0) == nil)
        #expect(model.session.completeTimedSet(at: 0, of: step, durationSeconds: -30) == nil)
        #expect(all(StepResult.self, context).isEmpty)
    }

    @Test func aRepExerciseNeverTakesADuration() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        let step = try #require(model.session.steps.first)
        #expect(model.session.completeTimedSet(at: 0, of: step, durationSeconds: 600) == nil)
        let bench = try #require(model.session.completeSet(at: 0, of: step, reps: 10, weightKg: 80))
        #expect(bench.actualReps == 10)
        #expect(bench.weightKg == 80)
        #expect(bench.actualDurationSeconds == nil)
        // Even handed one directly, the writer keeps a rep set duration-free.
        let direct = StepResultWriter.record(in: context, sessionId: model.session.session.id, ownerAccountID: nil, step: step,
                                             setIndex: 0, done: true, actualReps: 10, weightKg: 80, actualDurationSeconds: 600)
        #expect(direct.actualDurationSeconds == nil)
        #expect(direct.actualReps == 10)
    }

    @Test func overwritingATimedSetReplacesItsDuration() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        model.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミルウォームアップ")
        let step = try #require(model.session.steps.first)
        model.session.completeTimedSet(at: 0, of: step, durationSeconds: 750)
        model.session.completeTimedSet(at: 0, of: step, durationSeconds: 600)
        #expect(all(StepResult.self, context).map(\.actualDurationSeconds) == [600])
        // Skipped afterwards: no duration left behind.
        model.session.skipSet(at: 0, of: step)
        #expect(all(StepResult.self, context).map(\.actualDurationSeconds) == [nil])
    }

    @Test func aTimedSetIsPerformedWithADurationOrAsAnOlderRecordWithout() {
        let timedNew = StepResult(sessionId: UUID(), stepId: UUID(), setIndex: 0, done: true,
                                  exerciseIdAtExecution: "treadmill_warmup", actualDurationSeconds: 750)
        let timedOld = StepResult(sessionId: UUID(), stepId: UUID(), setIndex: 0, done: true,
                                  exerciseIdAtExecution: "treadmill_warmup")
        let timedSkipped = StepResult(sessionId: UUID(), stepId: UUID(), setIndex: 0, done: false,
                                      exerciseIdAtExecution: "treadmill_warmup")
        let benchNoReps = StepResult(sessionId: UUID(), stepId: UUID(), setIndex: 0, done: true,
                                     exerciseIdAtExecution: "bench_press")
        #expect(FreeWorkoutSession.isPerformance(timedNew))
        #expect(FreeWorkoutSession.isPerformance(timedOld))
        #expect(!FreeWorkoutSession.isPerformance(timedSkipped))
        #expect(!FreeWorkoutSession.isPerformance(benchNoReps))
    }

    @Test func durationTextReadsAsAnAmountOfTime() {
        #expect(SetDuration.text(30) == "30秒")
        #expect(SetDuration.text(60) == "1分")
        #expect(SetDuration.text(90) == "1分30秒")
        #expect(SetDuration.text(750) == "12分30秒")
        #expect(SetDuration.text(3_600) == "1時間")
        #expect(SetDuration.text(3_665) == "1時間1分5秒")
        #expect(SetDuration.validated(0) == nil)
        #expect(SetDuration.validated(-1) == nil)
        #expect(SetDuration.validated(nil) == nil)
        #expect(SetDuration.validated(1) == 1)
    }

    @Test func historyShowsATimedSetsDuration() throws {
        let context = ModelContext(try makeContainer())
        try logPastTimedTreadmill(context, seconds: 750)
        let stored = try #require(all(StepResult.self, context).first)
        #expect(SessionHistoryPresentation.setValueText(stored) == "12分30秒")
        #expect(SessionHistoryPresentation.setAccessibilityLabel(stored) == "セット 1、完了、12分30秒")
        #expect(all(Session.self, context).first?.status == .completed)
    }

    @Test func previousShowsLastTimesDuration() throws {
        let context = ModelContext(try makeContainer())
        try logPastTimedTreadmill(context, seconds: 750)
        let next = try open(context)
        next.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミルウォームアップ")
        #expect(next.cards.first?.previousText == "12分30秒")
    }

    @Test func previousTimedPerformanceStaysWithItsOwner() throws {
        let context = ModelContext(try makeContainer())
        let accountA = UUID(), accountB = UUID()
        try logPastTimedTreadmill(context, seconds: 750, scope: .account(accountA))

        let asB = try openIn(context, scope: .account(accountB))
        asB.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミルウォームアップ")
        #expect(asB.cards.first?.previousText == nil)
        asB.discard()

        let asGuest = try openIn(context, scope: .guest)
        asGuest.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミルウォームアップ")
        #expect(asGuest.cards.first?.previousText == nil)
        asGuest.discard()

        let asA = try openIn(context, scope: .account(accountA))
        asA.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミルウォームアップ")
        #expect(asA.cards.first?.previousText == "12分30秒")
    }

    @Test func guestTimedHistoryIsReadOnlyByGuest() throws {
        let context = ModelContext(try makeContainer())
        try logPastTimedTreadmill(context, seconds: 600)
        let asA = try openIn(context, scope: .account(UUID()))
        asA.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミルウォームアップ")
        #expect(asA.cards.first?.previousText == nil)
        asA.discard()
        let asGuest = try open(context)
        asGuest.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミルウォームアップ")
        #expect(asGuest.cards.first?.previousText == "10分")
    }

    @Test func aTimedDurationChangesNeitherTheSummaryNorTheCalories() throws {
        let context = ModelContext(try makeContainer())
        context.insert(DayLog(date: DateUtils.startOfDay(Date().addingTimeInterval(-86_400)), weightKg: 80))
        try logPastTimedTreadmill(context, seconds: 750)
        let summary = try historySummary(context)
        #expect(summary.duration == 900)               // the session's, not the set's 750
        #expect(summary.completedExerciseCount == 1)
        #expect(summary.completedSetCount == 1)
        #expect(summary.totalReps == 0)
        #expect(summary.totalVolumeKg == 0)
        #expect(summary.estimatedCalories == WorkoutCalorieEstimator.estimatedCalories(bodyWeightKg: 80, duration: 900))
    }

    @Test func aTimedExercisesPreviousPerformanceSaysOnlyThatItWasDone() throws {
        let context = ModelContext(try makeContainer())
        try logPastTreadmill(context)
        let next = try open(context)
        next.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミルウォームアップ")
        #expect(next.cards.first?.previousText == "実施済み")
    }

    @Test func anOlderTimedRecordWithRepsNeverShowsThem() throws {
        let context = ModelContext(try makeContainer())
        try logPastTreadmill(context, legacyReps: 10)
        let stored = try #require(all(StepResult.self, context).first)
        #expect(stored.actualReps == 10)   // the data itself is left alone
        #expect(try historySummary(context).totalReps == 0)
        #expect(SessionHistoryPresentation.setValueText(stored) == "実施済み")
        #expect(!SessionHistoryPresentation.setAccessibilityLabel(stored).contains("10回"))

        let next = try open(context)
        next.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミルウォームアップ")
        #expect(next.cards.first?.previousText == "実施済み")
    }

    @Test func aDoneTimedSetReadsAsDoneInHistory() throws {
        let context = ModelContext(try makeContainer())
        try logPastTreadmill(context)
        let stored = try #require(all(StepResult.self, context).first)
        #expect(stored.actualReps == nil)
        #expect(SessionHistoryPresentation.setValueText(stored) == "実施済み")
        #expect(SessionHistoryPresentation.setAccessibilityLabel(stored) == "セット 1、完了")
        #expect(all(Session.self, context).first?.status == .completed)
    }

    @Test func aRepExercisesPreviousAndHistoryTextAreUnchanged() throws {
        let context = ModelContext(try makeContainer())
        let past = try open(context)
        logBench(past, [(80, 10)])
        past.finish(now: past.startedAt.addingTimeInterval(60))
        let stored = try #require(all(StepResult.self, context).first)
        #expect(SessionHistoryPresentation.setValueText(stored) == "\(SetWeight.display(80)) × 10 回")

        let next = try open(context)
        next.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        let previous = try #require(next.cards.first?.previousText)
        #expect(previous != "実施済み" && previous.contains("10"))
    }

    @Test func aRepCountedExerciseStillTracksReps() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        model.addExercise(exerciseId: "pull_up", title: "プルアップ")
        #expect(model.cards.first?.tracksReps == true)
        #expect(model.cards.first?.acceptsWeight == true)   // added weight can be entered
    }

    @Test func aFractionalFreeWorkoutDurationMatchesHistory() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        logBench(model, [(80, 10)])
        model.finish(now: model.startedAt.addingTimeInterval(1_832.7))
        let summary = try #require(model.completion)
        #expect(summary.duration == 1_832)
        #expect(try historySummary(context).duration == summary.duration)
    }

    @Test func draftRowsAndUnloggedExercisesAddNothing() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        logBench(model, [(80, 10)])
        model.addSet(to: model.cards[0].id)
        model.setWeight(100, for: key(model, card: 0, set: 1))   // typed, never logged
        model.addExercise(exerciseId: "smith_bench_press", title: "スミスマシンベンチプレス")
        model.finish()

        let summary = try #require(model.completion)
        #expect(summary.completedExerciseCount == 1)
        #expect(summary.completedSetCount == 1)
        #expect(summary.totalVolumeKg == 800)
    }

    @Test func anOverwrittenSetCountsWithItsNewValuesOnly() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        logBench(model, [(80, 10)])
        let row = key(model, card: 0, set: 0)
        model.setWeight(85, for: row); model.setReps(8, for: row)
        model.finish()

        #expect(model.completion?.totalVolumeKg == 680)
        #expect(model.completion?.totalReps == 8)
        #expect(try historySummary(context).totalVolumeKg == 680)
    }

    @Test func aDeletedSetIsNotCounted() throws {
        let context = ModelContext(try makeContainer())
        let model = try open(context)
        logBench(model, [(80, 10), (60, 5)])
        model.removeSet(key(model, card: 0, set: 1))
        model.finish()

        let summary = try #require(model.completion)
        #expect(summary.completedSetCount == 1)
        #expect(summary.totalReps == 10)
        #expect(summary.totalVolumeKg == 800)
    }
}

// MARK: - Reps in reserve (domain only)

@MainActor
struct RepsInReserveTests {

    private func start() throws -> (FreeWorkoutSession, ModelContext) {
        let schema = Schema([Routine.self, Step.self, Session.self, StepResult.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let context = ModelContext(try ModelContainer(for: schema, configurations: [config]))
        return (try #require(FreeWorkoutSession.start(in: context, scope: .guest).session), context)
    }

    private func results(_ context: ModelContext) -> [StepResult] {
        ((try? context.fetch(FetchDescriptor<StepResult>())) ?? []).sorted { $0.setIndex < $1.setIndex }
    }

    @Test func validationAcceptsNilAndZeroToFourOnly() {
        #expect(RepsInReserve.isValid(nil))
        for value in 0...4 { #expect(RepsInReserve.isValid(value)) }
        #expect(!RepsInReserve.isValid(-1))
        #expect(!RepsInReserve.isValid(5))
        #expect(!RepsInReserve.isValid(Int.max))
    }

    @Test func aNewResultHasNoRepsInReserveAndCompletesWithout() throws {
        let (free, context) = try start()
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        let result = try #require(free.completeSet(at: 0, of: step, reps: 10, weightKg: 80))
        #expect(result.done && result.actualReps == 10 && result.weightKg == 80)
        #expect(result.repsInReserve == nil)
        #expect(StepResult(sessionId: UUID(), stepId: UUID(), setIndex: 0, done: true).repsInReserve == nil)
        #expect(results(context).count == 1)
    }

    @Test func aDoneSetStoresZeroTwoAndFour() throws {
        let (free, _) = try start()
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        free.completeSet(at: 0, of: step, reps: 10, weightKg: 80)
        for value in [0, 2, 4] {
            #expect(free.recordRepsInReserve(value, at: 0, of: step)?.repsInReserve == value)
        }
    }

    @Test func outOfRangeValuesAreRejectedNotClamped() throws {
        let (free, context) = try start()
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        free.completeSet(at: 0, of: step, reps: 10, weightKg: 80)
        free.recordRepsInReserve(2, at: 0, of: step)
        #expect(free.recordRepsInReserve(-1, at: 0, of: step) == nil)
        #expect(free.recordRepsInReserve(5, at: 0, of: step) == nil)     // not stored as 4
        #expect(results(context).map(\.repsInReserve) == [2])
        #expect(results(context).first.map { $0.done && $0.actualReps == 10 && $0.weightKg == 80 } == true)
    }

    @Test func updatesAfterCompletionTouchOnlyRepsInReserve() throws {
        let (free, context) = try start()
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        free.completeSet(at: 0, of: step, reps: 10, weightKg: 80)
        #expect(free.recordRepsInReserve(2, at: 0, of: step)?.repsInReserve == 2)    // nil → 2
        #expect(free.recordRepsInReserve(1, at: 0, of: step)?.repsInReserve == 1)    // 2 → 1, latest only
        #expect(results(context).map(\.repsInReserve) == [1])
        let cleared = try #require(free.recordRepsInReserve(nil, at: 0, of: step))   // 1 → nil
        #expect(cleared.repsInReserve == nil)
        #expect(cleared.done && cleared.actualReps == 10 && cleared.weightKg == 80)
        #expect(cleared.actualDurationSeconds == nil)
        #expect(results(context).count == 1)
    }

    @Test func reRecordingWeightOrRepsKeepsRepsInReserve() throws {
        let (free, context) = try start()
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        free.completeSet(at: 0, of: step, reps: 10, weightKg: 80)
        free.recordRepsInReserve(2, at: 0, of: step)
        free.completeSet(at: 0, of: step, reps: 9, weightKg: 82.5)
        let result = try #require(results(context).first)
        #expect(result.actualReps == 9 && result.weightKg == 82.5 && result.repsInReserve == 2)
    }

    @Test func skippingClearsItAndASkippedOrUnloggedSetTakesNone() throws {
        let (free, context) = try start()
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 2))
        free.completeSet(at: 0, of: step, reps: 10, weightKg: 80)
        free.recordRepsInReserve(3, at: 0, of: step)
        free.skipSet(at: 0, of: step)                                   // done → skip
        #expect(results(context).map(\.repsInReserve) == [nil])
        #expect(free.recordRepsInReserve(2, at: 0, of: step) == nil)    // skipped
        #expect(free.recordRepsInReserve(2, at: 1, of: step) == nil)    // not logged yet
        #expect(results(context).count == 1 && results(context)[0].repsInReserve == nil)
    }

    @Test func removingASetRemovesItsRepsInReserve() throws {
        let (free, context) = try start()
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 2))
        free.completeSet(at: 0, of: step, reps: 10, weightKg: 80)
        free.completeSet(at: 1, of: step, reps: 8, weightKg: 80)
        free.recordRepsInReserve(2, at: 0, of: step)
        free.recordRepsInReserve(0, at: 1, of: step)
        #expect(free.removeSet(at: 0, from: step))
        #expect(results(context).map(\.repsInReserve) == [0])
        #expect(results(context).map(\.actualReps) == [8])
    }

    @Test func aTimedSetNeverTakesRepsInReserveAndKeepsItsDuration() throws {
        let (free, context) = try start()
        let step = try #require(free.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミルウォームアップ"))
        free.completeTimedSet(at: 0, of: step, durationSeconds: 750)
        #expect(free.recordRepsInReserve(2, at: 0, of: step) == nil)
        // Even handed to the writer directly.
        #expect(StepResultWriter.recordRepsInReserve(2, in: context, sessionId: free.session.id, step: step, setIndex: 0) == nil)
        let result = try #require(results(context).first)
        #expect(result.repsInReserve == nil && result.actualDurationSeconds == 750 && result.actualReps == nil)
        #expect(SessionHistoryPresentation.setValueText(result) == "12分30秒")
        #expect(free.completeTimedSet(at: 0, of: step, durationSeconds: 600)?.actualDurationSeconds == 600)
    }

    @Test func aFinishedWorkoutTakesNoRepsInReserve() throws {
        let (free, context) = try start()
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        free.completeSet(at: 0, of: step, reps: 10, weightKg: 80)
        _ = free.finish()
        #expect(free.recordRepsInReserve(2, at: 0, of: step) == nil)
        #expect(results(context).first?.repsInReserve == nil)
    }
}

// MARK: - Reps in reserve (Free Workout rows)

@MainActor
struct FreeWorkoutRepsInReserveTests {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Routine.self, Step.self, Session.self, StepResult.self, DayLog.self])
        return ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]))
    }

    private func open(_ context: ModelContext, scope: WorkoutDataScope = .guest) throws -> FreeWorkoutViewModel {
        let launcher = FreeWorkoutLauncher(drafts: FreeWorkoutDraftStore())
        launcher.configure(context: context, scope: scope)
        launcher.start()
        return try #require(launcher.presented)
    }

    private func results(_ context: ModelContext) -> [StepResult] {
        ((try? context.fetch(FetchDescriptor<StepResult>())) ?? []).sorted { $0.setIndex < $1.setIndex }
    }

    @Test func onlyADoneRepSetTakesRIRAndTheRowShowsWhatIsStored() throws {
        let context = try makeContext()
        let model = try open(context)
        model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        let row = model.cards[0].rows[0].key
        #expect(!model.acceptsRepsInReserve(row))                  // draft
        model.adjustWeight(by: 80, for: row)
        model.complete(row)
        #expect(model.acceptsRepsInReserve(row))
        #expect(model.row(row)?.repsInReserve == nil)

        model.setRepsInReserve(2, for: row)                        // nil → 2
        #expect(model.row(row)?.repsInReserve == 2)
        #expect(results(context).map(\.repsInReserve) == [2])
        model.setRepsInReserve(1, for: row)                        // 2 → 1
        #expect(results(context).map(\.repsInReserve) == [1])
        model.setRepsInReserve(5, for: row)                        // refused; the row keeps what is stored
        #expect(model.row(row)?.repsInReserve == 1)
        model.setRepsInReserve(nil, for: row)                      // 1 → nil
        #expect(model.row(row)?.repsInReserve == nil)
        let stored = try #require(results(context).first)
        #expect(stored.repsInReserve == nil && stored.done && stored.actualReps == 10 && stored.weightKg == 80)
    }

    private func logPastBench(_ context: ModelContext, scope: WorkoutDataScope, rir: Int?) throws {
        let launcher = FreeWorkoutLauncher(drafts: FreeWorkoutDraftStore())
        launcher.configure(context: context, scope: scope)
        launcher.start()
        let past = try #require(launcher.presented)
        past.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        let row = past.cards[0].rows[0].key
        past.adjustWeight(by: 80, for: row)
        past.complete(row)
        past.setRepsInReserve(rir, for: row)
        past.finish(now: past.startedAt.addingTimeInterval(900))
        #expect(past.finishOutcome == .saved)
    }

    private func previousLine(_ context: ModelContext, scope: WorkoutDataScope) throws -> String? {
        let launcher = FreeWorkoutLauncher(drafts: FreeWorkoutDraftStore())
        launcher.configure(context: context, scope: scope)
        launcher.start()
        let next = try #require(launcher.presented)
        next.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        defer { next.discard() }
        return next.cards.first?.previousText
    }

    @Test func previousShowsLastTimesRIROnlyToItsOwner() throws {
        let context = try makeContext()
        let accountA = UUID()
        try logPastBench(context, scope: .account(accountA), rir: 4)
        #expect(try previousLine(context, scope: .account(accountA)) == "80\u{00A0}kg × 10 回 · RIR 4+")
        #expect(try previousLine(context, scope: .account(UUID())) == nil)
        #expect(try previousLine(context, scope: .guest) == nil)
    }

    @Test func previousWithoutRIRReadsAsBefore() throws {
        let context = try makeContext()
        try logPastBench(context, scope: .guest, rir: nil)
        #expect(try previousLine(context, scope: .guest) == "80\u{00A0}kg × 10 回")
    }

    @Test func reRecordingWeightAndRepsKeepsTheRIR() throws {
        let context = try makeContext()
        let model = try open(context)
        model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        let row = model.cards[0].rows[0].key
        model.adjustWeight(by: 80, for: row)
        model.complete(row)
        model.setRepsInReserve(2, for: row)
        model.adjustWeight(by: 2.5, for: row)                      // a done row is re-recorded at once
        model.adjustReps(by: -2, for: row)
        let stored = try #require(results(context).first)
        #expect(stored.weightKg == 82.5 && stored.actualReps == 8 && stored.repsInReserve == 2)
        #expect(model.row(row)?.repsInReserve == 2)
    }

    @Test func skippedAndTimedRowsTakeNoRIR() throws {
        let context = try makeContext()
        let model = try open(context)
        model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        model.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミルウォームアップ")
        let bench = model.cards[0].rows[0].key
        model.complete(bench)
        model.setRepsInReserve(3, for: bench)
        model.skip(bench)                                          // done → skipped
        #expect(!model.acceptsRepsInReserve(bench))
        #expect(model.row(bench)?.repsInReserve == nil)
        model.setRepsInReserve(2, for: bench)

        let timed = model.cards[1].rows[0].key
        model.setDuration(DurationEntry(minutes: "12", seconds: "30"), for: timed)
        model.complete(timed)
        #expect(model.row(timed)?.state == .done)
        #expect(!model.acceptsRepsInReserve(timed))
        model.setRepsInReserve(2, for: timed)
        #expect(results(context).allSatisfy { $0.repsInReserve == nil })
        #expect(results(context).compactMap(\.actualDurationSeconds) == [750])
    }

    @Test func bodyweightAndAssistedRepSetsTakeRIRToo() throws {
        let context = try makeContext()
        let model = try open(context)
        model.addExercise(exerciseId: "pull_up", title: "プルアップ")
        model.addExercise(exerciseId: "assisted_pull_up", title: "アシストプルアップ")
        #expect(model.cards.count == 2 && model.cards.allSatisfy(\.tracksReps))
        for card in model.cards {
            let row = card.rows[0].key
            model.complete(row)
            #expect(model.acceptsRepsInReserve(row) == card.tracksReps)
            model.setRepsInReserve(4, for: row)
            #expect(model.row(row)?.repsInReserve == (card.tracksReps ? 4 : nil))
        }
    }

    @Test func anotherAccountsOrAnEndedWorkoutCannotTakeRIR() throws {
        let context = try makeContext()
        let a = UUID(), b = UUID()
        let workoutA = try #require(FreeWorkoutSession.start(in: context, scope: .account(a)).session)
        let step = try #require(workoutA.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        workoutA.completeSet(at: 0, of: step, reps: 10, weightKg: 80)
        workoutA.recordRepsInReserve(2, at: 0, of: step)

        // Another account's workout, or the guest's, does not own A's step.
        let workoutB = try #require(FreeWorkoutSession.start(in: context, scope: .account(b)).session)
        #expect(workoutB.recordRepsInReserve(0, at: 0, of: step) == nil)
        let guest = try #require(FreeWorkoutSession.start(in: context, scope: .guest).session)
        #expect(guest.recordRepsInReserve(0, at: 0, of: step) == nil)
        #expect(results(context).map(\.repsInReserve) == [2])

        // Once A's workout has ended (abandoned here), nothing is written.
        workoutA.session.status = .abandoned
        #expect(workoutA.recordRepsInReserve(1, at: 0, of: step) == nil)
        #expect(results(context).map(\.repsInReserve) == [2])
        #expect(results(context).first?.ownerAccountID == a)
    }
}

// MARK: - Set type (domain only)

@MainActor
struct WorkoutSetTypeTests {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Routine.self, Step.self, Session.self, StepResult.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    private func start(_ context: ModelContext, scope: WorkoutDataScope = .guest) throws -> FreeWorkoutSession {
        try #require(FreeWorkoutSession.start(in: context, scope: scope).session)
    }

    private func results(_ free: FreeWorkoutSession, _ step: Step) -> [StepResult] { free.results(for: step) }

    // A–D: reading what is stored.
    @Test func storedValuesReadAsWarmupOrWorkingAndNothingElse() {
        #expect(WorkoutSetType(storedRawValue: nil) == .working)
        #expect(WorkoutSetType(storedRawValue: "warmup") == .warmup)
        #expect(WorkoutSetType(storedRawValue: "working") == .working)
        #expect(WorkoutSetType(storedRawValue: "drop") == .working)       // unknown: working, never warm-up
        #expect(WorkoutSetType(storedRawValue: "") == .working)
        #expect(WorkoutSetType.allCases == [.warmup, .working])
        #expect(WorkoutSetType.working.storedRawValue == nil)
        #expect(WorkoutSetType.warmup.storedRawValue == "warmup")

        let unknown = StepResult(sessionId: UUID(), stepId: UUID(), setIndex: 0, done: true, setTypeRaw: "drop")
        #expect(unknown.setType == .working)
        #expect(unknown.setTypeRaw == "drop")                               // reading never rewrites it
        #expect(StepResult(sessionId: UUID(), stepId: UUID(), setIndex: 0, done: true).setTypeRaw == nil)
    }

    // E, F: kind at completion.
    @Test func aNewSetCompletesAsWorkingOrAsTheGivenKind() throws {
        let context = try makeContext()
        let free = try start(context)
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 3))
        #expect(free.completeSet(at: 0, of: step, reps: 15, weightKg: 20, setType: .warmup)?.setType == .warmup)
        #expect(free.completeSet(at: 1, of: step, reps: 10, weightKg: 80)?.setTypeRaw == nil)          // default
        #expect(free.completeSet(at: 2, of: step, reps: 10, weightKg: 80, setType: .working)?.setTypeRaw == nil)
        #expect(results(free, step).map(\.setType) == [.warmup, .working, .working])
    }

    // G, H: a done set changes kind and nothing else.
    @Test func aDoneSetChangesKindBothWaysAndKeepsEverythingElse() throws {
        let context = try makeContext()
        let free = try start(context)
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        let set = try #require(free.completeSet(at: 0, of: step, reps: 10, weightKg: 80))
        free.recordRepsInReserve(2, at: 0, of: step)
        let before = (set.id, set.sessionId, set.stepId, set.setIndex, set.done, set.weightKg, set.actualReps,
                      set.actualDurationSeconds, set.repsInReserve, set.ownerAccountID, set.plannedSetsAtExecution,
                      set.exerciseIdAtExecution, set.exerciseTitleAtExecution)

        #expect(free.recordSetType(.warmup, resultId: set.id, at: 0, of: step)?.setTypeRaw == "warmup")
        #expect(free.recordSetType(.working, resultId: set.id, at: 0, of: step)?.setTypeRaw == nil)
        #expect(free.recordSetType(.warmup, resultId: set.id, at: 0, of: step)?.setType == .warmup)
        let after = try #require(results(free, step).first)
        #expect(results(free, step).count == 1)
        #expect(after.id == before.0 && after.sessionId == before.1 && after.stepId == before.2 && after.setIndex == before.3)
        #expect(after.done == before.4 && after.weightKg == before.5 && after.actualReps == before.6)
        #expect(after.actualDurationSeconds == before.7 && after.repsInReserve == before.8 && after.ownerAccountID == before.9)
        #expect(after.plannedSetsAtExecution == before.10 && after.exerciseIdAtExecution == before.11)
        #expect(after.exerciseTitleAtExecution == before.12)
    }

    // I, J, K: re-recording and RIR leave the kind alone, and the kind leaves RIR alone.
    @Test func reRecordingAndRIRKeepTheKindAndTheKindKeepsRIR() throws {
        let context = try makeContext()
        let free = try start(context)
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        let set = try #require(free.completeSet(at: 0, of: step, reps: 10, weightKg: 80, setType: .warmup))
        free.recordRepsInReserve(2, at: 0, of: step)

        free.completeSet(at: 0, of: step, reps: 8, weightKg: 82.5)                 // no kind given: unchanged
        var result = try #require(results(free, step).first)
        #expect(result.setType == .warmup && result.repsInReserve == 2)
        #expect(result.weightKg == 82.5 && result.actualReps == 8)

        free.recordRepsInReserve(1, at: 0, of: step)                                // RIR keeps the kind
        free.recordRepsInReserve(nil, at: 0, of: step)
        result = try #require(results(free, step).first)
        #expect(result.setType == .warmup && result.repsInReserve == nil)

        free.recordRepsInReserve(3, at: 0, of: step)
        free.recordSetType(.working, resultId: set.id, at: 0, of: step)              // the kind keeps RIR
        result = try #require(results(free, step).first)
        #expect(result.setType == .working && result.repsInReserve == 3)

        free.completeSet(at: 0, of: step, reps: 8, weightKg: 82.5, setType: .warmup) // an explicit kind applies
        #expect(results(free, step).first?.setType == .warmup)
    }

    // L: timed sets have no kind.
    @Test func aTimedSetNeverTakesAKind() throws {
        let context = try makeContext()
        let free = try start(context)
        let step = try #require(free.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミルウォームアップ"))
        let set = try #require(free.completeTimedSet(at: 0, of: step, durationSeconds: 600))
        #expect(free.recordSetType(.warmup, resultId: set.id, at: 0, of: step) == nil)
        #expect(StepResultWriter.recordSetType(.warmup, in: context, resultId: set.id, sessionId: free.session.id, step: step) == nil)
        // Even handed to the writer with a kind.
        StepResultWriter.record(in: context, sessionId: free.session.id, ownerAccountID: nil, step: step, setIndex: 0,
                                done: true, actualReps: nil, weightKg: nil, actualDurationSeconds: 600,
                                plannedSets: .currentStepSets, setType: .warmup)
        let result = try #require(results(free, step).first)
        #expect(result.setTypeRaw == nil && result.actualDurationSeconds == 600)
    }

    // M, N: bodyweight and assisted exercises take a kind like any rep set.
    @Test func bodyweightAndAssistedSetsTakeAWarmup() throws {
        let context = try makeContext()
        let free = try start(context)
        let pull = try #require(free.addExercise(exerciseId: "pull_up", title: "懸垂"))
        let assisted = try #require(free.addExercise(exerciseId: "assisted_pull_up", title: "アシスト懸垂"))
        #expect(free.completeSet(at: 0, of: pull, reps: 5, weightKg: nil, setType: .warmup)?.setType == .warmup)
        let a = try #require(free.completeSet(at: 0, of: assisted, reps: 8, weightKg: 30))
        #expect(free.recordSetType(.warmup, resultId: a.id, at: 0, of: assisted)?.weightKg == 30)
    }

    // O: skipping is about whether it was done, not what kind it was.
    @Test func skippingKeepsTheKindClearsRIRAndANewSkipIsWorking() throws {
        let context = try makeContext()
        let free = try start(context)
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 3))
        free.completeSet(at: 0, of: step, reps: 15, weightKg: 20, setType: .warmup)
        free.recordRepsInReserve(4, at: 0, of: step)
        free.skipSet(at: 0, of: step)
        free.skipSet(at: 1, of: step)
        free.skipSet(at: 2, of: step, setType: .warmup)
        let all = results(free, step)
        #expect(all.map(\.done) == [false, false, false])
        #expect(all.map(\.setType) == [.warmup, .working, .warmup])
        #expect(all.map(\.repsInReserve) == [nil, nil, nil])
        #expect(free.recordSetType(.working, resultId: all[0].id, at: 0, of: step) == nil)   // only a done set changes
    }

    // P: an action for a removed set is refused; nothing else changes, nothing is recreated.
    @Test func anActionForARemovedSetIsRefused() throws {
        let context = try makeContext()
        let free = try start(context)
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 3))
        let a = try #require(free.completeSet(at: 0, of: step, reps: 10, weightKg: 80))
        let b = try #require(free.completeSet(at: 1, of: step, reps: 9, weightKg: 80))
        let bId = b.id
        let c = try #require(free.completeSet(at: 2, of: step, reps: 8, weightKg: 80))
        free.recordRepsInReserve(1, at: 2, of: step)
        #expect(free.removeSet(at: 1, from: step))                                  // C moves to index 1
        #expect(free.recordSetType(.warmup, resultId: bId, at: 1, of: step) == nil)
        let all = results(free, step)
        #expect(all.map(\.id) == [a.id, c.id])
        #expect(all.map(\.setType) == [.working, .working])
        #expect(all.map(\.repsInReserve) == [nil, 1])
    }

    // Q: a surviving set that moved refuses an action from before the move;
    // a fresh one at its new position lands on that same set only.
    @Test func aMovedSetRefusesAStaleActionAndTakesAFreshOne() throws {
        let context = try makeContext()
        let free = try start(context)
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 2))
        free.completeSet(at: 0, of: step, reps: 10, weightKg: 80)
        let b = try #require(free.completeSet(at: 1, of: step, reps: 9, weightKg: 80))
        #expect(free.removeSet(at: 0, from: step))                                  // B: index 1 → 0
        #expect(free.recordSetType(.warmup, resultId: b.id, at: 1, of: step) == nil)
        #expect(results(free, step).map(\.setType) == [.working])
        #expect(free.recordSetType(.warmup, resultId: b.id, at: 0, of: step)?.id == b.id)
        #expect(results(free, step).map(\.setType) == [.warmup])
    }

    // R: another session's result is never reachable, even with the same step and set.
    @Test func anotherSessionsSetIsNeverChanged() throws {
        let context = try makeContext()
        let first = try start(context)
        let step = try #require(first.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        let old = try #require(first.completeSet(at: 0, of: step, reps: 10, weightKg: 80))
        _ = first.finish()
        let second = try start(context)
        let secondStep = try #require(second.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        let current = try #require(second.completeSet(at: 0, of: secondStep, reps: 10, weightKg: 80))
        #expect(second.recordSetType(.warmup, resultId: old.id, at: 0, of: secondStep) == nil)
        // The same step and set index in two sessions (as a routine run twice):
        // the writer refuses a result id from the other session.
        let other = UUID()
        let twin = StepResultWriter.record(in: context, sessionId: other, ownerAccountID: nil, step: secondStep,
                                           setIndex: 0, done: true, actualReps: 10, weightKg: 80)
        #expect(StepResultWriter.recordSetType(.warmup, in: context, resultId: twin.id, sessionId: second.session.id, step: secondStep) == nil)
        #expect(StepResultWriter.recordSetType(.warmup, in: context, resultId: current.id, sessionId: other, step: secondStep) == nil)
        #expect(old.setTypeRaw == nil && current.setTypeRaw == nil && twin.setTypeRaw == nil)
    }

    // S: only the owner reaches a workout, and a result with another owner is refused.
    @Test func ownershipDecidesWhoCanChangeAKind() throws {
        let context = try makeContext()
        let accountA = UUID(), accountB = UUID()
        let free = try start(context, scope: .account(accountA))
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        let set = try #require(free.completeSet(at: 0, of: step, reps: 10, weightKg: 80))
        #expect(set.ownerAccountID == accountA)
        #expect(FreeWorkoutSession.resume(free.session, in: context, scope: .account(accountB)) == nil)
        #expect(FreeWorkoutSession.resume(free.session, in: context, scope: .guest) == nil)
        let resumed = try #require(FreeWorkoutSession.resume(free.session, in: context, scope: .account(accountA)))
        set.ownerAccountID = accountB                                                // a result not this owner's
        #expect(resumed.recordSetType(.warmup, resultId: set.id, at: 0, of: step) == nil)
        set.ownerAccountID = accountA
        #expect(resumed.recordSetType(.warmup, resultId: set.id, at: 0, of: step)?.setType == .warmup)

        let guestContext = try makeContext()
        let guest = try start(guestContext)
        #expect(FreeWorkoutSession.resume(guest.session, in: guestContext, scope: .account(accountA)) == nil)
    }

    // T: a finished or abandoned workout takes no change.
    @Test func aFinishedOrAbandonedWorkoutTakesNoKind() throws {
        let context = try makeContext()
        let free = try start(context)
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        let set = try #require(free.completeSet(at: 0, of: step, reps: 10, weightKg: 80))
        _ = free.finish()
        #expect(free.recordSetType(.warmup, resultId: set.id, at: 0, of: step) == nil)

        let other = try makeContext()
        let abandoned = try start(other)
        let otherStep = try #require(abandoned.addExercise(exerciseId: "bench_press", title: "ベンチプレス"))
        let otherSet = try #require(abandoned.completeSet(at: 0, of: otherStep, reps: 10, weightKg: 80))
        abandoned.session.status = .abandoned
        #expect(abandoned.recordSetType(.warmup, resultId: otherSet.id, at: 0, of: otherStep) == nil)
        #expect(abandoned.completeSet(at: 0, of: otherStep, reps: 10, weightKg: 80, setType: .warmup) == nil)
        #expect(set.setTypeRaw == nil && otherSet.setTypeRaw == nil)
    }

    // U: a resumed workout still has its warm-ups.
    @Test func aResumedWorkoutKeepsItsWarmups() throws {
        let context = try makeContext()
        let free = try start(context)
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 2))
        free.completeSet(at: 0, of: step, reps: 15, weightKg: 20, setType: .warmup)
        free.completeSet(at: 1, of: step, reps: 10, weightKg: 80)
        try context.save()
        let candidate = try #require(FreeWorkoutRecovery.latest(in: context, scope: .guest))
        let resumed = try #require(FreeWorkoutRecovery.resume(candidate, in: context, scope: .guest))
        let resumedStep = try #require(resumed.steps.first)
        #expect(resumed.results(for: resumedStep).map(\.setType) == [.warmup, .working])
    }

    // Reordering exercises and removing a set keep each record's own kind and RIR.
    @Test func reorderingAndRemovingNeverMoveAKindOrRIR() throws {
        let context = try makeContext()
        let free = try start(context)
        let bench = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 3))
        let row = try #require(free.addExercise(exerciseId: "seated_row", title: "シーテッドロウ"))
        free.completeSet(at: 0, of: bench, reps: 15, weightKg: 20, setType: .warmup)
        free.completeSet(at: 1, of: bench, reps: 10, weightKg: 80)
        free.completeSet(at: 2, of: bench, reps: 8, weightKg: 80)
        free.recordRepsInReserve(2, at: 1, of: bench)
        free.completeSet(at: 0, of: row, reps: 12, weightKg: 40, setType: .warmup)
        #expect(free.moveExercise(from: 0, to: 1))
        #expect(free.removeSet(at: 0, from: bench))
        #expect(results(free, bench).map(\.setType) == [.working, .working])
        #expect(results(free, bench).map(\.repsInReserve) == [2, nil])
        #expect(results(free, bench).map(\.actualReps) == [10, 8])
        #expect(results(free, row).map(\.setType) == [.warmup])
    }
}

// MARK: - #264: a scope change revokes every Free Workout held before it

@MainActor
struct FreeWorkoutScopeInvalidationTests {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Routine.self, Step.self, Session.self, StepResult.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    // RED on the pre-fix code: the launcher took the new scope, but the open
    // workout and its session kept writing as the old account.
    @Test func aLauncherScopeChangeClosesTheWorkoutAndItsSessionStopsWriting() throws {
        let context = try makeContext()
        let a = UUID(), b = UUID()
        let launcher = FreeWorkoutLauncher(drafts: FreeWorkoutDraftStore())
        launcher.configure(context: context, scope: .account(a))
        launcher.start()
        let model = try #require(launcher.presented)
        let free = model.session
        let step = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 2))
        #expect(free.completeSet(at: 0, of: step, reps: 10, weightKg: 80) != nil)

        launcher.configure(context: context, scope: .account(b))

        #expect(launcher.presented == nil)
        #expect(free.completeSet(at: 1, of: step, reps: 8, weightKg: 80) == nil)
        #expect(free.results(for: step).count == 1)
    }
}

@MainActor
extension FreeWorkoutScopeInvalidationTests {

    /// What a refused mutation must leave untouched.
    private struct Snapshot: Equatable {
        struct Row: Equatable {
            let id: UUID, setIndex: Int, done: Bool, reps: Int?, weight: Double?
            let duration: Int?, rir: Int?, type: String?, owner: UUID?
        }
        let sessionId: UUID, status: SessionStatus, owner: UUID?
        let endedAt: Date?, totalSeconds: Int
        let routineCount: Int, stepIds: [UUID], stepSets: [Int], rows: [Row]
    }

    private func snapshot(_ free: FreeWorkoutSession, _ context: ModelContext) throws -> Snapshot {
        let rows = try context.fetch(FetchDescriptor<StepResult>())
            .filter { $0.sessionId == free.session.id }
            .sorted { ($0.stepId.uuidString, $0.setIndex) < ($1.stepId.uuidString, $1.setIndex) }
            .map { Snapshot.Row(id: $0.id, setIndex: $0.setIndex, done: $0.done, reps: $0.actualReps, weight: $0.weightKg,
                                duration: $0.actualDurationSeconds, rir: $0.repsInReserve, type: $0.setTypeRaw, owner: $0.ownerAccountID) }
        let routineId = free.routine.id
        let steps = try context.fetch(FetchDescriptor<Step>()).filter { $0.routineId == routineId }.sorted { $0.order < $1.order }
        return Snapshot(sessionId: free.session.id, status: free.session.status, owner: free.session.ownerAccountID,
                        endedAt: free.session.endedAt, totalSeconds: free.session.totalSeconds,
                        routineCount: try context.fetch(FetchDescriptor<Routine>()).filter { $0.id == routineId }.count,
                        stepIds: steps.map(\.id), stepSets: steps.map(\.sets), rows: rows)
    }

    /// A workout of `owner` with a Warm-up set at RIR 2 (80 kg × 10), a
    /// working set, a skipped set, a timed set, and an empty exercise.
    private func recordedWorkout(_ context: ModelContext, scope: WorkoutDataScope, authority: WorkoutScopeAuthority) throws -> (FreeWorkoutSession, bench: Step, timed: Step, empty: Step) {
        let free = try #require(FreeWorkoutSession.start(in: context, scope: scope, authority: authority).session)
        let bench = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 3))
        let timed = try #require(free.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミルウォームアップ"))
        let empty = try #require(free.addExercise(exerciseId: "seated_row", title: "シーテッドロー"))
        #expect(free.completeSet(at: 0, of: bench, reps: 10, weightKg: 80, setType: .warmup) != nil)
        #expect(free.recordRepsInReserve(2, at: 0, of: bench) != nil)
        #expect(free.completeSet(at: 1, of: bench, reps: 8, weightKg: 100) != nil)
        #expect(free.skipSet(at: 2, of: bench) != nil)
        #expect(free.completeTimedSet(at: 0, of: timed, durationSeconds: 600) != nil)
        try context.save()
        return (free, bench, timed, empty)
    }

    /// Every FreeWorkoutSession mutation, each through its real API, refused.
    private func expectEveryMutationRefused(_ free: FreeWorkoutSession, bench: Step, timed: Step, empty: Step, _ context: ModelContext) throws {
        let before = try snapshot(free, context)
        let warmupId = try #require(free.results(for: bench).first?.id)
        #expect(!free.isActive)
        #expect(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス") == nil)
        #expect(free.addExercise(try #require(ExerciseLibrary.exercise(for: ExerciseID("bench_press")))) == nil)
        #expect(!free.canRemoveExercise(empty))
        #expect(!free.removeExercise(empty))
        #expect(!free.moveExercise(from: 0, to: 2))
        #expect(!free.addSet(to: bench))
        #expect(!free.removeSet(at: 0, from: bench))
        #expect(free.completeSet(at: 0, of: bench, reps: 5, weightKg: 50) == nil)                 // rerecord
        #expect(free.completeSet(at: 0, of: bench, reps: 10, weightKg: 80, setType: .working) == nil)
        #expect(free.completeTimedSet(at: 0, of: timed, durationSeconds: 30) == nil)
        #expect(free.skipSet(at: 0, of: bench) == nil)
        #expect(free.skipSet(at: 2, of: bench, setType: .warmup) == nil)
        #expect(free.recordRepsInReserve(4, at: 0, of: bench) == nil)
        #expect(free.recordRepsInReserve(nil, at: 0, of: bench) == nil)
        #expect(free.recordSetType(.working, resultId: warmupId, at: 0, of: bench) == nil)
        #expect(free.finish(now: Date().addingTimeInterval(3600)) == .notActive)
        #expect(!free.discard())
        try context.save()
        #expect(try snapshot(free, context) == before)
    }

    // A, B, C, D and guest → undetermined: the held object refuses everything.
    @Test(arguments: [
        (WorkoutDataScope.account(UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!), WorkoutDataScope.account(UUID())),
        (.account(UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!), .guest),
        (.guest, .account(UUID())),
        (.account(UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!), .undetermined),
        (.guest, .undetermined),
    ])
    func aScopeChangeRevokesTheHeldSessionForEveryMutation(from: WorkoutDataScope, to: WorkoutDataScope) throws {
        let context = try makeContext()
        let authority = WorkoutScopeAuthority(scope: from)
        let (free, bench, timed, empty) = try recordedWorkout(context, scope: from, authority: authority)
        #expect(free.isActive)

        authority.update(to)

        try expectEveryMutationRefused(free, bench: bench, timed: timed, empty: empty, context)
        let results = free.results(for: bench)
        #expect(results.map(\.setTypeRaw) == ["warmup", nil, nil])
        #expect(results[0].repsInReserve == 2 && results[0].actualReps == 10 && results[0].weightKg == 80)
        #expect(free.session.status == .inProgress)              // revoked, not discarded or finished
        #expect(free.session.endedAt == nil)
        #expect(FreeWorkoutSession.start(in: context, scope: from, authority: authority).session == nil)  // a stale scope creates nothing
    }

    // E: A → B → A. The first A object stays dead; only a re-opened one writes.
    @Test func comingBackToTheSameAccountNeverRevivesAnOldSession() throws {
        let context = try makeContext()
        let a = UUID()
        let authority = WorkoutScopeAuthority(scope: .account(a))
        let (old, bench, timed, empty) = try recordedWorkout(context, scope: .account(a), authority: authority)
        let resultIds = old.results(for: bench).map(\.id)

        authority.update(.account(UUID()))
        authority.update(.account(a))

        #expect(authority.scope == .account(a))
        try expectEveryMutationRefused(old, bench: bench, timed: timed, empty: empty, context)

        // Recovery: the same workout, intact, under a new object.
        let candidate = try #require(FreeWorkoutRecovery.candidates(in: context, scope: .account(a)).first)
        let fresh = try #require(FreeWorkoutRecovery.resume(candidate, in: context, scope: .account(a), authority: authority))
        #expect(fresh.session.id == old.session.id)
        let kept = fresh.results(for: bench)
        #expect(kept.map(\.id) == resultIds)
        #expect(kept.map(\.setTypeRaw) == ["warmup", nil, nil])
        #expect(kept[0].repsInReserve == 2 && kept[0].actualReps == 10 && kept[0].weightKg == 80)
        #expect(kept[1].actualReps == 8 && kept[1].weightKg == 100 && !kept[2].done)
        #expect(fresh.results(for: timed).first?.actualDurationSeconds == 600)
        #expect(fresh.isActive)
        #expect(fresh.completeSet(at: 2, of: bench, reps: 6, weightKg: 100) != nil)
        #expect(fresh.recordSetType(.working, resultId: resultIds[0], at: 0, of: bench)?.setTypeRaw == nil)
        #expect(!old.isActive)                                     // still dead after the new one wrote
        #expect(old.completeSet(at: 1, of: bench, reps: 1, weightKg: 1) == nil)
        #expect(fresh.finish() == .saved)
    }

    // F, G: re-stating the same scope keeps every grant and normal operations.
    @Test(arguments: [WorkoutDataScope.account(UUID()), .guest])
    func reStatingTheSameScopeKeepsTheWorkout(scope: WorkoutDataScope) throws {
        let context = try makeContext()
        let authority = WorkoutScopeAuthority(scope: scope)
        let launcher = FreeWorkoutLauncher(drafts: FreeWorkoutDraftStore())
        launcher.configure(context: context, scope: scope, authority: authority)
        launcher.start()
        let model = try #require(launcher.presented)
        authority.update(scope)
        launcher.configure(context: context, scope: scope, authority: authority)
        #expect(launcher.presented === model)
        let free = model.session
        #expect(free.isActive)
        let bench = try #require(free.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 2))
        let timed = try #require(free.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミルウォームアップ"))
        #expect(free.addSet(to: bench))
        let done = try #require(free.completeSet(at: 0, of: bench, reps: 10, weightKg: 80, setType: .warmup))
        #expect(free.recordRepsInReserve(2, at: 0, of: bench) != nil)
        #expect(free.recordSetType(.working, resultId: done.id, at: 0, of: bench) != nil)
        #expect(free.skipSet(at: 1, of: bench) != nil)
        #expect(free.removeSet(at: 2, from: bench))
        #expect(free.completeTimedSet(at: 0, of: timed, durationSeconds: 300) != nil)
        #expect(free.moveExercise(from: 1, to: 0))
        #expect(free.finish() == .saved)
    }

    @Test func aSameScopeDiscardStillWorks() throws {
        let context = try makeContext()
        let authority = WorkoutScopeAuthority(scope: .guest)
        let (free, _, _, _) = try recordedWorkout(context, scope: .guest, authority: authority)
        #expect(free.discard())
        #expect(try context.fetch(FetchDescriptor<Session>()).isEmpty)
    }

    // Presentation + ViewModel + stale closure, through the production wiring.
    @Test func aScopeChangeClosesTheScreenAndItsViewModelAndActionsGoNowhere() throws {
        let context = try makeContext()
        let a = UUID(), b = UUID()
        let drafts = FreeWorkoutDraftStore()
        let resolver = WorkoutDataScopeResolver(fixed: .account(a))
        let launcher = FreeWorkoutLauncher(drafts: drafts)
        launcher.configure(context: context, scope: resolver.scope, authority: resolver.authority)
        launcher.start()
        let model = try #require(launcher.presented)
        model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        let bench = try #require(model.cards.first?.id)
        let key = FreeWorkoutViewModel.RowKey(stepId: bench, setIndex: 0)
        model.setWeight(80, for: key)
        model.complete(key)
        model.addSet(to: bench)
        let open = FreeWorkoutViewModel.RowKey(stepId: bench, setIndex: 1)
        model.setWeight(60, for: open)
        let staleComplete = { model.complete(open) }                 // an action made while it was open
        let staleDrafts = drafts.drafts(for: model.id)
        let before = try snapshot(model.session, context)

        // The account changes; the screen is still on screen until SwiftUI's
        // next update delivers `onChange`.
        let authority = resolver.authority
        authority.update(.account(b))
        staleComplete()
        model.setWeight(100, for: open)
        model.setRepsInReserve(3, for: key)
        model.skip(open)
        model.addSet(to: bench)
        model.removeSet(key)
        model.removeExercise(bench)
        model.addExercise(exerciseId: "seated_row", title: "シーテッドロー")
        model.finish()
        model.discard()
        #expect(model.finishOutcome == nil)
        #expect(try snapshot(model.session, context) == before)
        #expect(drafts.drafts(for: model.id) == staleDrafts)

        launcher.configure(context: context, scope: .account(b), authority: authority)
        #expect(launcher.presented == nil)

        // B starts its own workout; A's stale action never lands in it.
        launcher.start()
        let other = try #require(launcher.presented)
        #expect(other.id != model.id && other.session.session.ownerAccountID == b)
        other.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        staleComplete()
        model.complete(key)
        #expect(other.session.steps.flatMap { other.session.results(for: $0) }.isEmpty)
        #expect(try snapshot(model.session, context) == before)
        #expect(drafts.drafts(for: other.id).values.allSatisfy { !$0.edited })
    }

    // Two launchers (Training and History) share the app's authority: a
    // workout opened from either is revoked by one scope change.
    @Test func everyLauncherSWorkoutIsRevokedByOneScopeChange() throws {
        let context = try makeContext()
        let a = UUID()
        let authority = WorkoutScopeAuthority(scope: .account(a))
        let training = FreeWorkoutLauncher(drafts: FreeWorkoutDraftStore())
        let history = FreeWorkoutLauncher(drafts: FreeWorkoutDraftStore())
        training.configure(context: context, scope: .account(a), authority: authority)
        history.configure(context: context, scope: .account(a), authority: authority)
        training.start()
        let first = try #require(training.presented)
        #expect(history.resume(sessionId: first.id))
        let second = try #require(history.presented)
        #expect(second.session !== first.session)

        authority.update(.guest)                                    // before either hears of it

        #expect(!first.session.isActive && !second.session.isActive)
        #expect(first.session.addExercise(exerciseId: "bench_press", title: "ベンチプレス") == nil)
        #expect(second.session.addExercise(exerciseId: "bench_press", title: "ベンチプレス") == nil)
        // An action racing the change sees the authority's scope, not the
        // launcher's stale one: nothing is created under A.
        training.workoutScreenClosed(try #require(training.presented))
        training.start()
        #expect(training.presented?.session.session.ownerAccountID == nil)
        #expect(try context.fetch(FetchDescriptor<Session>()).filter { $0.ownerAccountID == a }.count == 1)
    }
}

@MainActor
extension FreeWorkoutScopeInvalidationTests {

    // A's screen is closed by the scope change; its close callback arriving
    // late must not close B's newly opened screen.
    @Test func aLateCloseFromTheOldScreenLeavesTheNewOneOpen() throws {
        let context = try makeContext()
        let authority = WorkoutScopeAuthority(scope: .account(UUID()))
        let launcher = FreeWorkoutLauncher(drafts: FreeWorkoutDraftStore())
        launcher.configure(context: context, scope: authority.scope, authority: authority)
        launcher.start()
        let old = try #require(launcher.presented)
        // The views' `onClose`, bound to the workout the screen showed.
        let staleClose = { launcher.workoutScreenClosed(old) }

        authority.update(.account(UUID()))
        launcher.configure(context: context, scope: authority.scope, authority: authority)
        launcher.start()
        let current = try #require(launcher.presented)
        #expect(current.id != old.id)

        staleClose()

        #expect(launcher.presented === current)
        launcher.workoutScreenClosed(current)                     // its own close still closes it
        #expect(launcher.presented == nil)
    }
}

@MainActor
extension FreeWorkoutScopeInvalidationTests {

    // A → B → A, then the same stored workout is resumed: the new screen has
    // the old one's session id but is a different screen, and the old one's
    // late close must not close it.
    @Test func aLateCloseFromTheSameResumedSessionLeavesTheNewScreenOpen() throws {
        let context = try makeContext()
        let a = UUID()
        let authority = WorkoutScopeAuthority(scope: .account(a))
        let launcher = FreeWorkoutLauncher(drafts: FreeWorkoutDraftStore())
        launcher.configure(context: context, scope: authority.scope, authority: authority)
        launcher.start()
        let oldModel = try #require(launcher.presented)
        let bench = try #require(oldModel.session.addExercise(exerciseId: "bench_press", title: "ベンチプレス", initialSets: 2))
        #expect(oldModel.session.completeSet(at: 0, of: bench, reps: 10, weightKg: 80, setType: .warmup) != nil)
        #expect(oldModel.session.recordRepsInReserve(2, at: 0, of: bench) != nil)
        try context.save()
        let staleClose = closeAction(launcher, oldModel)

        authority.update(.account(UUID()))
        launcher.configure(context: context, scope: authority.scope, authority: authority)
        authority.update(.account(a))
        launcher.configure(context: context, scope: authority.scope, authority: authority)
        let candidate = try #require(launcher.candidates.first)
        launcher.resume(candidate)
        let newModel = try #require(launcher.presented)
        #expect(oldModel.id == newModel.id)
        #expect(oldModel !== newModel)
        #expect(launcher.presented === newModel)
        let before = try snapshot(newModel.session, context)

        staleClose()
        staleClose()

        #expect(launcher.presented === newModel)
        #expect(newModel.session.isActive)
        #expect(!oldModel.session.isActive)
        #expect(try snapshot(newModel.session, context) == before)
        #expect(newModel.session.results(for: bench).first?.setTypeRaw == "warmup")

        closeAction(launcher, newModel)()                         // its own close still closes it
        #expect(launcher.presented == nil)
        #expect(newModel.session.session.status == .inProgress)  // closing is not finishing
    }

    // No scope change: the screen is closed and the same workout resumed.
    @Test func aLateCloseAfterASameScopeResumeLeavesTheNewScreenOpen() throws {
        let context = try makeContext()
        let launcher = FreeWorkoutLauncher(drafts: FreeWorkoutDraftStore())
        let authority = WorkoutScopeAuthority(scope: .guest)
        launcher.configure(context: context, scope: .guest, authority: authority)
        launcher.start()
        let oldModel = try #require(launcher.presented)
        oldModel.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        let staleClose = closeAction(launcher, oldModel)
        staleClose()
        #expect(launcher.presented == nil)

        #expect(launcher.resume(sessionId: oldModel.id))
        let newModel = try #require(launcher.presented)
        #expect(newModel !== oldModel && newModel.id == oldModel.id)

        staleClose()

        #expect(launcher.presented === newModel)
        #expect(newModel.session.isActive)
    }
}

@MainActor
extension FreeWorkoutScopeInvalidationTests {
    /// The `onClose` TrainingMoreView and HistoryView hand the screen,
    /// captured when it was shown.
    fileprivate func closeAction(_ launcher: FreeWorkoutLauncher, _ model: FreeWorkoutViewModel) -> () -> Void {
        { launcher.workoutScreenClosed(model) }
    }
}

// MARK: - Set Type controls (PR-C)

/// Free Workout set kinds through the production ViewModel and domain: the
/// open-row draft, logging, changing a logged set, numbering, prefill by
/// working position, and that an action made for one row never lands on
/// another — after removals, re-adds, a close and resume, or a scope change.
@MainActor
struct FreeWorkoutSetTypeControlTests {
    private typealias Key = FreeWorkoutViewModel.RowKey

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Routine.self, Step.self, Session.self, StepResult.self, DayLog.self])
        return ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]))
    }

    private func results(_ context: ModelContext) -> [StepResult] {
        ((try? context.fetch(FetchDescriptor<StepResult>())) ?? []).sorted { $0.setIndex < $1.setIndex }
    }

    /// A finished bench workout in the past, working sets only.
    private func pastBench(_ context: ModelContext, _ sets: [(Double, Int)], owner: UUID? = nil, daysAgo: Double = 2) {
        let date = Date().addingTimeInterval(-daysAgo * 86_400)
        let routine = Routine(name: "胸の日")
        let step = Step(routineId: routine.id, order: 0, title: "ベンチプレス", sets: sets.count, repsTarget: 10,
                        restSeconds: 90, exerciseId: "bench_press")
        let session = Session(routineId: routine.id, dayDate: date, startedAt: date, endedAt: date, status: .completed,
                              ownerAccountID: owner)
        context.insert(routine); context.insert(step); context.insert(session)
        for (index, set) in sets.enumerated() {
            StepResultWriter.record(in: context, sessionId: session.id, ownerAccountID: owner, step: step,
                                    setIndex: index, done: true, actualReps: set.1, weightKg: set.0)
        }
        try? context.save()
    }

    private func launcher(_ context: ModelContext, _ drafts: FreeWorkoutDraftStore? = nil,
                          scope: WorkoutDataScope = .guest, authority: WorkoutScopeAuthority? = nil) -> FreeWorkoutLauncher {
        let launcher = FreeWorkoutLauncher(drafts: drafts ?? FreeWorkoutDraftStore())
        launcher.configure(context: context, scope: scope, authority: authority)
        return launcher
    }

    /// A workout with one bench card of `sets` rows.
    private func benchWorkout(_ launcher: FreeWorkoutLauncher, sets: Int) throws -> (FreeWorkoutViewModel, UUID) {
        launcher.start()
        let model = try #require(launcher.presented)
        model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        let bench = try #require(model.cards.first?.id)
        for _ in 1..<sets { model.addSet(to: bench) }
        return (model, bench)
    }

    private func rows(_ model: FreeWorkoutViewModel, _ stepId: UUID) -> [FreeWorkoutViewModel.SetRow] {
        model.cards.first { $0.id == stepId }?.rows ?? []
    }

    private func labels(_ model: FreeWorkoutViewModel, _ stepId: UUID) -> [String] {
        rows(model, stepId).map(\.label.shortText)
    }

    private func setType(_ model: FreeWorkoutViewModel, _ type: WorkoutSetType, row index: Int, of stepId: UUID) {
        let row = rows(model, stepId)[index]
        model.setSetType(type, for: row.identity, at: row.key)
    }

    // MARK: numbering (pure)

    @Test func numberingCountsWorkingSetsOnly() {
        func text(_ types: [WorkoutSetType]) -> [String] {
            let labels = SetTypeNumbering.labels(types.enumerated().map { (setIndex: $0.offset, setType: $0.element) })
            return types.indices.map { labels[$0]!.shortText }
        }
        #expect(text([.working, .working, .working]) == ["1", "2", "3"])
        #expect(text([.warmup, .warmup, .working, .working, .working]) == ["W", "W", "1", "2", "3"])
        #expect(text([.working, .warmup, .working, .warmup, .working]) == ["1", "W", "2", "W", "3"])
        // A gap (a set never recorded) keeps "セット N" by setIndex without warm-ups.
        let gap = SetTypeNumbering.labels([(setIndex: 0, setType: .working), (setIndex: 2, setType: .working)])
        #expect(gap[2] == .working(3))
        #expect(SetTypeNumbering.Label.warmup.spokenText == "ウォームアップセット")
        #expect(SetTypeNumbering.Label.working(2).text == "セット 2")
    }

    @Test func numberingFollowsKindChangesSkipsAndRemovals() throws {
        let context = try makeContext()
        let (model, bench) = try benchWorkout(launcher(context), sets: 4)
        setType(model, .warmup, row: 0, of: bench)
        #expect(labels(model, bench) == ["W", "1", "2", "3"])
        setType(model, .working, row: 0, of: bench)
        #expect(labels(model, bench) == ["1", "2", "3", "4"])
        setType(model, .warmup, row: 1, of: bench)
        #expect(labels(model, bench) == ["1", "W", "2", "3"])
        // A skipped working set keeps its number; a skipped warm-up stays W.
        model.skip(rows(model, bench)[2].key)
        model.skip(rows(model, bench)[1].key)
        #expect(labels(model, bench) == ["1", "W", "2", "3"])
        #expect(rows(model, bench)[1].state == .skipped)
        #expect(results(context).first { $0.setIndex == 1 }?.setType == .warmup)
        #expect(results(context).first { $0.setIndex == 2 }?.setType == .working)
        model.removeSet(rows(model, bench)[1].key)
        #expect(labels(model, bench) == ["1", "2", "3"])
    }

    @Test func historyNumbersTheSameWayAndLegacyReadsAsBefore() throws {
        let context = try makeContext()
        let (model, bench) = try benchWorkout(launcher(context), sets: 4)
        setType(model, .warmup, row: 0, of: bench)
        for row in rows(model, bench) { model.complete(row.key) }
        let shown = labels(model, bench)
        let group = try #require(SessionHistoryPresentation.groupedResults(results: results(context), steps: model.session.steps).first)
        let history = SessionHistoryPresentation.setLabels(group)
        #expect(group.results.map { history[$0.id]!.shortText } == shown)
        #expect(shown == ["W", "1", "2", "3"])
        #expect(SessionHistoryPresentation.setAccessibilityLabel(group.results[0], label: history[group.results[0].id]).hasPrefix("ウォームアップセット、完了"))
        #expect(SessionHistoryPresentation.setAccessibilityLabel(group.results[1], label: history[group.results[1].id]).hasPrefix("セット 1、完了"))

        // Legacy and unknown kinds: "セット N" from setIndex, as before.
        pastBench(context, [(80, 10), (80, 9)])
        let legacy = results(context).filter { $0.sessionId != model.id }
        legacy[1].setTypeRaw = "future_kind"
        let legacyGroup = try #require(SessionHistoryPresentation.groupedResults(results: legacy, steps: []).first)
        let legacyLabels = SessionHistoryPresentation.setLabels(legacyGroup)
        #expect(legacyGroup.results.map { legacyLabels[$0.id]! } == [.working(1), .working(2)])
        #expect(SessionHistoryPresentation.setAccessibilityLabel(legacy[0]) == "セット 1、完了、80キログラム、10回")
        #expect(legacy[1].setTypeRaw == "future_kind")
    }

    // MARK: draft

    @Test func anOpenRowsKindIsADraftOnlyAndIsLoggedWithTheSet() throws {
        let context = try makeContext()
        let (model, bench) = try benchWorkout(launcher(context), sets: 3)
        #expect(rows(model, bench).allSatisfy { $0.setType == .working })
        setType(model, .warmup, row: 0, of: bench)
        setType(model, .warmup, row: 1, of: bench)
        #expect(results(context).isEmpty)                    // choosing a kind logs nothing
        #expect(rows(model, bench).allSatisfy { $0.state == .draft })

        model.complete(rows(model, bench)[0].key)            // warm-up complete
        model.skip(rows(model, bench)[1].key)                // warm-up skip
        model.complete(rows(model, bench)[2].key)            // working complete
        let stored = results(context)
        #expect(stored.map(\.setType) == [.warmup, .warmup, .working])
        #expect(stored.map(\.done) == [true, false, true])
        #expect(stored[2].setTypeRaw == nil)                 // working stays nil on disk

        // Finishing never keeps a row whose only change was its kind.
        model.addSet(to: bench)
        setType(model, .warmup, row: 3, of: bench)
        model.finish()
        #expect(model.finishOutcome == .saved)
        #expect(results(context).count == 3)
        #expect(results(context).allSatisfy { $0.plannedSetsAtExecution == 3 })
    }

    @Test func aDoneSetChangesKindKeepingEverythingElseAndReRecordingKeepsIt() throws {
        let context = try makeContext()
        let (model, bench) = try benchWorkout(launcher(context), sets: 1)
        let key = rows(model, bench)[0].key
        model.setWeight(80, for: key)
        model.setReps(8, for: key)
        model.complete(key)
        model.setRepsInReserve(2, for: key)
        let before = try #require(results(context).first)
        let id = before.id, owner = before.ownerAccountID, snapshot = before.plannedSetsAtExecution

        setType(model, .warmup, row: 0, of: bench)
        let after = try #require(results(context).first)
        #expect(after.id == id && after.setType == .warmup)
        #expect(after.weightKg == 80 && after.actualReps == 8 && after.repsInReserve == 2 && after.done)
        #expect(after.ownerAccountID == owner && after.plannedSetsAtExecution == snapshot)
        #expect(after.exerciseIdAtExecution == "bench_press")

        model.setWeight(82.5, for: key)                       // re-record: kind kept
        #expect(results(context).first?.setType == .warmup)
        #expect(results(context).first?.repsInReserve == 2)
        // A skipped set offers no kind change.
        model.addSet(to: bench)
        model.skip(rows(model, bench)[1].key)
        #expect(!model.acceptsSetType(rows(model, bench)[1].key))
        setType(model, .warmup, row: 1, of: bench)
        #expect(results(context).first { $0.setIndex == 1 }?.setType == .working)
        // Completing a skipped row keeps its kind (nil = unchanged).
        model.complete(rows(model, bench)[1].key)
        #expect(results(context).first { $0.setIndex == 1 }?.setType == .working)
    }

    @Test func removingARowMovesTheDraftsBelowWithEverythingTheyHold() throws {
        let context = try makeContext()
        let (model, bench) = try benchWorkout(launcher(context), sets: 3)
        let c = rows(model, bench)[2]
        setType(model, .warmup, row: 2, of: bench)
        model.setWeight(42.5, for: c.key)
        model.setReps(12, for: c.key)
        model.removeSet(rows(model, bench)[0].key)
        let moved = rows(model, bench)[1]
        #expect(moved.identity == c.identity)
        #expect(moved.setType == .warmup && moved.weightKg == 42.5 && moved.reps == 12)
        #expect(labels(model, bench) == ["1", "W"])
    }

    @Test func closeAndResumeKeepsAnOpenRowsKind() throws {
        let context = try makeContext()
        let drafts = FreeWorkoutDraftStore()
        let launcher = launcher(context, drafts)
        let (model, bench) = try benchWorkout(launcher, sets: 2)
        setType(model, .warmup, row: 1, of: bench)
        launcher.workoutScreenClosed(model)
        let candidate = try #require(launcher.candidates.first)
        launcher.resume(candidate)
        let reopened = try #require(launcher.presented)
        #expect(reopened !== model)
        #expect(labels(reopened, bench) == ["1", "W"])
        #expect(results(context).isEmpty)
    }

    // MARK: identity

    @Test func aStaleActionForARemovedRowNeverReachesTheRowThatMovedUp() throws {
        let context = try makeContext()
        let (model, bench) = try benchWorkout(launcher(context), sets: 3)
        // Done B (between A and C), open C.
        model.complete(rows(model, bench)[0].key)
        model.setWeight(70, for: rows(model, bench)[1].key)
        model.complete(rows(model, bench)[1].key)
        model.setRepsInReserve(1, for: rows(model, bench)[1].key)
        let doneB = rows(model, bench)[1]
        model.setWeight(90, for: rows(model, bench)[2].key)
        let openC = rows(model, bench)[2]
        model.removeSet(doneB.key)
        model.setSetType(.warmup, for: doneB.identity, at: doneB.key)   // stale: C is at B's key now
        #expect(rows(model, bench)[1].identity == openC.identity)
        #expect(rows(model, bench)[1].setType == .working && rows(model, bench)[1].weightKg == 90)
        #expect(results(context).allSatisfy { $0.setType == .working })

        // Open row: remove it, then act for it.
        model.addSet(to: bench)
        let openD = rows(model, bench)[2]
        model.removeSet(rows(model, bench)[1].key)                      // C goes, D moves up
        model.setSetType(.warmup, for: openC.identity, at: openC.key)
        #expect(rows(model, bench)[1].identity == openD.identity)
        #expect(rows(model, bench)[1].setType == .working)
        #expect(rows(model, bench)[0].setType == .working)
    }

    @Test func aRowAddedWhereARemovedOneWasIsNewAndWorking() throws {
        let context = try makeContext()
        let (model, bench) = try benchWorkout(launcher(context), sets: 2)
        let b = rows(model, bench)[1]
        setType(model, .warmup, row: 1, of: bench)
        model.setWeight(20, for: b.key)
        model.removeSet(b.key)
        model.addSet(to: bench)
        let d = rows(model, bench)[1]
        #expect(d.key == b.key && d.identity != b.identity)
        #expect(d.setType == .working && d.weightKg != 20)
        model.setSetType(.warmup, for: b.identity, at: b.key)
        #expect(rows(model, bench)[1].setType == .working)
    }

    @Test func aRemovedExerciseAndAnotherWorkoutTakeNoStaleAction() throws {
        let context = try makeContext()
        let drafts = FreeWorkoutDraftStore()
        let launcher = launcher(context, drafts)
        let (model, bench) = try benchWorkout(launcher, sets: 1)
        let row = rows(model, bench)[0]
        model.removeExercise(bench)
        model.addExercise(exerciseId: "bench_press", title: "ベンチプレス")
        let next = try #require(model.cards.first)
        model.setSetType(.warmup, for: row.identity, at: row.key)
        model.setSetType(.warmup, for: row.identity, at: next.rows[0].key)
        #expect(next.rows[0].setType == .working && rows(model, next.id)[0].setType == .working)

        // The same action against another workout's screen.
        model.finish()
        launcher.workoutScreenClosed(model)
        let (other, otherBench) = try benchWorkout(launcher, sets: 1)
        other.setSetType(.warmup, for: row.identity, at: Key(stepId: otherBench, setIndex: 0))
        #expect(rows(other, otherBench)[0].setType == .working)
    }

    /// RED on the pre-fix code: a closed screen kept writing into the drafts
    /// the resumed screen of the same workout reads.
    @Test func aClosedScreenOfTheSameWorkoutWritesNothingAfterResume() throws {
        let context = try makeContext()
        let drafts = FreeWorkoutDraftStore()
        let launcher = launcher(context, drafts)
        let (old, bench) = try benchWorkout(launcher, sets: 2)
        let row = rows(old, bench)[1]
        launcher.workoutScreenClosed(old)
        launcher.resume(try #require(launcher.candidates.first))
        let reopened = try #require(launcher.presented)
        let before = drafts.drafts(for: reopened.id)

        old.setWeight(99, for: row.key)
        old.setReps(30, for: row.key)
        old.complete(rows(old, bench)[0].key)
        old.setSetType(.warmup, for: row.identity, at: row.key)
        #expect(drafts.drafts(for: reopened.id) == before)
        #expect(results(context).isEmpty)
        reopened.addSet(to: bench)                                       // rebuild from the store
        #expect(rows(reopened, bench)[1].weightKg != 99 && rows(reopened, bench)[1].reps != 30)
        #expect(rows(reopened, bench).allSatisfy { $0.setType == .working })
        // The new screen works.
        setType(reopened, .warmup, row: 1, of: bench)
        #expect(labels(reopened, bench) == ["1", "W", "2"])
    }

    @Test func aScopeChangeRefusesKindChangesEvenBackOnTheSameAccount() throws {
        let context = try makeContext()
        let a = UUID(), b = UUID()
        let resolver = WorkoutDataScopeResolver(fixed: .account(a))
        let launcher = launcher(context, scope: resolver.scope, authority: resolver.authority)
        let (model, bench) = try benchWorkout(launcher, sets: 2)
        model.complete(rows(model, bench)[0].key)
        let done = rows(model, bench)[0], open = rows(model, bench)[1]
        let draftsBefore = rows(model, bench)
        for scope in [WorkoutDataScope.account(b), .guest, .undetermined, .account(a)] {
            resolver.authority.update(scope)
            model.setSetType(.warmup, for: done.identity, at: done.key)
            model.setSetType(.warmup, for: open.identity, at: open.key)
        }
        #expect(results(context).allSatisfy { $0.setType == .working })
        #expect(rows(model, bench) == draftsBefore)
        // guest → account: a guest workout's actions die too.
        let guestResolver = WorkoutDataScopeResolver(fixed: .guest)
        let guestLauncher = self.launcher(try makeContext(), scope: .guest, authority: guestResolver.authority)
        let (guest, gBench) = try benchWorkout(guestLauncher, sets: 1)
        let gRow = rows(guest, gBench)[0]
        guestResolver.authority.update(.account(a))
        guest.setSetType(.warmup, for: gRow.identity, at: gRow.key)
        #expect(rows(guest, gBench)[0].setType == .working)
    }

    // MARK: prefill

    /// RED on the pre-fix code: a working row took the warm-up above it, and
    /// the previous working sets were matched by physical position.
    @Test func workingRowsPrefillByWorkingPositionAndWarmupsGetNoWorkingValues() throws {
        let context = try makeContext()
        pastBench(context, [(80, 10), (80, 8), (77.5, 10)])
        let (model, bench) = try benchWorkout(launcher(context), sets: 2)
        let step = try #require(model.session.steps.first)
        model.session.completeSet(at: 0, of: step, reps: 15, weightKg: 20, setType: .warmup)
        model.session.completeSet(at: 1, of: step, reps: 10, weightKg: 40, setType: .warmup)
        for _ in 0..<4 { model.addSet(to: bench) }
        let values = rows(model, bench).map { ($0.weightKg, $0.reps) }
        #expect(values[2] == (80, 10))
        #expect(values[3] == (80, 8))
        #expect(values[4] == (77.5, 10))
        #expect(values[5] == (77.5, 10))                                // past the end: the last one
    }

    @Test func openWarmupRowsShowNoWorkingDefaultsAndManualValuesStay() throws {
        let context = try makeContext()
        pastBench(context, [(80, 10), (80, 8), (77.5, 10)])
        let (model, bench) = try benchWorkout(launcher(context), sets: 4)
        // Working-only: the old physical rule.
        #expect(rows(model, bench).map(\.weightKg) == [80, 80, 77.5, 77.5])
        // Untouched → warm-up: working defaults removed.
        setType(model, .warmup, row: 0, of: bench)
        #expect(rows(model, bench)[0].weightKg == nil && rows(model, bench)[0].reps == FreeWorkoutSession.defaultRepsTarget)
        // Later working rows follow their new working position.
        #expect(rows(model, bench)[1...3].map(\.weightKg) == [80, 80, 77.5])
        #expect(rows(model, bench)[1...3].map(\.reps) == [10, 8, 10])
        // Manual values stay through kind changes; only the untouched field follows.
        let second = rows(model, bench)[1].key
        model.setWeight(80, for: second)                                 // typed, equal to the default
        setType(model, .warmup, row: 1, of: bench)
        #expect(rows(model, bench)[1].weightKg == 80)                    // manual weight kept
        #expect(rows(model, bench)[1].reps == FreeWorkoutSession.defaultRepsTarget) // auto reps left with the kind
        setType(model, .working, row: 1, of: bench)
        #expect(rows(model, bench)[1].weightKg == 80 && rows(model, bench)[1].reps == 10)
        let third = rows(model, bench)[2].key
        model.setWeight(20, for: third)
        model.setReps(15, for: third)
        setType(model, .warmup, row: 2, of: bench)
        #expect(rows(model, bench)[2].weightKg == 20 && rows(model, bench)[2].reps == 15)
        setType(model, .working, row: 2, of: bench)
        #expect(rows(model, bench)[2].weightKg == 20 && rows(model, bench)[2].reps == 15)
        // Warm-up → working on an untouched row takes its working default.
        setType(model, .working, row: 0, of: bench)
        #expect(rows(model, bench)[0].weightKg == 80 && rows(model, bench)[0].reps == 10)
        // Removing a row above moves the working position of untouched rows.
        setType(model, .warmup, row: 0, of: bench)
        model.removeSet(rows(model, bench)[0].key)
        #expect(rows(model, bench)[0].weightKg == 80)                    // manual (row 1 before)
        #expect(rows(model, bench)[2].weightKg == 77.5)
    }

    @Test func doneSetsNeverChangeWhenRowsAboveChangeKind() throws {
        let context = try makeContext()
        pastBench(context, [(80, 10), (60, 8)])
        let (model, bench) = try benchWorkout(launcher(context), sets: 2)
        model.complete(rows(model, bench)[1].key)
        model.setRepsInReserve(3, for: rows(model, bench)[1].key)
        let done = try #require(results(context).first { $0.sessionId == model.id })
        setType(model, .warmup, row: 0, of: bench)
        #expect(done.weightKg == 60 && done.actualReps == 8 && done.repsInReserve == 3 && done.setType == .working)
        #expect(rows(model, bench)[1].label == .working(1))
    }

    @Test func noPreviousMeansNoInventedWeightAndNewRowsAreWorking() throws {
        let context = try makeContext()
        let (model, bench) = try benchWorkout(launcher(context), sets: 2)
        setType(model, .warmup, row: 1, of: bench)
        model.addSet(to: bench)
        #expect(rows(model, bench).map(\.weightKg) == [nil, nil, nil])
        #expect(rows(model, bench)[2].setType == .working)              // not inherited from the warm-up above
    }

    // MARK: compatibility

    @Test func timedRowsHaveNoKindAndNumberAsBefore() throws {
        let context = try makeContext()
        let launcher = launcher(context)
        launcher.start()
        let model = try #require(launcher.presented)
        model.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミル")
        let tread = try #require(model.cards.first?.id)
        model.addSet(to: tread)
        let row = rows(model, tread)[0]
        #expect(!model.acceptsSetType(row.key))
        model.setSetType(.warmup, for: row.identity, at: row.key)
        #expect(labels(model, tread) == ["1", "2"])
        model.setDuration(DurationEntry(totalSeconds: 600), for: row.key)
        model.complete(row.key)
        let stored = try #require(results(context).first)
        #expect(stored.actualDurationSeconds == 600 && stored.setTypeRaw == nil && stored.actualReps == nil)
    }

    @Test func bodyweightAndAssistedKeepTheirLoadSemantics() throws {
        for id in ["pull_up_bar", "assisted_pull_up"] {
            let context = try makeContext()
            let launcher = launcher(context)
            launcher.start()
            let model = try #require(launcher.presented)
            model.addExercise(exerciseId: id, title: id)
            let card = try #require(model.cards.first)
            let key = card.rows[0].key
            #expect(model.acceptsSetType(key))
            setType(model, .warmup, row: 0, of: card.id)
            model.setWeight(10, for: key)
            model.complete(key)
            let stored = try #require(results(context).first)
            #expect(stored.setType == .warmup && stored.weightKg == 10)
        }
    }

    // MARK: actual complete / skip / finish integration

    @Test func aRealWorkoutWithAWorkingSkipNeverEarnsAnIncrease() throws {
        let context = try makeContext()
        let launcher = launcher(context)
        let (model, bench) = try benchWorkout(launcher, sets: 6)
        setType(model, .warmup, row: 0, of: bench)
        setType(model, .warmup, row: 1, of: bench)
        func log(_ i: Int, _ kg: Double, _ reps: Int) {
            let key = rows(model, bench)[i].key
            model.setWeight(kg, for: key); model.setReps(reps, for: key); model.complete(key)
        }
        log(0, 20, 15)
        model.skip(rows(model, bench)[1].key)                             // warm-up skip
        log(2, 80, 10)
        log(3, 80, 10)
        model.skip(rows(model, bench)[4].key)                             // working skip
        // row 5: untouched, never logged
        model.finish()
        #expect(model.finishOutcome == .saved)
        let stored = results(context)
        #expect(stored.map(\.setType) == [.warmup, .warmup, .working, .working, .working])
        #expect(stored.map(\.done) == [true, false, true, true, false])
        #expect(stored.allSatisfy { $0.plannedSetsAtExecution == 5 })     // trimmed to the logged rows

        let step = try #require(model.session.steps.first)
        let previous = try #require(PreviousPerformanceQuery.latest(
            exerciseId: "bench_press", excludingSessionId: nil, expectedSets: 3,
            steps: [step], sessions: [model.session.session], results: stored))
        #expect(previous.plannedSetCount == 3 && previous.sets.count == 2)
        let suggestion = ProgressionRule.suggest(previous: previous, baselineReps: 10, expectedSets: 3,
                                                 allowsRepProgression: true, allowsWeightProgression: true)
        #expect(suggestion?.kind == .holdWeight && suggestion?.suggestedWeightKg == 80)
        let insight = WorkoutProgressQuery.exerciseInsights(steps: [step], sessions: [model.session.session], results: stored).first
        #expect(insight?.latestReps == [10, 10] && insight?.personalBestReps == 10)
        let summary = try #require(model.completion)
        #expect(summary.completedSetCount == 3 && summary.totalReps == 35 && summary.totalVolumeKg == 1_900)
    }

    @Test func aRealWorkoutWithAllWorkingSetsDoneMatchesAWorkingOnlyOne() throws {
        let context = try makeContext()
        let (model, bench) = try benchWorkout(launcher(context), sets: 7)
        for i in 0..<3 { setType(model, .warmup, row: i, of: bench) }
        func log(_ i: Int, _ kg: Double, _ reps: Int) {
            let key = rows(model, bench)[i].key
            model.setWeight(kg, for: key); model.setReps(reps, for: key); model.complete(key)
        }
        log(0, 20, 15); log(1, 40, 10)
        model.skip(rows(model, bench)[2].key)
        log(3, 80, 10); log(4, 80, 10); log(5, 80, 10)
        model.finish()
        let stored = results(context)
        #expect(stored.count == 6 && stored.allSatisfy { $0.plannedSetsAtExecution == 6 })
        let step = try #require(model.session.steps.first)
        let previous = try #require(PreviousPerformanceQuery.latest(
            exerciseId: "bench_press", excludingSessionId: nil, expectedSets: 3,
            steps: [step], sessions: [model.session.session], results: stored))
        #expect(previous.plannedSetCount == 3 && previous.sets.count == 3 && previous.uniformWeightKg == 80)
        let mixed = ProgressionRule.suggest(previous: previous, baselineReps: 10, expectedSets: 3,
                                            allowsRepProgression: true, allowsWeightProgression: true)
        let workingOnly = ProgressionRule.suggest(previous: PreviousPerformance(date: previous.date, setReps: [10, 10, 10],
                                                                                setWeightsKg: [80, 80, 80], plannedSetCount: 3),
                                                  baselineReps: 10, expectedSets: 3,
                                                  allowsRepProgression: true, allowsWeightProgression: true)
        #expect(mixed == workingOnly && mixed?.suggestedWeightKg == 82.5)
        let summary = try #require(model.completion)
        #expect(summary.completedSetCount == 5 && summary.totalReps == 55 && summary.totalVolumeKg == 3_100)
    }
}

// MARK: - Free Workout rest timer (Rest Timer PR-1)

@MainActor
private final class RestNotificationSpy: RunnerNotificationManaging {
    var status: UNAuthorizationStatus = .authorized
    var holdAuthorization = false
    var heldAuthorization: [(UNAuthorizationStatus) -> Void] = []
    var holdScheduleCompletion = false
    var heldScheduleCompletions: [() -> Void] = []
    private(set) var pending: [String: Date] = [:]
    private(set) var scheduleCount = 0
    private(set) var removed: [String] = []

    func getAuthorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        if holdAuthorization { heldAuthorization.append(completion) } else { completion(status) }
    }
    func scheduleRestNotification(deadline: Date, identifier: String, completion: @escaping () -> Void) {
        pending[identifier] = deadline
        scheduleCount += 1
        if holdScheduleCompletion { heldScheduleCompletions.append(completion) } else { completion() }
    }
    func removeNotification(identifier: String) {
        pending[identifier] = nil
        removed.append(identifier)
    }
}

/// The rest store's expiry arming, held so a test fires it when it wants.
@MainActor
private final class RestExpiryQueue {
    var armed: [(delay: TimeInterval, fire: @MainActor () -> Void)] = []
    /// The app's lifecycle as the store hears it: switching posts the same
    /// notifications UIKit does, at the test clock's current time.
    let lifecycle = NotificationCenter()
    var appActive = true {
        didSet {
            guard appActive != oldValue else { return }
            lifecycle.post(name: appActive ? UIApplication.didBecomeActiveNotification : UIApplication.willResignActiveNotification, object: nil)
        }
    }
    private(set) var feedbackCount = 0
    func schedule(_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) { armed.append((delay, fire)) }
    func feedback() { feedbackCount += 1 }
    /// Fires everything armed so far, oldest first.
    func fireAll() {
        let pending = armed
        armed = []
        for entry in pending { entry.fire() }
    }
}

@MainActor
private final class RestClock {
    var now = Date(timeIntervalSince1970: 2_000_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// Lets the store's `Task { @MainActor }` hops run.
@MainActor
private func settle() async {
    for _ in 0..<10 { await Task.yield() }
}

struct RestCountdownTests {
    private let t0 = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func countsDownFromTheDeadlineAndNeverBelowZero() throws {
        let c = try #require(RestCountdown(seconds: 120, now: t0))
        #expect(c.remainingSeconds(now: t0) == 120)
        #expect(c.remainingSeconds(now: t0.addingTimeInterval(0.4)) == 120)   // rounds up
        #expect(c.remainingSeconds(now: t0.addingTimeInterval(119.5)) == 1)
        #expect(!c.isExpired(now: t0.addingTimeInterval(119.5)))
        #expect(c.isExpired(now: t0.addingTimeInterval(120)))
        #expect(c.remaining(now: t0.addingTimeInterval(86_400 * 365)) == 0)   // a long time later
        #expect(c.remaining(now: t0.addingTimeInterval(-30)) == 150)          // before start: still bounded by the deadline
    }

    @Test func adjustingMovesOnlyTheDeadlineAndNeverRevivesAFinishedRest() throws {
        let c = try #require(RestCountdown(seconds: 120, now: t0))
        let later = t0.addingTimeInterval(30)
        let plus = c.adjusted(by: 15, now: later)
        #expect(plus.remainingSeconds(now: later) == 105)
        #expect(plus.initialDuration == 120 && plus.startedAt == t0)
        let minus = plus.adjusted(by: -15, now: later)
        #expect(minus.remainingSeconds(now: later) == 90)
        let nearEnd = t0.addingTimeInterval(110)
        #expect(c.adjusted(by: -15, now: nearEnd).isExpired(now: nearEnd))    // below 15 s: to 0
        let over = t0.addingTimeInterval(200)
        #expect(c.adjusted(by: 15, now: over).isExpired(now: over))           // a late +15 does nothing
        let capped = c.adjusted(by: 10_000, now: t0)
        #expect(capped.remaining(now: t0) == RestCountdown.maximumSeconds)
    }

    @Test func fractionStaysWithinZeroAndOneThroughAdjustments() throws {
        let c = try #require(RestCountdown(seconds: 120, now: t0))
        #expect(c.fractionRemaining(now: t0) == 1)
        #expect(c.fractionRemaining(now: t0.addingTimeInterval(60)) == 0.5)
        #expect(c.fractionRemaining(now: t0.addingTimeInterval(500)) == 0)
        let plus = c.adjusted(by: 15, now: t0)                                // +15 at the very start
        #expect(plus.fractionRemaining(now: t0) == 1)
        let mid = t0.addingTimeInterval(60)
        let extended = c.adjusted(by: 15, now: mid)                            // 75 left of 135
        #expect(abs(extended.fractionRemaining(now: mid) - 75.0 / 135.0) < 1e-9)
        #expect(c.fractionRemaining(now: t0.addingTimeInterval(-10)) == 1)
    }

    @Test func invalidDurationsStartNothing() {
        #expect(RestCountdown(seconds: 0, now: t0) == nil)
        #expect(RestCountdown(seconds: -30, now: t0) == nil)
        #expect(RestCountdown(seconds: .max, now: t0)?.initialDuration == RestCountdown.maximumSeconds)
    }
}

@MainActor
struct FreeWorkoutRestTimerTests {
    private typealias Key = FreeWorkoutViewModel.RowKey

    private struct Fixture {
        let context: ModelContext
        let clock: RestClock
        let spy: RestNotificationSpy
        let store: RestTimerStore
        let drafts: FreeWorkoutDraftStore
        let launcher: FreeWorkoutLauncher
        let resolver: WorkoutDataScopeResolver?
        let expiry: RestExpiryQueue
    }

    private func fixture(scope: WorkoutDataScope = .guest, withAuthority: Bool = false, enabled: Bool = true) throws -> Fixture {
        let schema = Schema([Routine.self, Step.self, Session.self, StepResult.self, DayLog.self])
        let context = ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]))
        let clock = RestClock(), spy = RestNotificationSpy(), drafts = FreeWorkoutDraftStore(), expiry = RestExpiryQueue()
        let store = RestTimerStore(notifications: spy, notificationsEnabled: { enabled }, now: { clock.now },
                                   lifecycle: expiry.lifecycle, initiallyActive: true, expiryFeedback: { expiry.feedback() },
                                   scheduleExpiry: { expiry.schedule($0, $1) })
        let launcher = FreeWorkoutLauncher(drafts: drafts, restTimers: store)
        let resolver = withAuthority ? WorkoutDataScopeResolver(fixed: scope) : nil
        // As the app does it (ContentView): the store follows the authority.
        if let resolver { store.observe(resolver.authority) }
        launcher.configure(context: context, scope: scope, authority: resolver?.authority)
        return Fixture(context: context, clock: clock, spy: spy, store: store, drafts: drafts, launcher: launcher, resolver: resolver, expiry: expiry)
    }

    private func bench(_ fx: Fixture, sets: Int = 3, exerciseId: String = "bench_press") throws -> (FreeWorkoutViewModel, UUID) {
        if fx.launcher.presented == nil { fx.launcher.start() }
        let model = try #require(fx.launcher.presented)
        model.addExercise(exerciseId: exerciseId, title: exerciseId)
        let stepId = try #require(model.cards.last?.id)
        for _ in 1..<sets { model.addSet(to: stepId) }
        return (model, stepId)
    }

    private func key(_ model: FreeWorkoutViewModel, _ stepId: UUID, _ index: Int) -> Key {
        model.cards.first { $0.id == stepId }!.rows[index].key
    }

    private var identifierPrefix: String { "freeWorkoutRest." }

    // MARK: auto-start

    @Test func aFirstCompletionStartsARestAtTheStepsRest() async throws {
        let fx = try fixture()
        let (model, b) = try bench(fx)
        let step = try #require(model.session.steps.first)
        #expect(step.restSeconds == FreeWorkoutSession.defaultRestSeconds && step.restSeconds == 120)
        #expect(model.activeRest == nil)
        model.complete(key(model, b, 0))
        let rest = try #require(model.activeRest)
        #expect(rest.sessionId == model.id && rest.countdown.remainingSeconds(now: fx.clock.now) == 120)
        await settle()
        #expect(fx.spy.pending[RestTimerStore.notificationIdentifier(for: model.id)] == rest.countdown.deadline)
        #expect(RestTimerStore.notificationIdentifier(for: model.id).hasPrefix(identifierPrefix))
    }

    @Test func warmupSkippedThenDoneAndTimedCompletionsStartARest() throws {
        let fx = try fixture()
        let (model, b) = try bench(fx)
        let warm = model.cards[0].rows[0]
        model.setSetType(.warmup, for: warm.identity, at: warm.key)
        model.complete(warm.key)
        let first = try #require(model.activeRest?.token)
        model.skip(key(model, b, 1))
        #expect(model.activeRest?.token == first)                        // skip starts nothing
        model.complete(key(model, b, 1))                                  // skipped → done
        let second = try #require(model.activeRest?.token)
        #expect(second != first)
        model.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミル")
        let tread = try #require(model.cards.last)
        model.complete(tread.rows[0].key)                                 // no duration: refused
        #expect(model.activeRest?.token == second)
        model.setDuration(DurationEntry(totalSeconds: 300), for: tread.rows[0].key)
        model.complete(tread.rows[0].key)
        #expect(model.activeRest?.token != second)
    }

    @Test func editsOfALoggedSetAndOtherActionsNeverStartOrRestartARest() async throws {
        let fx = try fixture()
        let (model, b) = try bench(fx)
        let k0 = key(model, b, 0)
        model.complete(k0)
        let rest = try #require(model.activeRest)
        await settle()
        let schedules = fx.spy.scheduleCount
        model.complete(k0)                                                // duplicate tap on a done set
        model.setWeight(82.5, for: k0)                                    // re-record
        model.setReps(8, for: k0)
        model.setRepsInReserve(2, for: k0)
        let done = model.cards[0].rows[0]
        model.setSetType(.warmup, for: done.identity, at: done.key)
        model.setWeight(60, for: key(model, b, 1))                        // open row edit
        model.addSet(to: b)
        model.removeSet(key(model, b, 3))
        await settle()
        #expect(model.activeRest == rest)
        #expect(fx.spy.scheduleCount == schedules)
    }

    @Test func aZeroRestStepAndARefusedCompletionStartNothing() throws {
        let fx = try fixture()
        let (model, b) = try bench(fx)
        try #require(model.session.steps.first).restSeconds = 0
        model.complete(key(model, b, 0))
        #expect(model.activeRest == nil && fx.store.rest == nil)
        // A revoked session's complete is refused by the domain: no rest.
        let k1 = key(model, b, 1)
        model.session.revoke()
        model.complete(k1)
        #expect(fx.store.rest == nil)
    }

    // MARK: PR-2

    @Test func aZeroRestCompletionEndsTheRunningRestAndItsNotification() async throws {
        let fx = try fixture()
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        let running = try #require(model.activeRest)
        await settle()
        let id = RestTimerStore.notificationIdentifier(for: model.id)
        #expect(fx.spy.pending[id] != nil)
        model.setRestSeconds(0, for: b)
        #expect(model.activeRest == running)                              // a setting never touches the running rest
        model.complete(key(model, b, 1))                                  // a real completion with no rest
        await settle()
        #expect(model.activeRest == nil && fx.store.rest == nil)
        #expect(fx.spy.pending[id] == nil)
        #expect(!fx.store.adjust(by: 15, sessionId: model.id, token: running.token))
        // Re-recording a done set is not a completion: nothing ends.
        model.setRestSeconds(120, for: b)
        model.complete(key(model, b, 2))
        let next = try #require(model.activeRest)
        model.setRestSeconds(0, for: b)
        model.complete(key(model, b, 1))                                  // already done
        #expect(model.activeRest == next)
    }

    @Test func aRefusedZeroRestCompletionLeavesTheRestAlone() throws {
        let fx = try fixture()
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        let running = try #require(fx.store.rest)
        model.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミル")
        let tread = try #require(model.cards.last)
        model.setRestSeconds(0, for: tread.id)
        model.complete(tread.rows[0].key)                                 // no duration: refused by the domain
        #expect(fx.store.rest == running)
    }

    @Test func theExercisesRestSettingIsForTheNextRestsOnly() throws {
        let fx = try fixture()
        let (model, b) = try bench(fx)
        #expect(model.cards[0].restSeconds == 120)
        model.complete(key(model, b, 0))
        let running = try #require(model.activeRest)
        model.setRestSeconds(60, for: b)
        #expect(model.cards[0].restSeconds == 60)
        #expect(model.activeRest == running)
        #expect(running.countdown.remainingSeconds(now: fx.clock.now) == 120)
        model.complete(key(model, b, 1))
        #expect(model.activeRest?.countdown.remainingSeconds(now: fx.clock.now) == 60)
        // Only the presets; anything else is refused and changes nothing.
        model.setRestSeconds(45, for: b)
        model.setRestSeconds(-1, for: b)
        model.setRestSeconds(900, for: b)
        #expect(model.cards[0].restSeconds == 60)
        for preset in [0, 60, 90, 120, 180] {
            model.setRestSeconds(preset, for: b)
            #expect(model.cards[0].restSeconds == preset)
        }
        // ±15 changes the rest, never the setting.
        model.setRestSeconds(90, for: b)
        model.complete(key(model, b, 2))
        let rest = try #require(model.activeRest)
        model.adjustRest(by: 15, token: rest.token)
        #expect(model.cards[0].restSeconds == 90)
        #expect(model.session.steps.first?.restSeconds == 90)
        // A revoked screen cannot change it.
        model.session.revoke()
        model.setRestSeconds(180, for: b)
        #expect(model.session.steps.first?.restSeconds == 90)
    }

    @Test func aRestEndsAtItsDeadlineAndSoundsOnlyInTheForegroundOnTime() async throws {
        let fx = try fixture()
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        await settle()
        let id = RestTimerStore.notificationIdentifier(for: model.id)
        #expect(fx.expiry.armed.last?.delay == 120)
        fx.clock.advance(120)
        fx.expiry.fireAll()
        #expect(fx.store.rest == nil)                                     // the entry, not only the bar
        #expect(fx.expiry.feedbackCount == 1)
        #expect(fx.spy.pending[id] != nil)                                // left for the system to deliver
        // In the background the notification speaks; the app stays silent.
        model.complete(key(model, b, 1))
        fx.expiry.appActive = false
        fx.clock.advance(120)
        fx.expiry.fireAll()
        #expect(fx.store.rest == nil && fx.expiry.feedbackCount == 1)
        // Back minutes after a rest ran out: ended, but no late beep.
        fx.expiry.appActive = true
        model.complete(key(model, b, 2))
        fx.clock.advance(400)
        fx.expiry.fireAll()
        #expect(fx.store.rest == nil && fx.expiry.feedbackCount == 1)
    }

    @Test func anOlderArmingNeverEndsANewerOrAdjustedRest() throws {
        let fx = try fixture()
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        let first = try #require(model.activeRest)
        model.adjustRest(by: 15, token: first.token)                      // re-arms for 135
        fx.clock.advance(120)
        let stale = fx.expiry.armed.removeFirst()                         // armed for the old deadline
        stale.fire()
        #expect(model.activeRest?.token == first.token)
        #expect(fx.expiry.feedbackCount == 0)
        model.complete(key(model, b, 1))                                  // a new rest
        let second = try #require(model.activeRest)
        fx.clock.advance(15)
        fx.expiry.armed.removeFirst().fire()                              // the adjusted first rest's
        #expect(model.activeRest == second && fx.expiry.feedbackCount == 0)
        // Fired early (a clock that moved back): it waits again.
        fx.expiry.armed.removeFirst().fire()
        #expect(model.activeRest == second && fx.expiry.armed.count == 1)
        // +15 after the end never revives it.
        fx.clock.advance(120)
        fx.expiry.fireAll()
        #expect(fx.store.rest == nil)
        #expect(!fx.store.adjust(by: 15, sessionId: model.id, token: second.token))
    }

    // MARK: PR-2 fix — natural expiry and feedback

    @Test func aNaturalExpiryLeavesTheNotificationForTheSystemToDeliver() async throws {
        let fx = try fixture()
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        await settle()
        let id = RestTimerStore.notificationIdentifier(for: model.id)
        let deadline = try #require(fx.spy.pending[id])
        fx.clock.advance(120)
        fx.expiry.fireAll()
        await settle()
        #expect(fx.store.rest == nil)
        #expect(fx.spy.pending[id] == deadline)                           // not taken back
    }

    @Test func aManualEndStillCancelsTheNotification() async throws {
        let fx = try fixture()
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        let rest = try #require(model.activeRest)
        await settle()
        model.finishRest(token: rest.token)
        await settle()
        #expect(fx.spy.pending[RestTimerStore.notificationIdentifier(for: model.id)] == nil)
    }

    @Test func aBackgroundOrInactiveExpiryKeepsTheNotificationAndStaysSilent() async throws {
        for phase in ["background", "inactive"] {
            let fx = try fixture()
            let (model, b) = try bench(fx)
            model.complete(key(model, b, 0))
            await settle()
            let id = RestTimerStore.notificationIdentifier(for: model.id)
            fx.clock.advance(100)
            fx.expiry.appActive = false                                   // resigned before the deadline
            fx.clock.advance(20)
            fx.expiry.fireAll()
            await settle()
            #expect(fx.spy.pending[id] != nil, "\(phase)")
            #expect(fx.expiry.feedbackCount == 0, "\(phase)")
        }
    }

    @Test func aRestThatEndsInTheForegroundSoundsOnce() throws {
        let fx = try fixture()
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        fx.clock.advance(120)
        fx.expiry.fireAll()
        fx.expiry.fireAll()
        #expect(fx.expiry.feedbackCount == 1)
    }

    @Test func comingBackJustAfterABackgroundExpiryDoesNotSound() throws {
        let fx = try fixture()
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        fx.clock.advance(60)
        fx.expiry.appActive = false
        fx.clock.advance(60.5)                                            // the deadline passes in the background
        fx.expiry.appActive = true                                        // back within a second
        fx.expiry.fireAll()                                               // the suspended expiry runs now
        #expect(fx.store.rest == nil)
        #expect(fx.expiry.feedbackCount == 0)
    }

    @Test func inactiveAcrossTheDeadlineDoesNotSound() throws {
        let fx = try fixture()
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        fx.clock.advance(119)
        fx.expiry.appActive = false                                       // e.g. Control Center pulled down
        fx.clock.advance(1.5)
        fx.expiry.appActive = true
        fx.expiry.fireAll()
        #expect(fx.expiry.feedbackCount == 0)
    }

    @Test func comingBackBeforeTheDeadlineSoundsAtTheDeadline() throws {
        let fx = try fixture()
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        fx.expiry.appActive = false
        fx.clock.advance(60)
        fx.expiry.appActive = true                                        // back well before it ends
        fx.clock.advance(60)
        fx.expiry.fireAll()
        #expect(fx.expiry.feedbackCount == 1)
    }

    @Test func aLateScheduleAnswerAfterANaturalExpiryNeverTakesTheNotificationBack() async throws {
        let fx = try fixture()
        fx.spy.holdScheduleCompletion = true
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        await settle()
        let id = RestTimerStore.notificationIdentifier(for: model.id)
        #expect(fx.spy.pending[id] != nil)
        fx.clock.advance(120)
        fx.expiry.fireAll()                                               // natural end
        for completion in fx.spy.heldScheduleCompletions { completion() }
        fx.spy.heldScheduleCompletions = []
        await settle()
        #expect(fx.spy.pending[id] != nil)
    }

    @Test func aNewRestAfterANaturalExpiryOwnsItsNotificationAndOldArmingsAreInert() async throws {
        let fx = try fixture()
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        await settle()
        fx.clock.advance(120)
        let staleA = fx.expiry.armed
        fx.expiry.armed = []
        for entry in staleA { entry.fire() }                              // A ends naturally
        model.complete(key(model, b, 1))                                  // B in the same workout
        let restB = try #require(model.activeRest)
        await settle()
        let id = RestTimerStore.notificationIdentifier(for: model.id)
        #expect(fx.spy.pending[id] == restB.countdown.deadline)
        for entry in staleA { entry.fire() }                              // A's armings again
        await settle()
        #expect(model.activeRest == restB)
        #expect(fx.spy.pending[id] == restB.countdown.deadline)
        #expect(fx.expiry.feedbackCount == 1)                             // A's only
    }

    // MARK: PR-2 fix — scope observation and Home resume

    @Test func everyAuthorityChangeEndsTheRestEvenABToAInOneGo() async throws {
        let a = UUID(), other = UUID()
        let fx = try fixture(scope: .account(a), withAuthority: true)
        let authority = try #require(fx.resolver?.authority)
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        let rest = try #require(fx.store.rest)
        await settle()
        let id = RestTimerStore.notificationIdentifier(for: model.id)
        fx.launcher.workoutScreenClosed(model)
        authority.update(.account(a))                                     // the same scope: kept
        #expect(fx.store.rest == rest)
        // A → B → A with nothing in between: no view, no launcher, no revalidate.
        authority.update(.account(other))
        authority.update(.account(a))
        await settle()
        #expect(fx.store.rest == nil)
        #expect(fx.spy.pending[id] == nil)
        #expect(!fx.store.adjust(by: 15, sessionId: model.id, token: rest.token))
        fx.clock.advance(200)
        fx.expiry.fireAll()                                               // its expiry arming is inert
        #expect(fx.expiry.feedbackCount == 0 && fx.store.rest == nil)
    }

    @Test func aNotificationLeftByANaturalEndGoesWithTheScopeOrTheWorkout() async throws {
        let a = UUID()
        let fx = try fixture(scope: .account(a), withAuthority: true)
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        await settle()
        let id = RestTimerStore.notificationIdentifier(for: model.id)
        fx.clock.advance(120)
        fx.expiry.fireAll()
        #expect(fx.spy.pending[id] != nil)                                // left for the system
        fx.resolver?.authority.update(.guest)
        #expect(fx.spy.pending[id] == nil)                                // another scope: taken back

        let fx2 = try fixture()
        let (model2, b2) = try bench(fx2)
        model2.complete(key(model2, b2, 0))
        await settle()
        let id2 = RestTimerStore.notificationIdentifier(for: model2.id)
        fx2.clock.advance(120)
        fx2.expiry.fireAll()
        fx2.store.revalidate(scope: .guest)                               // same scope: left alone
        #expect(fx2.spy.pending[id2] != nil)
        model2.discard()                                                  // its workout ends: taken back
        #expect(fx2.spy.pending[id2] == nil)
    }

    @Test func homeResumesOnlyTheRestItShowed() async throws {
        let a = UUID()
        let fx = try fixture(scope: .account(a), withAuthority: true)
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        let shownA = try #require(fx.store.currentRest())
        fx.launcher.workoutScreenClosed(model)
        #expect(fx.launcher.presented == nil)
        #expect(fx.launcher.resumeRest(shownA))                           // the rest it showed: opens it
        let reopened = try #require(fx.launcher.presented)
        #expect(reopened.id == model.id)
        // Replaced by B: the pill drawn for A opens nothing.
        reopened.complete(key(reopened, b, 1))
        fx.launcher.workoutScreenClosed(reopened)
        #expect(!fx.launcher.resumeRest(shownA))
        #expect(fx.launcher.presented == nil)
        // Ended at its deadline: B's pill opens nothing either.
        let shownB = try #require(fx.store.currentRest())
        fx.clock.advance(121)
        #expect(!fx.launcher.resumeRest(shownB))
        // A → B → A: an old pill never opens anything.
        let reopened2 = try #require({ fx.launcher.resume(sessionId: model.id); return fx.launcher.presented }())
        reopened2.complete(key(reopened2, b, 2))
        let shownC = try #require(fx.store.currentRest())
        fx.launcher.workoutScreenClosed(reopened2)
        fx.resolver?.authority.update(.account(UUID()))
        fx.resolver?.authority.update(.account(a))
        fx.launcher.configure(context: fx.context, scope: .account(a), authority: fx.resolver?.authority)
        #expect(!fx.launcher.resumeRest(shownC))
        #expect(fx.launcher.presented == nil)
    }

    @Test func homeDoesNotResumeADiscardedWorkoutsRest() throws {
        let fx = try fixture()
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        let shown = try #require(fx.store.currentRest())
        model.discard()
        fx.launcher.workoutScreenClosed(model)
        #expect(fx.store.rest == nil)
        #expect(!fx.launcher.resumeRest(shown))
        #expect(fx.launcher.presented == nil)
    }

    @Test func homeSeesAnyWorkoutsRestButOnlyWhileItIsTheScopes() throws {
        let owner = UUID()
        let fx = try fixture(scope: .account(owner), withAuthority: true)
        let (model, b) = try bench(fx)
        #expect(fx.store.currentRest() == nil)
        model.complete(key(model, b, 0))
        let rest = try #require(fx.store.currentRest())
        #expect(rest.sessionId == model.id && rest.exerciseTitle == "bench_press")
        #expect(fx.store.activeRest(for: UUID()) == nil)                  // another workout's screen shows nothing
        fx.resolver?.authority.update(.account(UUID()))                         // the scope changes, nobody calls anything yet
        #expect(fx.store.currentRest() == nil)
    }

    @Test func aScopeChangeEndsTheRestWithNoWorkoutScreenAtAll() async throws {
        // The app-level observer's call (ContentView → `revalidate`), with no
        // launcher configured again and the workout screen closed.
        let a = UUID(), b2 = UUID()
        let fx = try fixture(scope: .account(a), withAuthority: true)
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        let rest = try #require(fx.store.rest)
        await settle()
        fx.launcher.workoutScreenClosed(model)
        #expect(fx.store.rest == rest)                                    // a close keeps it
        fx.store.revalidate(scope: .account(a))                           // the same scope again keeps it
        #expect(fx.store.rest == rest)
        let id = RestTimerStore.notificationIdentifier(for: model.id)
        fx.resolver?.authority.update(.account(b2))
        fx.store.revalidate(scope: .account(b2))
        await settle()
        #expect(fx.store.rest == nil)
        #expect(fx.spy.pending[id] == nil)
        fx.resolver?.authority.update(.account(a))
        fx.store.revalidate(scope: .account(a))
        #expect(fx.store.currentRest() == nil)
        #expect(!fx.store.adjust(by: 15, sessionId: model.id, token: rest.token))
        #expect(!fx.store.finish(sessionId: model.id, token: rest.token))
    }

    @Test func theRestSummaryKeepsThisRestApartFromTheSetting() throws {
        let t0 = Date(timeIntervalSince1970: 2_000_000_000)
        let c = try #require(RestCountdown(seconds: 120, now: t0))
        #expect(FreeWorkoutRestBar.restSummary(c) == "この休憩 02:00")
        #expect(FreeWorkoutRestBar.restSummary(c.adjusted(by: 15, now: t0.addingTimeInterval(60))).hasPrefix("この休憩 02:00（+"))
        #expect(FreeWorkoutRestBar.restSummary(c.adjusted(by: -15, now: t0.addingTimeInterval(10))).hasPrefix("この休憩 02:00（−"))
    }

    @Test func aNewCompletionReplacesTheRestAndItsNotification() async throws {
        let fx = try fixture()
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        let first = try #require(model.activeRest)
        await settle()
        fx.clock.advance(40)
        model.complete(key(model, b, 1))
        let second = try #require(model.activeRest)
        await settle()
        #expect(second.token != first.token)
        #expect(second.countdown.deadline == fx.clock.now.addingTimeInterval(120))
        #expect(fx.spy.pending[RestTimerStore.notificationIdentifier(for: model.id)] == second.countdown.deadline)
        #expect(!fx.store.adjust(by: 15, sessionId: model.id, token: first.token))
        #expect(!fx.store.finish(sessionId: model.id, token: first.token))
        #expect(model.activeRest == second)
    }

    // MARK: controls

    @Test func plusMinusAndFinishTouchOnlyTheCurrentRest() async throws {
        let fx = try fixture()
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        let token = try #require(model.activeRest?.token)
        let stepRest = try #require(model.session.steps.first).restSeconds
        fx.clock.advance(20)
        model.adjustRest(by: 15, token: token)
        #expect(model.activeRest?.countdown.remainingSeconds(now: fx.clock.now) == 115)
        model.adjustRest(by: -15, token: token)
        #expect(model.activeRest?.countdown.remainingSeconds(now: fx.clock.now) == 100)
        await settle()
        let id = RestTimerStore.notificationIdentifier(for: model.id)
        #expect(fx.spy.pending[id] == fx.clock.now.addingTimeInterval(100))
        #expect(try #require(model.session.steps.first).restSeconds == stepRest)   // not persisted
        // Another session's or a made-up token changes nothing.
        let before = fx.store.rest
        #expect(!fx.store.adjust(by: 15, sessionId: UUID(), token: token))
        model.adjustRest(by: 15, token: UUID())
        #expect(fx.store.rest == before)
        // −15 under 15 s ends it.
        fx.clock.advance(90)
        model.adjustRest(by: -15, token: token)
        #expect(model.activeRest == nil && fx.store.rest == nil)
        #expect(fx.spy.pending[id] == nil)
        // A finished rest takes no more actions.
        model.adjustRest(by: 15, token: token)
        model.finishRest(token: token)
        #expect(fx.store.rest == nil)
    }

    @Test func finishingEarlyCancelsTheNotification() async throws {
        let fx = try fixture()
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        await settle()
        let token = try #require(model.activeRest?.token)
        model.finishRest(token: token)
        #expect(model.activeRest == nil)
        #expect(fx.spy.pending.isEmpty)
    }

    @Test func aRestThatRanOutIsOverAndComesBackNeither() throws {
        let fx = try fixture()
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        let token = try #require(model.activeRest?.token)
        fx.clock.advance(121)                                             // e.g. while in the background
        #expect(model.activeRest == nil)
        model.adjustRest(by: 15, token: token)
        #expect(model.activeRest == nil)
        model.appDidBecomeActive()
        #expect(fx.store.rest == nil)
    }

    // MARK: lifecycle

    @Test func closeKeepsTheRestResumeShowsItAndTheOldScreenCannotTouchIt() throws {
        let fx = try fixture()
        let (old, b) = try bench(fx)
        old.complete(key(old, b, 0))
        let rest = try #require(old.activeRest)
        fx.launcher.workoutScreenClosed(old)
        #expect(fx.store.rest == rest)                                    // closing is not ending
        fx.launcher.resume(try #require(fx.launcher.candidates.first))
        let reopened = try #require(fx.launcher.presented)
        #expect(reopened.activeRest == rest)
        old.adjustRest(by: 15, token: rest.token)
        old.finishRest(token: rest.token)
        #expect(fx.store.rest == rest)
        fx.launcher.workoutScreenClosed(old)                              // a late close of the old screen
        #expect(fx.launcher.presented === reopened && fx.store.rest == rest)
        reopened.adjustRest(by: 15, token: rest.token)
        #expect(fx.store.rest?.countdown.remainingSeconds(now: fx.clock.now) == 135)
    }

    @Test func finishAndDiscardEndTheRestButAnOlderWorkoutsCleanupDoesNot() async throws {
        let fx = try fixture()
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        await settle()
        model.finish()
        #expect(model.finishOutcome == .saved && fx.store.rest == nil && fx.spy.pending.isEmpty)
        fx.launcher.workoutScreenClosed(model)

        let (second, b2) = try bench(fx)
        second.complete(key(second, b2, 0))
        let rest = try #require(second.activeRest)
        fx.store.endRest(of: model.id)                                    // the finished workout's late cleanup
        #expect(fx.store.rest == rest)
        second.discard()
        #expect(fx.store.rest == nil)
    }

    @Test func discardingFromTheCardEndsThatWorkoutsRest() throws {
        let fx = try fixture()
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        fx.launcher.workoutScreenClosed(model)
        fx.launcher.discard(try #require(fx.launcher.candidates.first))
        #expect(fx.store.rest == nil)
    }

    @Test func aScopeChangeEndsTheRestForGoodAndTheSameScopeKeepsIt() async throws {
        let a = UUID(), b = UUID()
        let changes: [(WorkoutDataScope, WorkoutDataScope)] = [
            (.account(a), .account(b)), (.account(a), .guest), (.guest, .account(b)),
            (.account(a), .undetermined), (.guest, .undetermined),
        ]
        for (from, to) in changes {
            let fx = try fixture(scope: from, withAuthority: true)
            let (model, s) = try bench(fx)
            model.complete(key(model, s, 0))
            let rest = try #require(model.activeRest)
            await settle()
            fx.launcher.configure(context: fx.context, scope: from, authority: fx.resolver?.authority)
            #expect(fx.store.rest == rest)                                // re-stating the scope keeps it
            fx.resolver?.authority.update(to)
            #expect(model.activeRest == nil)                              // hidden at once
            fx.launcher.configure(context: fx.context, scope: to, authority: fx.resolver?.authority)
            #expect(fx.store.rest == nil, "\(from) → \(to)")
            #expect(fx.spy.pending.isEmpty)
            #expect(!fx.store.adjust(by: 15, sessionId: model.id, token: rest.token))
        }
        // A → B → A: the old rest stays dead.
        let fx = try fixture(scope: .account(a), withAuthority: true)
        let (model, s) = try bench(fx)
        model.complete(key(model, s, 0))
        let rest = try #require(model.activeRest)
        fx.resolver?.authority.update(.account(b))
        fx.resolver?.authority.update(.account(a))
        #expect(fx.store.activeRest(for: model.id) == nil)
        #expect(!fx.store.adjust(by: 15, sessionId: model.id, token: rest.token))
        #expect(!fx.store.finish(sessionId: model.id, token: rest.token))
    }

    // MARK: notifications

    @Test func notificationsFollowSettingsAndPermissionWhileTheTimerRuns() async throws {
        let off = try fixture(enabled: false)
        let (m1, b1) = try bench(off)
        m1.complete(key(m1, b1, 0))
        await settle()
        #expect(m1.activeRest != nil && off.spy.pending.isEmpty)

        let denied = try fixture()
        denied.spy.status = .denied
        let (m2, b2) = try bench(denied)
        m2.complete(key(m2, b2, 0))
        await settle()
        #expect(m2.activeRest != nil && denied.spy.pending.isEmpty)
    }

    @Test func aLateAuthorizationAnswerNeverSchedulesForAnOlderRest() async throws {
        let fx = try fixture()
        fx.spy.holdAuthorization = true
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        let token = try #require(model.activeRest?.token)
        model.adjustRest(by: 15, token: token)
        model.adjustRest(by: 15, token: token)
        let deadline = try #require(model.activeRest?.countdown.deadline)
        for answer in fx.spy.heldAuthorization { answer(.authorized) }
        await settle()
        let id = RestTimerStore.notificationIdentifier(for: model.id)
        #expect(fx.spy.pending[id] == deadline)
        #expect(fx.spy.scheduleCount == 1)                                 // only the latest one

        // Finished before the answer comes back: nothing scheduled.
        fx.spy.heldAuthorization = []
        model.complete(key(model, b, 1))
        model.finishRest(token: try #require(model.activeRest?.token))
        for answer in fx.spy.heldAuthorization { answer(.authorized) }
        await settle()
        #expect(fx.spy.pending[id] == nil)
    }

    @Test func aScheduleThatCompletesAfterTheRestEndedIsTakenBack() async throws {
        let fx = try fixture()
        fx.spy.holdScheduleCompletion = true
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        await settle()
        let id = RestTimerStore.notificationIdentifier(for: model.id)
        #expect(fx.spy.pending[id] != nil)
        model.finishRest(token: try #require(model.activeRest?.token))
        // The add that raced with the cancel comes back late.
        for done in fx.spy.heldScheduleCompletions { done() }
        await settle()
        #expect(fx.spy.pending[id] == nil)
    }

    // MARK: performance isolation

    @Test func readingTheRestNeverPublishesSavesOrRebuildsRows() throws {
        let fx = try fixture()
        let (model, b) = try bench(fx)
        model.complete(key(model, b, 0))
        try fx.context.save()
        let cards = model.cards
        var publishes = 0
        let sink = fx.store.objectWillChange.sink { publishes += 1 }
        for _ in 0..<60 {
            fx.clock.advance(1)
            _ = model.activeRest?.countdown.remainingSeconds(now: fx.clock.now)
        }
        sink.cancel()
        #expect(publishes == 0)
        #expect(!fx.context.hasChanges)
        #expect(model.cards == cards)
    }
}
