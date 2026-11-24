//
//  RunnerViewModel.swift
//  Pulse Cue
//
//  Created by Codex.
//

import Foundation
import SwiftData
import Combine
import UserNotifications

@MainActor
final class RunnerViewModel: ObservableObject {
    struct CompleteContext: Equatable {
        fileprivate let sessionId: UUID
        fileprivate let phase: RunnerPhase
        fileprivate let stepId: UUID
        fileprivate let stepIndex: Int
        fileprivate let setIndex: Int
        fileprivate let generation: UInt
    }

    @Published private(set) var phase: RunnerPhase = .done
    @Published private(set) var currentStepIndex: Int = 0
    @Published private(set) var currentSetIndex: Int = 0
    @Published private(set) var currentReps: Int = 0
    /// Load for the set on screen, in kg; `nil` = not entered. Transient until
    /// Complete writes it to that set's `StepResult.weightKg`, which is the
    /// truth. Carried to the next set of the same exercise as a starting value.
    @Published private(set) var currentWeightKg: Double?
    /// Duration typed for the timed set on screen. Like the load: empty for
    /// every new set (no fake default), written to
    /// `StepResult.actualDurationSeconds` by Complete, and restored after a
    /// relaunch onto the same step and set, invalid entries included.
    @Published private(set) var currentDuration = DurationEntry()
    @Published private(set) var restDeadline: Date?
    @Published private(set) var remainingSeconds: Int = 0
    @Published var needsAttention: Bool = false
    @Published private(set) var sessionId: UUID?
    @Published private(set) var routineId: UUID?
    @Published private(set) var isConfigured: Bool = false
    /// The current exercise's last completed performance and a conservative
    /// reps target, derived read-only from History. Recomputed only on
    /// exercise change (see `refreshExerciseInsight`), never per rest tick.
    @Published private(set) var previousPerformance: PreviousPerformance?
    /// For a timed exercise: when it was last done. Shown as "実施済み".
    @Published private(set) var previousTimedPerformance: PreviousTimedPerformance?
    @Published private(set) var progression: ProgressionSuggestion?
    /// Non-nil only between a *completed* finish and the user dismissing the
    /// Workout Completion screen. Purely presentational: the session it
    /// describes is already finalized, so nothing here re-writes History.
    /// An abandoned session (quit) never produces one.
    @Published private(set) var completion: WorkoutCompletionSummary?
    /// The rep-counted set completed last in this workout, whose reps in
    /// reserve stay editable whatever the phase (#258). Fixed when the set is
    /// completed, so it never follows the position. The stored
    /// `StepResult.repsInReserve` is the truth; this holds a copy read once
    /// per change, never per rest tick.
    @Published private(set) var lastCompletedSet: LastCompletedSet?

    struct LastCompletedSet: Equatable {
        let stepId: UUID
        let setIndex: Int
        let title: String
        /// History's own set text ("80 kg × 10 回"), so loads read the same.
        let valueText: String
        let accessibilityLabel: String
        let repsInReserve: Int?
    }

    private var modelContext: ModelContext?
    /// Whose workouts this Runner may start, resume and read.
    ///
    /// Defaults to `.guest` so the DEBUG QA roots and the existing tests — all
    /// of which work with unowned data — behave exactly as they did.
    private var scope: WorkoutDataScope = .guest
    private var routine: Routine?
    private var steps: [Step] = []
    private var session: Session?
    private var timer: Timer?
    private var restNotificationGeneration = 0
    private var attentionGeneration = 0
    private var completeGeneration: UInt = 0
    private let notificationManager: any RunnerNotificationManaging

    let settings: SettingsStore

    init(
        settings: SettingsStore,
        notificationManager: (any RunnerNotificationManaging)? = nil
    ) {
        self.settings = settings
        self.notificationManager = notificationManager ?? NotificationManager.shared
    }

    func configure(modelContext: ModelContext, scope: WorkoutDataScope = .guest) {
        guard !isConfigured else { return }
        self.modelContext = modelContext
        self.scope = scope
        self.isConfigured = true
        restoreIfPossible()
    }

    /// React to the signed-in account changing underneath a running app.
    ///
    /// Two things have to happen, in this order. A workout that is no longer
    /// in scope is let go of — an account switch must not leave the previous
    /// account's set still counting down on screen — and then whatever *is* in
    /// scope is picked up, so signing back in returns you to your own workout.
    ///
    /// Letting go is in-memory only. The session row keeps its owner and the
    /// saved resume point is left exactly where it is, because the workout is
    /// not abandoned: it belongs to somebody who is not currently signed in,
    /// and they are entitled to find it again.
    func applyScope(_ newScope: WorkoutDataScope) {
        guard isConfigured, newScope != scope else {
            scope = newScope
            return
        }
        scope = newScope
        if let session, !newScope.matches(ownerAccountID: session.ownerAccountID) {
            detachFromActiveSession()
        }
        if session == nil {
            restoreIfPossible()
        }
    }

