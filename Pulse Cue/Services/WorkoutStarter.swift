//
//  WorkoutStarter.swift
//  Pulse Cue
//
//  The single Runner-start path, shared by the routine list and Quick Plan.
//  Only the *start* is extracted here — Runner initialization itself stays in
//  `RunnerViewModel` (not duplicated), and there is no Quick-Plan-specific
//  session source of truth.
//
//  It preserves the existing 3-layer rest hierarchy: the steps' current rest
//  values seed `RoutineRestPreferenceStore.prepareRoutine`, then each step's
//  rest is resolved as step-override → routine-default → app-default before
//  the workout begins — exactly what `WorkoutView.startRoutine` did.
//

import Foundation
import SwiftData

enum WorkoutStarter {

    /// Seeds rest preferences from `steps`, resolves each step's rest through
    /// the 3-layer hierarchy, persists, then hands the routine to the runner.
    /// A no-op for an empty routine so an emptily-generated plan can never
    /// start a blank session.
    @MainActor
    static func start(
        routine: Routine,
        steps: [Step],
        modelContext: ModelContext,
        restStore: RoutineRestPreferenceStore,
        appDefaultRestSeconds: Int,
        runner: RunnerViewModel
    ) {
        guard !steps.isEmpty else { return }
        restStore.prepareRoutine(
            routine.id,
            existingStepRests: steps
                .sorted { $0.order < $1.order }
                .map { (id: $0.id, seconds: $0.restSeconds) },
            appDefault: appDefaultRestSeconds
        )
        let routineRest = restStore.routineDefault(for: routine.id, appDefault: appDefaultRestSeconds)
        for step in steps {
            step.restSeconds = restStore.stepOverride(for: step.id) ?? routineRest
        }
        try? modelContext.save()
        runner.start(routine: routine)
    }
}

// MARK: - Free Workout

/// A workout built while it runs: exercises and sets are added, removed and
/// reordered on the fly, with no routine prepared beforehand.
///
/// Persistence is the ordinary one, so History, Progress and previous
/// performance read it with no special case: a hidden `.freeWorkout` routine
/// (kept out of the library, like Quick Plan's `.workoutGenerated` one) owns
/// the session's `Step`s, `Session.routineId` points at it, and every set is a
/// `StepResult` written by `StepResultWriter` — the Runner's own snapshot
/// rules. The routine is kept after the workout so History can name it.
///
/// This type owns domain and persistence only — no UI state. Every mutation
/// is refused once the session is no longer in progress.
///
/// Set model. `Step.sets` is the number of set rows the exercise shows; rows
/// are `0..<sets`, and a row is recorded when a `StepResult` with that
/// `setIndex` exists. Persisted `setIndex` stays dense: removing a set shifts
/// the later ones down, because History labels sets by `setIndex + 1`.
///
/// Planned sets. A Free Workout has no plan other than its live set list, so
/// every result of a (session, step) record carries `plannedSetsAtExecution
/// == step.sets` at all times, and `finish()` trims the list to the sets that
/// were actually logged (done or skipped). The finished record therefore
/// states its real structure — never nil, which previous performance would
/// read as a legacy record judged against a future routine's set count, and
/// never a stale or split value.
@MainActor
final class FreeWorkoutSession {

    static let routineName = "フリーワークアウト"
    static let defaultRepsTarget = 10
    static let defaultRestSeconds = 90

    let session: Session
    let routine: Routine
    private let context: ModelContext

    private init(context: ModelContext, session: Session, routine: Routine) {
        self.context = context
        self.session = session
        self.routine = routine
    }

    // MARK: Start / resume

    /// Starts an empty Free Workout. Nil while the data scope is unknown — the
    /// same rule as the Runner: no workout is created under a guessed owner.
    static func start(in context: ModelContext, scope: WorkoutDataScope, now: Date = Date()) -> FreeWorkoutSession? {
        guard scope.canCreateWorkouts else { return nil }
        let routine = Routine(name: routineName, createdAt: now, updatedAt: now, origin: .freeWorkout)
        let session = Session(
            routineId: routine.id,
            dayDate: DateUtils.startOfDay(now),
            startedAt: now,
            ownerAccountID: scope.creationOwnerAccountID
        )
        context.insert(routine)
        context.insert(session)
        return FreeWorkoutSession(context: context, session: session, routine: routine)
    }

