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

import Foundation
import SwiftData
import Testing
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
        free.finish()

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
        free.finish()

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
        free.finish()

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
        free.finish()
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
        free.finish()
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
        launcher.workoutScreenClosed()
        #expect(launcher.presented == nil)
        let candidate = try #require(launcher.candidates.first)
        #expect(candidate.stepCount == 1)

        launcher.resume(candidate)
        #expect(launcher.presented?.cards.map(\.title) == ["ベンチプレス"])
        launcher.workoutScreenClosed()
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
        launcher.workoutScreenClosed()
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
            launcher.workoutScreenClosed()
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
                flow.launcher.workoutScreenClosed()
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
        flow.launcher.workoutScreenClosed()
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
        started.workoutScreenClosed()

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
        flow.launcher.workoutScreenClosed()
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
            flow.launcher.workoutScreenClosed()

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
        started.workoutScreenClosed()

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
        flow.launcher.workoutScreenClosed()

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
        model.complete(key(model, card: 0, set: 0))
        model.finish(now: model.startedAt.addingTimeInterval(600))
        #expect(try #require(model.completion).estimatedCalories == nil)
    }

    @Test func aTimedOnlyWorkoutStillGetsTheWorkoutLevelEstimate() throws {
        let context = ModelContext(try makeContainer())
        context.insert(DayLog(date: DateUtils.startOfDay(Date().addingTimeInterval(-86_400)), weightKg: 80))
        let model = try open(context)
        model.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミルウォームアップ")
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

    /// Logs one done treadmill set in a finished Free Workout; `legacyReps`
    /// stands in for an older record that still stored a rep count.
    private func logPastTreadmill(_ context: ModelContext, legacyReps: Int? = nil) throws {
        let past = try open(context)
        past.addExercise(exerciseId: "treadmill_warmup", title: "トレッドミルウォームアップ")
        past.complete(key(past, card: 0, set: 0))
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