    /// Drop the in-memory workout without touching the stored session or the
    /// saved resume point.
    private func detachFromActiveSession() {
        if let sessionId {
            cancelRestNotification(for: sessionId)
        }
        stopTimer()
        invalidateCompleteContext()
        invalidateAttention()
        completion = nil
        session = nil
        sessionId = nil
        routine = nil
        routineId = nil
        steps = []
        currentStepIndex = 0
        currentSetIndex = 0
        currentReps = 0
        currentWeightKg = nil
        currentDuration = DurationEntry()
        phase = .done
        restDeadline = nil
        remainingSeconds = 0
        previousPerformance = nil
        previousTimedPerformance = nil
        progression = nil
        lastCompletedSet = nil
    }

    func start(routine: Routine) {
        guard let modelContext else { return }
        // No workout is started under an unknown scope. It would have to guess
        // an owner, and the harmless-looking guess — "guest for now" — makes an
        // account holder's workout invisible the moment their session confirms.
        guard scope.canCreateWorkouts else { return }
        completion = nil
        invalidateCompleteContext()
        stopTimer()
        invalidateAttention()
        cancelRestNotification()

        self.routine = routine
        self.routineId = routine.id
        self.steps = fetchSteps(routineId: routine.id)
        self.currentStepIndex = 0
        self.currentSetIndex = 0
        self.currentReps = steps.first?.repsTarget ?? 0
        self.currentWeightKg = nil
        self.currentDuration = DurationEntry()
        self.phase = .exercise
        self.restDeadline = nil
        self.remainingSeconds = 0
        self.lastCompletedSet = nil

        let session = Session(
            routineId: routine.id,
            dayDate: DateUtils.startOfDay(Date()),
            ownerAccountID: scope.creationOwnerAccountID
        )
        modelContext.insert(session)
        self.session = session
        self.sessionId = session.id
        cancelRestNotification(for: session.id)

        if steps.isEmpty {
            finishSession(completed: true)
            return
        }

        saveState()
    }

    var completeContext: CompleteContext? {
        guard let sessionId, let stepId = currentStep?.id, phase != .done else { return nil }
        // A timed set completes only with a valid duration typed in; until
        // then there is nothing to complete, so the button is disabled.
        if phase == .exercise, currentDurationIssue != nil { return nil }
        return CompleteContext(
            sessionId: sessionId,
            phase: phase,
            stepId: stepId,
            stepIndex: currentStepIndex,
            setIndex: currentSetIndex,
            generation: completeGeneration
        )
    }

    func handle(action: RunnerAction) {
        switch action {
        case .complete:
            // Complete must be bound to the phase and position rendered by the
            // caller. Re-reading current state here would turn a duplicate
            // exercise Complete into a rest completion (or complete a zero-rest
            // next set), so context-free Complete is intentionally ignored.
            return
        case .skip:
            skipCurrent()
        case .extend:
            extendRest()
        case .back:
            goBack()
        }
    }

    func handle(action: RunnerAction, context: CompleteContext) {
        guard case .complete = action, context == completeContext else { return }
        invalidateCompleteContext()
        completeCurrent()
    }

    func endSessionEarly() {
        invalidateCompleteContext()
        finishSession(completed: false)
    }

    /// Closes the Workout Completion screen. Presentation-only: the session
    /// was finalized once by `finishSession`, so this writes nothing, changes
    /// no History row, and never starts another Session.
    func dismissCompletion() {
        completion = nil
    }

    /// Whether the Runner cover belongs on screen — an active workout, or a
    /// finished one whose completion summary has not been dismissed yet.
    var shouldPresentRunner: Bool {
        isRunning || completion != nil
    }

    func adjustCurrentReps(by adjustment: Int) {
        guard phase == .exercise, isRunning else { return }
        let (adjustedReps, overflowed) = currentReps.addingReportingOverflow(adjustment)
        guard !overflowed else { return }
        currentReps = max(0, adjustedReps)
        saveState()
    }

    /// Whether the current exercise takes a load. Hidden only when the library
    /// says the movement is timed or cardio; custom / unresolved exercises
    /// accept a weight.
    var currentStepAcceptsWeight: Bool {
        guard let step = currentStep else { return false }
        guard let exercise = resolvedExercise(for: step) else { return true }
        return !exercise.isDurationBased && exercise.movementPattern != .cardio
    }