    /// Re-attaches to an in-progress Free Workout of this scope.
    static func resume(_ session: Session, in context: ModelContext, scope: WorkoutDataScope) -> FreeWorkoutSession? {
        guard session.status == .inProgress, scope.matches(ownerAccountID: session.ownerAccountID) else { return nil }
        let routineId = session.routineId
        let descriptor = FetchDescriptor<Routine>(predicate: #Predicate<Routine> { $0.id == routineId })
        guard let routine = try? context.fetch(descriptor).first, routine.origin == .freeWorkout else { return nil }
        return FreeWorkoutSession(context: context, session: session, routine: routine)
    }

    var isActive: Bool { session.status == .inProgress }

    /// The exercises in display order.
    var steps: [Step] {
        let routineId = routine.id
        let descriptor = FetchDescriptor<Step>(
            predicate: #Predicate<Step> { $0.routineId == routineId }
        )
        return ((try? context.fetch(descriptor)) ?? []).sorted {
            $0.order != $1.order ? $0.order < $1.order : $0.id.uuidString < $1.id.uuidString
        }
    }

    func results(for step: Step) -> [StepResult] {
        StepResultWriter.results(in: context, sessionId: session.id, stepId: step.id)
            .sorted { $0.setIndex < $1.setIndex }
    }

    private var allResults: [StepResult] {
        let sessionId = session.id
        let descriptor = FetchDescriptor<StepResult>(predicate: #Predicate<StepResult> { $0.sessionId == sessionId })
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: Exercises

    /// Appends an exercise. The same exercise may be added more than once;
    /// each is its own step.
    @discardableResult
    func addExercise(_ exercise: Exercise, initialSets: Int = 1) -> Step? {
        addExercise(exerciseId: exercise.id.rawValue, title: exercise.displayName, initialSets: initialSets)
    }

    /// Appends an exercise by id and title — for a custom machine the id is nil.
    @discardableResult
    func addExercise(exerciseId: String?, title: String, initialSets: Int = 1) -> Step? {
        guard isActive else { return nil }
        let step = Step(
            routineId: routine.id,
            order: (steps.map(\.order).max() ?? -1) + 1,
            title: title,
            sets: initialSets,
            repsTarget: Self.defaultRepsTarget,
            restSeconds: Self.defaultRestSeconds,
            exerciseId: exerciseId
        )
        context.insert(step)
        return step
    }

    /// Whether `step` may be deleted: only while nothing was recorded for it,
    /// the same line the Runner draws for replacing an exercise.
    func canRemoveExercise(_ step: Step) -> Bool {
        isActive && owns(step) && results(for: step).isEmpty
    }

    @discardableResult
    func removeExercise(_ step: Step) -> Bool {
        guard canRemoveExercise(step) else { return false }
        context.delete(step)
        renumber(steps.filter { $0.id != step.id })
        return true
    }

    /// Moves the exercise at `source` to `destination` (indices into `steps`).
    /// Only `Step.order` changes; results keep their `stepId` and snapshots.
    @discardableResult
    func moveExercise(from source: Int, to destination: Int) -> Bool {
        var ordered = steps
        guard isActive, ordered.indices.contains(source), ordered.indices.contains(destination) else { return false }
        let moved = ordered.remove(at: source)
        ordered.insert(moved, at: destination)
        renumber(ordered)
        return true
    }

    private func renumber(_ ordered: [Step]) {
        for (index, step) in ordered.enumerated() where step.order != index {
            step.order = index
        }
    }

    private func owns(_ step: Step) -> Bool { step.routineId == routine.id }

    // MARK: Sets

    /// Adds one set row. Refused at `Step`'s set cap.
    @discardableResult
    func addSet(to step: Step) -> Bool {
        guard isActive, owns(step), Step.clampSets(step.sets + 1) > step.sets else { return false }
        step.sets += 1
        syncPlannedSets(for: step)
        return true
    }

    /// Removes the set row at `setIndex`, deleting its result if it was
    /// recorded and shifting later results down so `setIndex` stays dense.
    /// The last row of an exercise is cleared rather than removed — removing
    /// the exercise is `removeExercise`.
    @discardableResult
    func removeSet(at setIndex: Int, from step: Step) -> Bool {
        guard isActive, owns(step), (0..<step.sets).contains(setIndex) else { return false }
        let existing = results(for: step)
        for result in existing where result.setIndex == setIndex {
            context.delete(result)
        }
        for result in existing where result.setIndex > setIndex {
            result.setIndex -= 1
        }
        step.sets = Step.clampSets(step.sets - 1)
        syncPlannedSets(for: step)
        return true
    }

    /// Records set row `setIndex` as done (or overwrites it).
    @discardableResult
    func completeSet(at setIndex: Int, of step: Step, reps: Int?, weightKg: Double?) -> StepResult? {
        write(setIndex: setIndex, of: step, done: true, reps: reps.map { max(0, $0) }, weightKg: SetWeight.validated(weightKg))
    }

    /// Records set row `setIndex` as skipped — logged, not performed.
    @discardableResult
    func skipSet(at setIndex: Int, of step: Step) -> StepResult? {
        write(setIndex: setIndex, of: step, done: false, reps: nil, weightKg: nil)
    }

    private func write(setIndex: Int, of step: Step, done: Bool, reps: Int?, weightKg: Double?) -> StepResult? {
        guard isActive, owns(step), (0..<step.sets).contains(setIndex) else { return nil }
        return StepResultWriter.record(
            in: context,
            sessionId: session.id,
            ownerAccountID: session.ownerAccountID,
            step: step,
            setIndex: setIndex,
            done: done,
            actualReps: reps,
            weightKg: weightKg,
            plannedSets: .currentStepSets
        )
    }

    private func syncPlannedSets(for step: Step) {
        for result in results(for: step) {
            result.plannedSetsAtExecution = step.sets
        }
    }

    // MARK: Initial values

    /// Starting weight / reps for set row `setIndex`: the nearest recorded set
    /// above it in this workout; otherwise the matching set of this exercise's
    /// most recent performance in this scope; otherwise the step's target with
    /// no weight. Nothing is persisted — it is a suggestion for the editor.
    func initialEntry(forSetAt setIndex: Int, of step: Step, scope: WorkoutDataScope) -> (reps: Int, weightKg: Double?) {
        if let earlier = results(for: step).last(where: { $0.setIndex < setIndex && $0.actualReps != nil }) {
            return (earlier.actualReps ?? step.repsTarget, earlier.weightKg)
        }
        guard let exerciseId = step.exerciseId,
              let previous = previousPerformance(exerciseId: exerciseId, expectedSets: step.sets, scope: scope),
              !previous.sets.isEmpty
        else { return (step.repsTarget, nil) }
        let set = previous.sets[min(setIndex, previous.sets.count - 1)]
        return (set.reps, set.weightKg)
    }

    func previousPerformance(exerciseId: String, expectedSets: Int, scope: WorkoutDataScope) -> PreviousPerformance? {
        let sessions = scope.visible((try? context.fetch(FetchDescriptor<Session>())) ?? [])
        let results = scope.visible((try? context.fetch(FetchDescriptor<StepResult>())) ?? [])
        let steps = (try? context.fetch(FetchDescriptor<Step>())) ?? []
        return PreviousPerformanceQuery.latest(
            exerciseId: exerciseId,
            excludingSessionId: session.id,
            expectedSets: expectedSets,
            steps: steps,
            sessions: sessions,
            results: results
        )
    }

    // MARK: Finish / discard

    enum FinishOutcome: Equatable {
        /// Saved as a completed session.
        case saved
        /// Nothing was performed, so the whole workout was discarded.
        case discarded
        /// Already finished or discarded; nothing changed.
        case notActive
    }

    /// Ends the workout. With at least one performed set (done with a rep
    /// count) it is saved as completed: unlogged rows are dropped, each
    /// exercise's results are compacted to `0..<n` with `n` as its planned set
    /// count, and exercises with nothing logged are removed. Skip-only or
    /// empty workouts are discarded — a skip is logged, not performed.
    @discardableResult
    func finish(now: Date = Date()) -> FinishOutcome {
        guard isActive else { return .notActive }
        guard allResults.contains(where: Self.isPerformance) else {
            deleteEverything()
            return .discarded
        }
        var kept: [Step] = []
        for step in steps {
            let logged = results(for: step)
            guard !logged.isEmpty else {
                context.delete(step)
                continue
            }
            kept.append(step)
            for (index, result) in logged.enumerated() {
                result.setIndex = index
            }
            step.sets = Step.clampSets(logged.count)
            syncPlannedSets(for: step)
        }
        renumber(kept)
        session.endedAt = now
        session.status = .completed
        session.totalSeconds = max(0, Int(now.timeIntervalSince(session.startedAt)))
        return .saved
    }

    /// Throws the in-progress workout away: its results, steps, routine and
    /// session. Only this session's own rows are touched.
    @discardableResult
    func discard() -> Bool {
        guard isActive else { return false }
        deleteEverything()
        return true
    }

    static func isPerformance(_ result: StepResult) -> Bool {
        result.done && result.actualReps != nil
    }

    private func deleteEverything() {
        for result in allResults { context.delete(result) }
        for step in steps { context.delete(step) }
        context.delete(routine)
        session.status = .abandoned   // marks this handle inactive
        context.delete(session)
    }
}
