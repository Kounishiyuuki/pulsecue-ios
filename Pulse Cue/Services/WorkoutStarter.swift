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

    enum StartOutcome {
        case started(FreeWorkoutSession)
        /// This scope already has an in-progress Free Workout. Nothing was
        /// created; the caller offers resume / discard for these instead.
        case activeWorkoutExists([FreeWorkoutRecovery.Candidate])
        /// The data scope is unknown — the Runner's rule: no workout is
        /// created under a guessed owner.
        case scopeUndetermined

        var session: FreeWorkoutSession? {
            if case let .started(session) = self { return session }
            return nil
        }
    }

    /// Starts an empty Free Workout — unless this scope already has one in
    /// progress, so a double tap or a forgotten workout can never quietly
    /// become two. Existing ones are never deleted here.
    static func start(in context: ModelContext, scope: WorkoutDataScope, now: Date = Date()) -> StartOutcome {
        guard scope.canCreateWorkouts else { return .scopeUndetermined }
        let active = FreeWorkoutRecovery.candidates(in: context, scope: scope)
        guard active.isEmpty else { return .activeWorkoutExists(active) }
        let routine = Routine(name: routineName, createdAt: now, updatedAt: now, origin: .freeWorkout)
        let session = Session(
            routineId: routine.id,
            dayDate: DateUtils.startOfDay(now),
            startedAt: now,
            ownerAccountID: scope.creationOwnerAccountID
        )
        context.insert(routine)
        context.insert(session)
        return .started(FreeWorkoutSession(context: context, session: session, routine: routine))
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

    /// Wall-clock time since the workout began, time spent backgrounded or
    /// with the app closed included — the same `endedAt − startedAt` the
    /// Runner and `finish()` record, so no separate timer state is needed.
    func elapsedSeconds(now: Date = Date()) -> Int {
        max(0, Int(now.timeIntervalSince(session.startedAt)))
    }

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
    ///
    /// For rep-counted sets. Do not use it to complete a timed set: it writes
    /// no duration, so the set would be stored as done without one. Timed
    /// sets go through `completeTimedSet`. The writer still accepts a
    /// duration-free timed set only so historical data stays compatible.
    ///
    /// `setType` nil leaves the kind as it is — working for a new set, and a
    /// re-recorded warm-up stays one; pass `.working` to change it back.
    @discardableResult
    func completeSet(at setIndex: Int, of step: Step, reps: Int?, weightKg: Double?, setType: WorkoutSetType? = nil) -> StepResult? {
        write(setIndex: setIndex, of: step, done: true, reps: reps.map { max(0, $0) }, weightKg: SetWeight.validated(weightKg), setType: setType)
    }

    /// Records set row `setIndex` of a timed exercise as done with how long it
    /// actually ran. Refused (nil, nothing written) unless the step is timed
    /// and `durationSeconds` is positive — this path never stores a timed set
    /// without a duration.
    ///
    /// How a Free Workout completes a timed set. Runner and Free Workout both
    /// take the duration in their set editors and need it to be > 0 (the
    /// Runner writes through `StepResultWriter`, same validation). A timed
    /// set stored without a duration exists only from before durations were
    /// entered; it still reads as "実施済み" for compatibility.
    @discardableResult
    func completeTimedSet(at setIndex: Int, of step: Step, durationSeconds: Int?) -> StepResult? {
        guard !WorkoutSetSemantics.countsReps(exerciseId: step.exerciseId),
              let duration = SetDuration.validated(durationSeconds) else { return nil }
        return write(setIndex: setIndex, of: step, done: true, reps: nil, weightKg: nil, durationSeconds: duration)
    }

    /// Records set row `setIndex` as skipped — logged, not performed. Its
    /// kind is kept (or set, when given), so a skipped warm-up stays one.
    @discardableResult
    func skipSet(at setIndex: Int, of step: Step, setType: WorkoutSetType? = nil) -> StepResult? {
        write(setIndex: setIndex, of: step, done: false, reps: nil, weightKg: nil, setType: setType)
    }

    /// Sets or clears the reps in reserve of done set row `setIndex`, as
    /// `StepResultWriter.recordRepsInReserve` allows.
    @discardableResult
    func recordRepsInReserve(_ value: Int?, at setIndex: Int, of step: Step) -> StepResult? {
        guard isActive, owns(step) else { return nil }
        return StepResultWriter.recordRepsInReserve(value, in: context, sessionId: session.id, step: step, setIndex: setIndex)
    }

    /// Changes the kind of the done set `resultId`, the result the action was made
    /// for. Refused (nil) unless the workout is active, the step is this
    /// workout's, the result is still this workout's and owner's, and it is
    /// still at `setIndex`: after any set above it is removed it has moved,
    /// so an action made before then is stale and never lands anywhere.
    @discardableResult
    func recordSetType(_ setType: WorkoutSetType, resultId: UUID, at setIndex: Int, of step: Step) -> StepResult? {
        guard isActive, owns(step),
              let current = results(for: step).first(where: { $0.id == resultId }),
              current.setIndex == setIndex,
              current.ownerAccountID == session.ownerAccountID
        else { return nil }
        return StepResultWriter.recordSetType(setType, in: context, resultId: resultId, sessionId: session.id, step: step)
    }

    private func write(setIndex: Int, of step: Step, done: Bool, reps: Int?, weightKg: Double?, durationSeconds: Int? = nil, setType: WorkoutSetType? = nil) -> StepResult? {
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
            actualDurationSeconds: durationSeconds,
            plannedSets: .currentStepSets,
            setType: setType
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
    /// most recent performance by the same owner; otherwise the step's target
    /// with no weight. Nothing is persisted — it is a suggestion for the editor.
    func initialEntry(forSetAt setIndex: Int, of step: Step) -> (reps: Int, weightKg: Double?) {
        if let earlier = results(for: step).last(where: { $0.setIndex < setIndex && $0.actualReps != nil }) {
            return (earlier.actualReps ?? step.repsTarget, earlier.weightKg)
        }
        guard let previous = previousPerformance(for: step), !previous.sets.isEmpty
        else { return (step.repsTarget, nil) }
        let set = previous.sets[min(setIndex, previous.sets.count - 1)]
        return (set.reps, set.weightKg)
    }

    /// The most recent finished performance of `step`'s exercise, from this
    /// workout's owner's history only. Nil for an exercise with no id.
    func previousPerformance(for step: Step) -> PreviousPerformance? {
        guard let exerciseId = step.exerciseId else { return nil }
        let scope = historyScope
        let sessions = scope.visible((try? context.fetch(FetchDescriptor<Session>())) ?? [])
        let results = scope.visible((try? context.fetch(FetchDescriptor<StepResult>())) ?? [])
        let steps = (try? context.fetch(FetchDescriptor<Step>())) ?? []
        return PreviousPerformanceQuery.latest(
            exerciseId: exerciseId,
            excludingSessionId: session.id,
            expectedSets: step.sets,
            steps: steps,
            sessions: sessions,
            results: results
        )
    }

    /// When `step`'s exercise was last performed, from the same history.
    func lastTimedPerformance(for step: Step) -> PreviousTimedPerformance? {
        guard let exerciseId = step.exerciseId else { return nil }
        let scope = historyScope
        return PreviousPerformanceQuery.lastTimedPerformance(
            exerciseId: exerciseId,
            excludingSessionId: session.id,
            steps: (try? context.fetch(FetchDescriptor<Step>())) ?? [],
            sessions: scope.visible((try? context.fetch(FetchDescriptor<Session>())) ?? []),
            results: scope.visible((try? context.fetch(FetchDescriptor<StepResult>())) ?? [])
        )
    }

    /// Whose history this workout may read: its own session's owner, fixed
    /// when it was created. Deliberately not a caller argument and not the
    /// live account state — a sign-in change mid-workout must not let this
    /// session read another owner's history.
    private var historyScope: WorkoutDataScope {
        session.ownerAccountID.map(WorkoutDataScope.account) ?? .guest
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
    /// count, and exercises with nothing logged are removed. A blank row is an
    /// input field, not a planned set; a skip is a planned set not performed
    /// (so the record stays honestly incomplete). Skip-only or
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

    /// A rep-counted set is performed with a rep count; a timed set with a
    /// positive duration. A done timed set with no duration (recorded before
    /// V15, or before the editor sends durations) still counts: it was done,
    /// and dropping it would erase a real workout.
    static func isPerformance(_ result: StepResult) -> Bool {
        guard result.done else { return false }
        if WorkoutSetSemantics.countsReps(exerciseId: result.exerciseIdAtExecution) {
            return result.actualReps != nil
        }
        return result.actualDurationSeconds.map { $0 > 0 } ?? true
    }

    private func deleteEverything() {
        for result in allResults { context.delete(result) }
        for step in steps { context.delete(step) }
        context.delete(routine)
        session.status = .abandoned   // marks this handle inactive
        context.delete(session)
    }
}

// MARK: - Free Workout recovery

/// Finds Free Workouts left in progress — the app was closed, the screen was
/// left, a crash — so they can be resumed or discarded instead of lingering.
///
/// Deciding *which* workouts there are lives here; re-attaching to one is
/// `FreeWorkoutSession.resume`, and throwing one away is its `discard()`.
/// Views ask this type and never query SwiftData themselves.
///
/// What counts: an in-progress session, in the current scope, whose routine
/// exists and is `.freeWorkout`. An in-progress session alone is not enough —
/// the Runner's and Quick Plan's look the same — and a session whose routine
/// is gone cannot be told apart from theirs, so it is left alone.
///
/// Nothing here deletes, finishes or repairs on its own. Several leftovers
/// (an old crash) are all listed, newest first, and a day-old one is still
/// offered: only the person holding the phone decides.
@MainActor
enum FreeWorkoutRecovery {

    /// What a recovery card shows, as values only. It deliberately holds no
    /// SwiftData object: a card can outlive its workout (a double tap on
    /// 破棄, a stale sheet), and a deleted model must never be read. Every
    /// operation re-fetches the session by `id` and re-validates it.
    struct Candidate: Identifiable, Equatable, Sendable {
        /// The session's id.
        let id: UUID
        /// For "昨日 21:10開始".
        let startedAt: Date
        /// Exercises added, logged or not.
        let stepCount: Int
        /// Results written — done and skipped alike.
        let loggedResultCount: Int
        /// As of listing, for display. `resume` re-evaluates it.
        let isResumable: Bool
    }

    /// In-progress Free Workouts of `scope`, newest first (session id breaks
    /// ties). Empty while the scope is unknown: fail closed.
    static func candidates(in context: ModelContext, scope: WorkoutDataScope) -> [Candidate] {
        guard scope.canCreateWorkouts else { return [] }
        // Filtered in memory: predicates over a Codable enum attribute are not
        // reliably supported by SwiftData.
        let sessions = scope.visible((try? context.fetch(FetchDescriptor<Session>())) ?? [])
            .filter { $0.status == .inProgress }
        guard !sessions.isEmpty else { return [] }
        let routineIds = Set(sessions.map(\.routineId))
        let routines = ((try? context.fetch(FetchDescriptor<Routine>())) ?? [])
            .filter { routineIds.contains($0.id) && $0.origin == .freeWorkout }
        let routineById = Dictionary(routines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return sessions
            .compactMap { session -> Candidate? in
                guard routineById[session.routineId] != nil else { return nil }
                let structure = Structure(sessionId: session.id, routineId: session.routineId, in: context)
                return Candidate(
                    id: session.id,
                    startedAt: session.startedAt,
                    stepCount: structure.stepIds.count,
                    loggedResultCount: structure.resultStepIds.count,
                    isResumable: structure.isIntact
                )
            }
            .sorted {
                $0.startedAt != $1.startedAt ? $0.startedAt > $1.startedAt : $0.id.uuidString > $1.id.uuidString
            }
    }

    static func hasActiveFreeWorkout(in context: ModelContext, scope: WorkoutDataScope) -> Bool {
        !candidates(in: context, scope: scope).isEmpty
    }

    /// The one a single "再開" card offers: the newest. The others stay listed.
    static func latest(in context: ModelContext, scope: WorkoutDataScope) -> Candidate? {
        candidates(in: context, scope: scope).first
    }

    /// Re-attaches to `candidate`, judged on the store as it is now — nothing
    /// the candidate captured is trusted. Nil when the session is gone, when
    /// `FreeWorkoutSession.resume` (the authority on status, scope and
    /// origin) refuses it, or when a result points at a step that no longer
    /// exists. Unlogged exercises or rows are a normal draft, not damage.
    static func resume(_ candidate: Candidate, in context: ModelContext, scope: WorkoutDataScope) -> FreeWorkoutSession? {
        guard let session = currentSession(id: candidate.id, in: context),
              let handle = FreeWorkoutSession.resume(session, in: context, scope: scope),
              Structure(sessionId: session.id, routineId: handle.routine.id, in: context).isIntact
        else { return nil }
        return handle
    }

    /// Throws `candidate` away — its session, routine, steps and results only.
    /// Works for a non-resumable one too. False, touching nothing, when the
    /// session is already gone (a second tap), finished, or not in this scope.
    @discardableResult
    static func discard(_ candidate: Candidate, in context: ModelContext, scope: WorkoutDataScope) -> Bool {
        guard let session = currentSession(id: candidate.id, in: context) else { return false }
        return FreeWorkoutSession.resume(session, in: context, scope: scope)?.discard() ?? false
    }

    private static func currentSession(id: UUID, in context: ModelContext) -> Session? {
        try? context.fetch(FetchDescriptor<Session>(predicate: #Predicate<Session> { $0.id == id })).first
    }

    /// Whether a workout's results still belong to its steps. The only
    /// structural damage recovery looks for; it is reported, never repaired.
    private struct Structure {
        let stepIds: Set<UUID>
        let resultStepIds: [UUID]

        init(sessionId: UUID, routineId: UUID, in context: ModelContext) {
            stepIds = Set(((try? context.fetch(FetchDescriptor<Step>(
                predicate: #Predicate<Step> { $0.routineId == routineId }))) ?? []).map(\.id))
            resultStepIds = ((try? context.fetch(FetchDescriptor<StepResult>(
                predicate: #Predicate<StepResult> { $0.sessionId == sessionId }))) ?? []).map(\.stepId)
        }

        var isIntact: Bool { resultStepIds.allSatisfy(stepIds.contains) }
    }
}