    /// False for a timed movement: the rep counter is hidden and no rep count
    /// is recorded.
    var currentStepTracksReps: Bool {
        guard let step = currentStep else { return true }
        return WorkoutSetSemantics.countsReps(exerciseId: step.exerciseId)
    }

    /// Sets or clears (`nil`) the reps in reserve of the set at `stepId` /
    /// `setIndex` — the target the caller showed, never the position now on
    /// screen, so a choice that lands after the Runner moved on still goes to
    /// the set it was made for. Written through the domain first; the copy on
    /// screen follows only a successful write. Optional: nothing waits for it.
    func recordRepsInReserve(_ value: Int?, stepId: UUID, setIndex: Int) {
        guard let modelContext, let sessionId, let step = steps.first(where: { $0.id == stepId }),
              StepResultWriter.recordRepsInReserve(value, in: modelContext, sessionId: sessionId, step: step, setIndex: setIndex) != nil
        else { return }
        try? modelContext.save()
        if let last = lastCompletedSet, last.stepId == stepId, last.setIndex == setIndex {
            lastCompletedSet = loadLastCompletedSet(stepId: stepId, setIndex: setIndex)
        }
    }

    /// The target for a done, rep-counted result of this session; nil for
    /// anything else (missing, skipped, timed), so a stale target is dropped.
    private func loadLastCompletedSet(stepId: UUID, setIndex: Int) -> LastCompletedSet? {
        guard let modelContext, let sessionId, let step = steps.first(where: { $0.id == stepId }),
              let result = StepResultWriter.results(in: modelContext, sessionId: sessionId, stepId: stepId)
                .first(where: { $0.setIndex == setIndex }),
              result.done,
              WorkoutSetSemantics.countsReps(exerciseId: result.exerciseIdAtExecution ?? step.exerciseId)
        else { return nil }
        let title = result.exerciseTitleAtExecution ?? step.title
        return LastCompletedSet(
            stepId: stepId,
            setIndex: setIndex,
            title: title,
            valueText: SessionHistoryPresentation.setValueText(result),
            accessibilityLabel: "直前のセット、\(title)、" + SessionHistoryPresentation.setAccessibilityLabel(result),
            repsInReserve: result.repsInReserve
        )
    }

    /// Why the timed set on screen cannot be completed yet; nil when it can,
    /// and always nil for a rep-counted set.
    var currentDurationIssue: DurationEntry.Issue? {
        guard !currentStepTracksReps else { return nil }
        return currentDuration.issue
    }

    /// The duration typed for the timed set on screen, kept as entered —
    /// an out-of-range value shows its reason rather than being corrected.
    func setCurrentDuration(_ entry: DurationEntry) {
        guard phase == .exercise, isRunning, !currentStepTracksReps else { return }
        currentDuration = entry
        saveState()
    }

    /// Sets the current set's load. Invalid values (negative, non-finite, over
    /// `SetWeight.maximumKg`) are ignored rather than clamped; `nil` clears it.
    func setCurrentWeight(_ kg: Double?) {
        guard phase == .exercise, isRunning, currentStepAcceptsWeight else { return }
        if let kg {
            guard let valid = SetWeight.validated(kg) else { return }
            currentWeightKg = valid
        } else {
            currentWeightKg = nil
        }
        saveState()
    }

    /// Steps the current load; floors at 0. No-op while nothing is entered.
    func adjustCurrentWeight(by delta: Double) {
        guard let current = currentWeightKg else { return }
        setCurrentWeight(max(0, current + delta))
    }

    func shortenRest() {
        adjustRest(by: -10)
    }

    func appDidBecomeActive() {
        guard phase == .rest else { return }
        if let deadline = restDeadline, deadline > Date() {
            startTimer()
            scheduleRestNotification()
        } else {
            restDeadline = nil
            phase = .exercise
            cancelRestNotification()
            signalAttentionIfNeeded()
            advanceAfterRest()
        }
    }

    func appDidEnterBackground() {
        saveState()
    }

    var currentStep: Step? {
        guard steps.indices.contains(currentStepIndex) else { return nil }
        return steps[currentStepIndex]
    }

    var nextStep: Step? {
        let nextIndex = currentStepIndex + 1
        guard steps.indices.contains(nextIndex) else { return nil }
        return steps[nextIndex]
    }

    // MARK: - Exercise replacement

