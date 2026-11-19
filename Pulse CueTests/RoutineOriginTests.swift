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