    /// The current exercise can be swapped only before any of its sets is
    /// recorded (and while actually exercising, not resting). Set 0 alone is
    /// not enough: Back after a Complete or Skip returns there too.
    var canReplaceCurrentExercise: Bool {
        guard isRunning, phase == .exercise, currentSetIndex == 0, let step = currentStep else { return false }
        return !hasRecordedResult(for: step)
    }

    /// The next exercise can be swapped whenever a workout is running and it
    /// has no result in this session yet.
    var canReplaceNextExercise: Bool {
        guard isRunning, let step = nextStep else { return false }
        return !hasRecordedResult(for: step)
    }

    /// Whether this session already holds any result — done or skipped — for
    /// `step`. Replacing such a step would make the screen disagree with the
    /// exercise snapshotted on its results. Other sessions' results do not
    /// count: history alone never blocks a swap.
    private func hasRecordedResult(for step: Step) -> Bool {
        // Undeterminable counts as recorded (fail closed), like a failed fetch.
        guard let modelContext, let sessionId else { return true }
        let stepId = step.id
        let descriptor = FetchDescriptor<StepResult>(
            predicate: #Predicate<StepResult> { $0.sessionId == sessionId && $0.stepId == stepId }
        )
        // A failed fetch counts as recorded: refuse rather than risk a mismatch.
        return ((try? modelContext.fetchCount(descriptor)) ?? 1) > 0
    }

    /// Ranked replacement candidates for `step`, from the active gym's
    /// available equipment, excluding the workout's other exercises. Empty
    /// when the step has no resolvable exercise (e.g. a custom machine) or the
    /// gym has nothing else available — the sheet then shows a no-alternative
    /// message rather than a dead end.
    func replacementCandidates(for step: Step) -> [GeneratedExercise] {
        guard let modelContext, let exercise = resolvedExercise(for: step) else { return [] }
        let repo = GymRepository(modelContext: modelContext)
        guard let gym = repo.activeGym() else { return [] }
        let equipment = repo.availableEquipment(for: gym, availableOnly: true)
        let originalMachineId = exercise.compatibleMachineIds.first ?? (step.exerciseId ?? "")
        let others = Set(steps.compactMap { other -> String? in
            guard other.id != step.id else { return nil }
            return resolvedExercise(for: other)?.compatibleMachineIds.first
        })
        return WorkoutPlanGenerator.alternatives(
            toMachineId: originalMachineId,
            bodyParts: Set(exercise.bodyParts),
            usableEquipment: equipment,
            excludingMachineIds: others
        )
    }

    /// Replaces the exercise on `step` with `candidate`, keeping the original
    /// sets / reps / rest. Allowed only for the current exercise before any
    /// set is completed, or an as-yet-unstarted later exercise — a completed
    /// or in-progress exercise — any step with a result in this session — is
    /// never rewritten, and no `StepResult` is touched. Returns whether the replacement applied.
    @discardableResult
    func replaceExercise(_ step: Step, with candidate: GeneratedExercise) -> Bool {
        guard isRunning else { return false }
        guard let index = steps.firstIndex(where: { $0.id == step.id }) else { return false }
        let isCurrentUnstarted = index == currentStepIndex && phase == .exercise && currentSetIndex == 0
        let isFutureUnstarted = index > currentStepIndex
        guard isCurrentUnstarted || isFutureUnstarted, !hasRecordedResult(for: step) else { return false }

        objectWillChange.send()
        step.title = candidate.exerciseName
        step.exerciseId = RoutineFactory.persistableExerciseId(candidate.exerciseId)
        step.note = candidate.cue
        // sets / repsTarget / restSeconds / order are intentionally preserved.

        // Drop any in-flight Complete bound to the old position, and refresh
        // the on-screen rep counter when the current exercise changed.
        invalidateCompleteContext()
        if index == currentStepIndex {
            currentReps = step.repsTarget
            currentWeightKg = nil
            currentDuration = DurationEntry()
        }
        try? modelContext?.save()
        saveState()
        if index == currentStepIndex { refreshExerciseInsight() }
        return true
    }

    // MARK: - Previous performance / progression (read-only)

    /// Recomputes `previousPerformance` and `progression` for the current
    /// exercise from History. Called on workout start, exercise change, and
    /// after a replacement — never per rest tick. Read-only: no `StepResult`,
    /// `Session`, or session state is modified.
    func refreshExerciseInsight() {
        guard let modelContext, let step = currentStep, let exerciseId = step.exerciseId else {
            previousPerformance = nil
            previousTimedPerformance = nil
            progression = nil
            return
        }
        let allSteps = (try? modelContext.fetch(FetchDescriptor<Step>())) ?? []
        // History in scope only: a previous-performance number is a claim about
        // what *you* lifted last time, and the current account's is the only
        // honest source for it.
        let allSessions = scope.visible((try? modelContext.fetch(FetchDescriptor<Session>())) ?? [])
        let allResults = scope.visible((try? modelContext.fetch(FetchDescriptor<StepResult>())) ?? [])

        let previous = PreviousPerformanceQuery.latest(
            exerciseId: exerciseId,
            excludingSessionId: sessionId,
            expectedSets: step.sets,
            currentStepOrder: step.order,
            steps: allSteps,
            sessions: allSessions,
            results: allResults
        )
        // Rep progression is inappropriate for cardio; custom machines (no
        // resolvable exercise) are treated as rep-trainable.
        let isCardio = resolvedExercise(for: step)?.movementPattern == .cardio
        previousPerformance = previous
        previousTimedPerformance = currentStepTracksReps ? nil : PreviousPerformanceQuery.lastTimedPerformance(
            exerciseId: exerciseId, excludingSessionId: sessionId,
            steps: allSteps, sessions: allSessions, results: allResults
        )
        progression = ProgressionRule.suggest(
            previous: previous,
            baselineReps: step.repsTarget,
            expectedSets: step.sets,
            allowsRepProgression: !isCardio,
            allowsWeightProgression: currentStepAcceptsWeight
        )
    }

    /// Copies the suggestion into the current set's on-screen reps and, for a
    /// load suggestion, its weight. Only on an explicit tap — never on
    /// exercise start. Transient only, like the ± buttons: no `StepResult`,
    /// `Step`, or `Routine` is touched; Complete records it as usual.
    func applyProgressionSuggestion() {
        guard phase == .exercise, isRunning, let suggestion = progression else { return }
        currentReps = max(0, suggestion.suggestedReps)
        if let weight = suggestion.suggestedWeightKg, currentStepAcceptsWeight,
           let valid = SetWeight.validated(weight) {
            currentWeightKg = valid
        }
        saveState()
    }

    /// Representative catalog machine id for a step's exercise, used by the
    /// replacement sheet's "same movement" relation label. Empty when the
    /// step has no resolvable exercise (e.g. a custom machine).
    func exerciseMachineId(for step: Step) -> String {
        resolvedExercise(for: step)?.compatibleMachineIds.first ?? ""
    }

    private func resolvedExercise(for step: Step) -> Exercise? {
        guard let idString = step.exerciseId else { return nil }
        return ExerciseLibrary.exercise(for: ExerciseID(rawValue: idString))
    }

    var isRunning: Bool {
        phase != .done && sessionId != nil
    }

    private func completeCurrent() {
        guard phase != .done else { return }
        if phase == .rest {
            finishRest()
            return
        }
        guard let step = currentStep else {
            finishSession(completed: true)
            return
        }

        let duration: Int?
        if currentStepTracksReps {
            duration = nil
        } else {
            guard let seconds = currentDuration.totalSeconds else { return }
            duration = seconds
        }
        recordStepResult(
            done: true,
            actualReps: currentStepTracksReps ? currentReps : nil,
            weightKg: currentStepAcceptsWeight ? currentWeightKg : nil,
            actualDurationSeconds: duration
        )
        // A timed set clears the target: an older strength set is no longer
        // the one just done.
        lastCompletedSet = currentStepTracksReps ? loadLastCompletedSet(stepId: step.id, setIndex: currentSetIndex) : nil
        startRest(for: step)
    }

    private func skipCurrent() {
        guard phase != .done else { return }
        invalidateCompleteContext()
        invalidateAttention()
        cancelRestNotification()
        if phase == .rest {
            stopTimer()
            restDeadline = nil
            advanceToNextStepSkippingSets()
            return
        }
        guard currentStep != nil else {
            finishSession(completed: true)
            return
        }
        recordStepResult(done: false, actualReps: nil, weightKg: nil)
        advanceToNextStepSkippingSets()
    }

    private func extendRest() {
        adjustRest(by: 10)
    }

    private func adjustRest(by adjustment: Int) {
        guard phase == .rest, let deadline = restDeadline else { return }
        let adjustedRemaining = max(0, deadline.timeIntervalSinceNow + TimeInterval(adjustment))
        restDeadline = Date().addingTimeInterval(adjustedRemaining)
        tick()
        guard phase == .rest else { return }
        scheduleRestNotification()
        saveState()
    }

    private func goBack() {
        guard phase != .done else { return }
        // Going back re-opens a set for re-recording; its next Complete sets
        // the target again.
        if phase == .rest {
            lastCompletedSet = nil
            invalidateCompleteContext()
            invalidateAttention()
            cancelRestNotification()
            phase = .exercise
            restDeadline = nil
            stopTimer()
            currentReps = restoredRepsForCurrentPosition()
            restoreWeightForCurrentPosition()
            saveState()
            return
        }

        guard currentSetIndex > 0 || currentStepIndex > 0 else { return }
        invalidateAttention()
        cancelRestNotification()
        var moved = false
        if currentSetIndex > 0 {
            currentSetIndex -= 1
            moved = true
        } else if currentStepIndex > 0 {
            currentStepIndex -= 1
            currentSetIndex = max(0, (currentStep?.sets ?? 1) - 1)
            moved = true
        }
        guard moved else { return }
        lastCompletedSet = nil
        invalidateCompleteContext()
        currentReps = restoredRepsForCurrentPosition()
        restoreWeightForCurrentPosition()
        saveState()
    }

    private func startRest(for step: Step) {
        invalidateAttention()
        if step.restSeconds <= 0 {
            cancelRestNotification()
            advanceAfterRest()
            return
        }
        phase = .rest
        restDeadline = Date().addingTimeInterval(TimeInterval(step.restSeconds))
        startTimer()
        scheduleRestNotification()
        saveState()
    }

    private func finishRest() {
        invalidateAttention()
        restDeadline = nil
        stopTimer()
        cancelRestNotification()
        advanceAfterRest()
    }

    private func advanceAfterRest() {
        guard let step = currentStep else {
            finishSession(completed: true)
            return
        }

        if currentSetIndex + 1 < step.sets {
            // Same exercise: the load just used is the natural starting value.
            currentSetIndex += 1
        } else {
            currentSetIndex = 0
            currentStepIndex += 1
            currentWeightKg = nil
        }

        if currentStepIndex >= steps.count {
            finishSession(completed: true)
            return
        }

        phase = .exercise
        currentReps = currentStep?.repsTarget ?? 0
        currentDuration = DurationEntry()
        saveState()
    }

    private func advanceToNextStepSkippingSets() {
        currentSetIndex = 0
        currentStepIndex += 1
        currentWeightKg = nil

        if currentStepIndex >= steps.count {
            finishSession(completed: true)
            return
        }

        phase = .exercise
        currentReps = currentStep?.repsTarget ?? 0
        currentDuration = DurationEntry()
        saveState()
    }

    private func finishSession(completed: Bool) {
        guard let session else {
            resetState()
            return
        }

        session.endedAt = Date()
        session.status = completed ? .completed : .abandoned
        session.totalSeconds = Int(session.endedAt!.timeIntervalSince(session.startedAt))

        // Snapshot after finalization but before `resetState()` clears the
        // session, so the Completion screen reports the finalized numbers.
        // A routine with no steps finishes instantly on start and has nothing
        // to celebrate, so it gets no Completion screen.
        let summary = (completed && !steps.isEmpty) ? completionSummary(for: session) : nil

        resetState()
        completion = summary
    }

    /// Reads the just-finalized session's completed work. Only `StepResult`s
    /// actually marked done are counted, so skipped sets never inflate the
    /// set count and an exercise counts only when at least one of its sets
    /// was completed.
    private func completionSummary(for session: Session) -> WorkoutCompletionSummary? {
        guard let modelContext else { return nil }
        let sessionId = session.id
        let results = (try? modelContext.fetch(FetchDescriptor<StepResult>(
            predicate: #Predicate<StepResult> { $0.sessionId == sessionId }
        ))) ?? []
        return WorkoutCompletionSummary.make(
            sessionId: sessionId,
            // The stored, truncated `totalSeconds` — what History shows too.
            duration: TimeInterval(session.totalSeconds),
            results: results,
            steps: steps,
            bodyWeightKg: WorkoutCalorieEstimator.bodyWeightKg(for: session, modelContext: modelContext)
        )
    }

    private func resetState() {
        stopTimer()
        cancelRestNotification()
        invalidateAttention()
        phase = .done
        currentStepIndex = 0
        currentSetIndex = 0
        currentReps = 0
        currentWeightKg = nil
        currentDuration = DurationEntry()
        restDeadline = nil
        remainingSeconds = 0
        needsAttention = false
        sessionId = nil
        routineId = nil
        routine = nil
        steps = []
        session = nil
        lastCompletedSet = nil
        RunnerPersistence.clear(scope: scope)
    }

    private func recordStepResult(done: Bool, actualReps: Int?, weightKg: Double?, actualDurationSeconds: Int? = nil) {
        guard let modelContext, let sessionId, let step = currentStep else { return }
        // Snapshot rules (first-written planned sets, first-sibling exercise
        // identity, owner from the parent session) live in `StepResultWriter`,
        // shared with Free Workout.
        StepResultWriter.record(
            in: modelContext,
            sessionId: sessionId,
            ownerAccountID: session?.ownerAccountID,
            step: step,
            setIndex: currentSetIndex,
            done: done,
            actualReps: actualReps,
            weightKg: weightKg,
            actualDurationSeconds: actualDurationSeconds,
            plannedSets: .firstWritten
        )
    }

    private func restoredRepsForCurrentPosition() -> Int {
        guard let modelContext, let sessionId, let step = currentStep else {
            return currentStep?.repsTarget ?? 0
        }
        let stepId = step.id
        let setIndex = currentSetIndex
        let descriptor = FetchDescriptor<StepResult>(
            predicate: #Predicate<StepResult> {
                $0.sessionId == sessionId && $0.stepId == stepId && $0.setIndex == setIndex
            }
        )
        let recordedReps = (try? modelContext.fetch(descriptor).first)?.actualReps
        return max(0, recordedReps ?? step.repsTarget)
    }

    /// After moving back onto a set: a set that already has a result shows the
    /// weight recorded for it (`nil` if none); a set with no result keeps the
    /// value on screen, so going back never silently drops an entered load.
    private func restoreWeightForCurrentPosition() {
        guard let modelContext, let sessionId, let step = currentStep else { return }
        let stepId = step.id
        let setIndex = currentSetIndex
        let descriptor = FetchDescriptor<StepResult>(
            predicate: #Predicate<StepResult> {
                $0.sessionId == sessionId && $0.stepId == stepId && $0.setIndex == setIndex
            }
        )
        if let recorded = try? modelContext.fetch(descriptor).first {
            currentWeightKg = recorded.weightKg
            currentDuration = DurationEntry(totalSeconds: recorded.actualDurationSeconds)
        } else {
            currentDuration = DurationEntry()
        }
    }

    private func fetchSteps(routineId: UUID) -> [Step] {
        guard let modelContext else { return [] }
        let descriptor = FetchDescriptor<Step>(
            predicate: #Predicate<Step> { $0.routineId == routineId },
            sortBy: [SortDescriptor(\Step.order, order: .forward)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func startTimer() {
        stopTimer()
        tick()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard phase == .rest, let deadline = restDeadline else {
            remainingSeconds = 0
            return
        }
        let remaining = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
        remainingSeconds = remaining
        if remaining <= 0 {
            onRestFinished()
        }
    }

    private func onRestFinished() {
        stopTimer()
        cancelRestNotification()
        phase = .exercise
        restDeadline = nil
        signalAttentionIfNeeded()
        advanceAfterRest()
    }

    private func signalAttentionIfNeeded() {
        guard let sessionId else { return }
        attentionGeneration &+= 1
        let generation = attentionGeneration
        notificationManager.getAuthorizationStatus { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.attentionGeneration,
                      self.phase == .exercise,
                      self.sessionId == sessionId
                else { return }
                let authorized = (status == .authorized || status == .provisional)
                guard !authorized || !self.settings.notificationsEnabled else { return }

                self.needsAttention = true
                if self.settings.soundEnabled {
                    SoundHapticManager.playBeep()
                }
                if self.settings.hapticsEnabled {
                    SoundHapticManager.playHaptic()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self,
                          generation == self.attentionGeneration,
                          self.phase == .exercise,
                          self.sessionId == sessionId
                    else { return }
                    self.needsAttention = false
                }
            }
        }
    }

    private func scheduleRestNotification() {
        guard let sessionId else { return }
        cancelRestNotification(for: sessionId)
        guard settings.notificationsEnabled, restDeadline != nil else { return }
        let generation = restNotificationGeneration
        notificationManager.getAuthorizationStatus { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.restNotificationGeneration,
                      self.phase == .rest,
                      self.sessionId == sessionId,
                      let deadline = self.restDeadline,
                      deadline > Date(),
                      self.settings.notificationsEnabled,
                      status == .authorized || status == .provisional
                else { return }
                self.notificationManager.scheduleRestNotification(
                    deadline: deadline,
                    identifier: self.restNotificationIdentifier(for: sessionId)
                ) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let registrationIsCurrent =
                            generation == self.restNotificationGeneration &&
                            self.phase == .rest &&
                            self.sessionId == sessionId &&
                            self.restDeadline == deadline &&
                            self.settings.notificationsEnabled
                        guard !registrationIsCurrent else { return }

                        self.notificationManager.removeNotification(
                            identifier: self.restNotificationIdentifier(for: sessionId)
                        )
                        let newerScheduleOwnsIdentifier =
                            self.phase == .rest &&
                            self.sessionId == sessionId &&
                            self.settings.notificationsEnabled &&
                            (self.restDeadline ?? .distantPast) > Date()
                        if newerScheduleOwnsIdentifier {
                            self.scheduleRestNotification()
                        }
                    }
                }
            }
        }
    }

    private func cancelRestNotification(for sessionId: UUID? = nil) {
        restNotificationGeneration &+= 1
        guard let sessionId = sessionId ?? self.sessionId else { return }
        notificationManager.removeNotification(identifier: restNotificationIdentifier(for: sessionId))
    }

    private func invalidateCompleteContext() {
        completeGeneration &+= 1
    }

    private func restNotificationIdentifier(for sessionId: UUID) -> String {
        "rest.\(sessionId.uuidString)"
    }

    private func invalidateAttention() {
        attentionGeneration &+= 1
        needsAttention = false
    }

    private func saveState() {
        guard let sessionId, let routineId else { return }
        let state = RunnerPersistentState(
            sessionId: sessionId,
            routineId: routineId,
            phase: phase,
            stepIndex: currentStepIndex,
            setIndex: currentSetIndex,
            currentReps: currentReps,
            currentWeightKg: currentWeightKg,
            durationStepId: currentDuration == DurationEntry() ? nil : currentStep?.id,
            durationMinutes: currentDuration == DurationEntry() ? nil : currentDuration.minutes,
            durationSeconds: currentDuration == DurationEntry() ? nil : currentDuration.seconds,
            restDeadline: restDeadline,
            lastUpdatedAt: Date(),
            lastCompletedStepId: lastCompletedSet?.stepId,
            lastCompletedSetIndex: lastCompletedSet?.setIndex
        )
        RunnerPersistence.save(state, scope: scope)
    }

    private func restoreIfPossible() {
        guard let modelContext, let state = RunnerPersistence.load(scope: scope) else { return }

        let sessionDescriptor = FetchDescriptor<Session>(predicate: #Predicate<Session> { $0.id == state.sessionId })
        let routineDescriptor = FetchDescriptor<Routine>(predicate: #Predicate<Routine> { $0.id == state.routineId })

        guard let session = try? modelContext.fetch(sessionDescriptor).first,
              let routine = try? modelContext.fetch(routineDescriptor).first else {
            cancelRestNotification(for: state.sessionId)
            RunnerPersistence.clear(scope: scope)
            return
        }

        if session.status != .inProgress {
            cancelRestNotification(for: state.sessionId)
            RunnerPersistence.clear(scope: scope)
            return
        }

        // Out of scope: somebody else's workout, or ours before the account is
        // confirmed. Return without clearing — unlike a finished or deleted
        // session, this one is still resumable, just not by whoever is holding
        // the phone right now.
        guard scope.matches(ownerAccountID: session.ownerAccountID) else { return }

        self.session = session
        self.routine = routine
        self.sessionId = session.id
        self.routineId = routine.id
        self.steps = fetchSteps(routineId: routine.id)
        self.currentStepIndex = min(state.stepIndex, max(0, steps.count - 1))
        self.currentSetIndex = max(0, state.setIndex)
        self.currentReps = max(0, state.currentReps ?? currentStep?.repsTarget ?? 0)
        self.currentWeightKg = SetWeight.validated(state.currentWeightKg)
        // Only onto the step it was typed for: the saved position is the set
        // index, the step id guards against the steps having changed.
        if let stepId = state.durationStepId, stepId == currentStep?.id {
            self.currentDuration = DurationEntry(minutes: state.durationMinutes ?? "", seconds: state.durationSeconds ?? "")
        } else {
            self.currentDuration = DurationEntry()
        }
        self.phase = state.phase
        self.restDeadline = state.restDeadline
        self.remainingSeconds = 0
        // Only a target that still names a done rep-counted set of this
        // session comes back; anything else is dropped.
        if let stepId = state.lastCompletedStepId, let setIndex = state.lastCompletedSetIndex {
            self.lastCompletedSet = loadLastCompletedSet(stepId: stepId, setIndex: setIndex)
        } else {
            self.lastCompletedSet = nil
        }

        if phase == .rest {
            if let deadline = restDeadline, deadline > Date() {
                startTimer()
                scheduleRestNotification()
            } else {
                restDeadline = nil
                phase = .exercise
                cancelRestNotification(for: session.id)
                advanceAfterRest()
            }
        }
    }
}
