//
//  RunnerPresenter.swift
//  Pulse Cue
//
//  UI-presentation state for the Runner full-screen cover, kept *separate*
//  from the workout's domain state (`RunnerViewModel.isRunning`).
//
//  Contract:
//   - The workout itself is owned solely by RunnerViewModel. This type never
//     starts, ends, or mutates a session — it only decides whether the cover
//     is on screen.
//   - `syncPresentation(shouldPresent:)` mirrors the domain state: a workout
//     becoming active presents the cover; it stays presented while a finished
//     workout's Completion summary is still showing, and is dismissed once
//     neither holds. ContentView calls this on every
//     `RunnerViewModel.shouldPresentRunner` change and once at launch (so a
//     session recovered from disk re-presents its Runner).
//   - `resume(isRunning:)` is the explicit "ワークアウトを再開" path: it
//     re-presents the cover for an *already active* workout WITHOUT touching
//     domain state, so no new Session is ever created. When nothing is
//     running it is a no-op (never presents an empty Runner).
//
//  Because the cover is bound to `isRunnerCovered` and marked
//  `.interactiveDismissDisabled` while active, presentation cannot silently
//  desync from an active workout.
//

import Foundation
import Combine
import SwiftData

@MainActor
final class RunnerPresenter: ObservableObject {
    /// Whether the Runner full-screen cover is currently shown.
    @Published var isRunnerCovered: Bool = false

    /// Mirror the authoritative workout state onto presentation.
    func syncPresentation(shouldPresent: Bool) {
        isRunnerCovered = shouldPresent
    }

    /// Explicit user-initiated resume. Only re-presents an existing active
    /// workout; creates/mutates nothing. No-op when nothing is running.
    func resume(isRunning: Bool) {
        guard isRunning else { return }
        isRunnerCovered = true
    }
}

// MARK: - Free Workout
//
// Kept in this file only because a new file would need a project.pbxproj
// change; they belong in their own FreeWorkout*.swift files.

/// Home / Training's Free Workout entry: start, or resume / discard what is
/// already in progress. Every decision is the domain's
/// (`FreeWorkoutSession.start`, `FreeWorkoutRecovery`); this holds UI state.
@MainActor
final class FreeWorkoutLauncher: ObservableObject {

    enum Notice: Equatable {
        /// The data scope is not known yet, so nothing may start.
        case scopeUndetermined
        /// The workout was finished with nothing performed: not saved.
        case nothingSaved
    }

    @Published private(set) var candidates: [FreeWorkoutRecovery.Candidate] = []
    /// The open workout screen, when there is one.
    @Published var presented: FreeWorkoutViewModel?
    @Published var notice: Notice?
    /// Set while an action runs, so its button can be disabled. Not what
    /// makes it safe — the domain refuses doubles on its own.
    @Published private(set) var isBusy = false

    private var context: ModelContext?
    private var scope: WorkoutDataScope = .undetermined
    private let drafts: FreeWorkoutDraftStore

    /// `drafts` is shared by Home's and Training's cards so a workout left
    /// from one and resumed from the other keeps its typed values.
    init(drafts: FreeWorkoutDraftStore? = nil) {
        self.drafts = drafts ?? .shared
    }

    func configure(context: ModelContext, scope: WorkoutDataScope) {
        self.context = context
        self.scope = scope
        refresh()
    }

    func refresh() {
        guard let context else { return }
        candidates = FreeWorkoutRecovery.candidates(in: context, scope: scope)
        // Drafts of this scope's workouts that are no longer in progress —
        // finished or discarded elsewhere — are dropped; the open one always
        // stays, and other owners' drafts are not this scope's to judge.
        drafts.prune(in: scope, keeping: Set(candidates.map(\.id)).union(presented.map { [$0.id] } ?? []))
    }

    func start(now: Date = Date()) {
        guard let context, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        switch FreeWorkoutSession.start(in: context, scope: scope, now: now) {
        case let .started(session):
            try? context.save()
            open(session, context: context)
        case let .activeWorkoutExists(existing):
            // Nothing created: the card now offers 再開 / 破棄 for these.
            candidates = existing
        case .scopeUndetermined:
            notice = .scopeUndetermined
        }
    }

    func resume(_ candidate: FreeWorkoutRecovery.Candidate) {
        guard let context, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        if let session = FreeWorkoutRecovery.resume(candidate, in: context, scope: scope) {
            open(session, context: context)
        }
        refresh()
    }

    func discard(_ candidate: FreeWorkoutRecovery.Candidate) {
        guard let context, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        if FreeWorkoutRecovery.discard(candidate, in: context, scope: scope) {
            drafts.clear(candidate.id)
            try? context.save()
        }
        refresh()
    }

    /// The workout screen closed — finished, discarded or just left.
    func workoutScreenClosed() {
        if presented?.finishOutcome == .discarded { notice = .nothingSaved }
        presented = nil
        refresh()
    }

    private func open(_ session: FreeWorkoutSession, context: ModelContext) {
        presented = FreeWorkoutViewModel(session: session, context: context, drafts: drafts)
    }
}

/// Values typed into set rows not yet logged, per workout, for the life of
/// the process only.
///
/// Closing the workout screen and resuming it keeps them; a relaunch loses
/// them by design — they are never persisted (a blank row is an input field,
/// not a set), and the row count and logged sets come back from the store.
/// Keyed by session so two leftover workouts never share a draft.
@MainActor
final class FreeWorkoutDraftStore {
    static let shared = FreeWorkoutDraftStore()

    struct Draft: Equatable {
        var weightKg: Double?
        var reps: Int
        /// Touched by the user: never replaced by a fresher default.
        var edited: Bool
    }

    private struct Entry {
        let ownerAccountID: UUID?
        var drafts: [FreeWorkoutViewModel.RowKey: Draft]
    }

    private var bySession: [UUID: Entry] = [:]

    var sessionIds: Set<UUID> { Set(bySession.keys) }

    func drafts(for sessionId: UUID) -> [FreeWorkoutViewModel.RowKey: Draft] {
        bySession[sessionId]?.drafts ?? [:]
    }

    func set(_ drafts: [FreeWorkoutViewModel.RowKey: Draft], for sessionId: UUID, ownerAccountID: UUID?) {
        bySession[sessionId] = drafts.isEmpty ? nil : Entry(ownerAccountID: ownerAccountID, drafts: drafts)
    }

    func clear(_ sessionId: UUID) {
        bySession[sessionId] = nil
    }

    /// Drops `scope`'s entries not in `sessionIds`. Entries of other owners
    /// are left alone — an account switch must not erase their drafts.
    func prune(in scope: WorkoutDataScope, keeping sessionIds: Set<UUID>) {
        bySession = bySession.filter { id, entry in
            sessionIds.contains(id) || !scope.matches(ownerAccountID: entry.ownerAccountID)
        }
    }
}

/// The Free Workout screen's state. Exercises and sets come from the store
/// through `FreeWorkoutSession`; the only thing held here is the *draft* of
/// rows not yet logged — values typed into a row before ✓ or Skip, which by
/// design are not persisted (a blank row is an input field, not a set).
@MainActor
final class FreeWorkoutViewModel: ObservableObject, Identifiable {

    struct RowKey: Hashable {
        let stepId: UUID
        let setIndex: Int
    }

    struct SetRow: Identifiable, Equatable {
        enum State: Equatable { case draft, done, skipped }
        let key: RowKey
        var id: RowKey { key }
        var number: Int { key.setIndex + 1 }
        let state: State
        let weightKg: Double?
        let reps: Int
    }

    struct ExerciseCard: Identifiable, Equatable {
        let id: UUID
        let title: String
        let acceptsWeight: Bool
        let previousText: String?
        let rows: [SetRow]
        let canRemove: Bool
        let canAddSet: Bool
    }

    private typealias Draft = FreeWorkoutDraftStore.Draft

    let session: FreeWorkoutSession
    nonisolated let id: UUID
    private let context: ModelContext

    @Published private(set) var cards: [ExerciseCard] = []
    /// The row the editor below the list works on.
    @Published var selected: RowKey?
    @Published private(set) var finishOutcome: FreeWorkoutSession.FinishOutcome?
    @Published private(set) var completion: WorkoutCompletionSummary?

    private let draftStore: FreeWorkoutDraftStore
    /// This workout's drafts, kept in the process-wide store so they outlive
    /// this screen (see `FreeWorkoutDraftStore`).
    private var drafts: [RowKey: Draft] {
        get { draftStore.drafts(for: id) }
        set { draftStore.set(newValue, for: id, ownerAccountID: session.session.ownerAccountID) }
    }
    private var previousTextByStep: [UUID: String?] = [:]

    init(session: FreeWorkoutSession, context: ModelContext, drafts: FreeWorkoutDraftStore) {
        self.session = session
        self.id = session.session.id
        self.context = context
        self.draftStore = drafts
        // Only what the user typed survives a reopen; untouched defaults are
        // recomputed from the store as it is now.
        self.drafts = self.drafts.filter(\.value.edited)
        rebuild()
        selected = firstOpenRow()
    }

    var startedAt: Date { session.session.startedAt }

    func elapsedText(now: Date) -> String {
        DateUtils.formatDuration(seconds: session.elapsedSeconds(now: now))
    }

    // MARK: Exercises

    func addExercise(_ exercise: Exercise) {
        guard let step = session.addExercise(exercise) else { return }
        saveAndRebuild(select: RowKey(stepId: step.id, setIndex: 0))
    }

    /// A custom machine: no catalogue id, so no previous performance.
    func addExercise(exerciseId: String?, title: String) {
        guard let step = session.addExercise(exerciseId: exerciseId, title: title) else { return }
        saveAndRebuild(select: RowKey(stepId: step.id, setIndex: 0))
    }

    func removeExercise(_ stepId: UUID) {
        guard let step = step(stepId), session.removeExercise(step) else { return }
        drafts = drafts.filter { $0.key.stepId != stepId }
        saveAndRebuild(select: selected?.stepId == stepId ? nil : selected)
    }

    func moveExercises(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard source.count == 1, let from = source.first else { return }
        // `onMove` gives the index *before* removal; the domain wants it after.
        let to = destination > from ? destination - 1 : destination
        guard from != to, session.moveExercise(from: from, to: to) else { return }
        saveAndRebuild(select: selected)
    }

    // MARK: Sets

    func addSet(to stepId: UUID) {
        guard let step = step(stepId), session.addSet(to: step) else { return }
        saveAndRebuild(select: RowKey(stepId: stepId, setIndex: step.sets - 1))
    }

    func removeSet(_ key: RowKey) {
        guard let step = step(key.stepId), session.removeSet(at: key.setIndex, from: step) else { return }
        // Later rows shifted down one; so do their drafts.
        var shifted: [RowKey: Draft] = [:]
        for (rowKey, draft) in drafts {
            guard rowKey.stepId == key.stepId else { shifted[rowKey] = draft; continue }
            if rowKey.setIndex < key.setIndex { shifted[rowKey] = draft }
            if rowKey.setIndex > key.setIndex { shifted[RowKey(stepId: rowKey.stepId, setIndex: rowKey.setIndex - 1)] = draft }
        }
        drafts = shifted
        saveAndRebuild(select: nil)
    }

    // MARK: Editing the selected row

    /// Tapping the selected row again closes its editor.
    func select(_ key: RowKey) {
        selected = selected == key ? nil : key
    }

    func adjustWeight(by delta: Double, for key: RowKey) {
        let current = row(key)?.weightKg ?? 0
        setWeight(current + delta, for: key)
    }

    /// Invalid values (negative, over the maximum) are ignored; nil clears.
    func setWeight(_ kg: Double?, for key: RowKey) {
        guard let row = row(key) else { return }
        if let kg, SetWeight.validated(kg) == nil { return }
        let value = kg.flatMap(SetWeight.validated)
        edit(key, row: row) { $0.weightKg = value }
    }

    func adjustReps(by delta: Int, for key: RowKey) {
        guard let row = row(key) else { return }
        setReps(row.reps + delta, for: key)
    }

    func setReps(_ reps: Int, for key: RowKey) {
        guard let row = row(key) else { return }
        edit(key, row: row) { $0.reps = max(0, reps) }
    }

    /// A logged row is re-recorded at once — the writer overwrites in place,
    /// keeping its snapshots. A draft row only changes its draft.
    private func edit(_ key: RowKey, row: SetRow, _ change: (inout Draft) -> Void) {
        var draft = drafts[key] ?? Draft(weightKg: row.weightKg, reps: row.reps, edited: false)
        change(&draft)
        draft.edited = true
        switch row.state {
        case .draft:
            drafts[key] = draft
            rebuild()
        case .done:
            guard let step = step(key.stepId) else { return }
            session.completeSet(at: key.setIndex, of: step, reps: draft.reps, weightKg: weight(draft.weightKg, step: step))
            saveAndRebuild(select: key)
        case .skipped:
            drafts[key] = draft
            rebuild()
        }
    }

    func complete(_ key: RowKey) {
        guard let step = step(key.stepId), let row = row(key) else { return }
        guard session.completeSet(at: key.setIndex, of: step, reps: row.reps, weightKg: weight(row.weightKg, step: step)) != nil
        else { return }
        drafts[key] = nil
        // Untouched drafts below now default from this set.
        drafts = drafts.filter { !($0.key.stepId == key.stepId && $0.key.setIndex > key.setIndex && !$0.value.edited) }
        saveAndRebuild(select: nextOpenRow(after: key))
    }

    func skip(_ key: RowKey) {
        guard let step = step(key.stepId), session.skipSet(at: key.setIndex, of: step) != nil else { return }
        drafts[key] = nil
        saveAndRebuild(select: nextOpenRow(after: key))
    }

    // MARK: Finish / discard

    /// Ends the workout. Saved → a completion summary to show; nothing
    /// performed → discarded by the domain.
    func finish(now: Date = Date()) {
        let outcome = session.finish(now: now)
        finishOutcome = outcome
        if outcome != .notActive { draftStore.clear(id) }
        guard outcome == .saved else { try? context.save(); return }
        let done = session.steps.flatMap { session.results(for: $0) }.filter(\.done)
        completion = WorkoutCompletionSummary(
            sessionId: session.session.id,
            duration: TimeInterval(session.session.totalSeconds),
            completedExerciseCount: Set(done.map(\.stepId)).count,
            completedSetCount: done.count
        )
        try? context.save()
    }

    func discard() {
        if session.discard() {
            finishOutcome = .discarded
            draftStore.clear(id)
        }
        try? context.save()
    }

    // MARK: Rows

    func row(_ key: RowKey) -> SetRow? {
        cards.first { $0.id == key.stepId }?.rows.first { $0.key == key }
    }

    private func rebuild() {
        cards = session.steps.map { step in
            let results = Dictionary(session.results(for: step).map { ($0.setIndex, $0) }, uniquingKeysWith: { first, _ in first })
            let rows = (0..<step.sets).map { index -> SetRow in
                let key = RowKey(stepId: step.id, setIndex: index)
                if let result = results[index] {
                    // An edited skip keeps its typed values until ✓.
                    if !result.done, let draft = drafts[key] {
                        return SetRow(key: key, state: .skipped, weightKg: draft.weightKg, reps: draft.reps)
                    }
                    return SetRow(key: key, state: result.done ? .done : .skipped,
                                  weightKg: result.weightKg, reps: result.actualReps ?? step.repsTarget)
                }
                let draft = drafts[key] ?? {
                    let entry = session.initialEntry(forSetAt: index, of: step)
                    return Draft(weightKg: entry.weightKg, reps: entry.reps, edited: false)
                }()
                drafts[key] = draft
                return SetRow(key: key, state: .draft, weightKg: draft.weightKg, reps: draft.reps)
            }
            return ExerciseCard(
                id: step.id,
                title: step.title,
                acceptsWeight: acceptsWeight(step),
                previousText: previousText(for: step),
                rows: rows,
                canRemove: session.canRemoveExercise(step),
                canAddSet: Step.clampSets(step.sets + 1) > step.sets
            )
        }
    }

    private func saveAndRebuild(select key: RowKey?) {
        try? context.save()
        rebuild()
        selected = key.flatMap { row($0) != nil ? $0 : nil } ?? firstOpenRow()
    }

    private func firstOpenRow() -> RowKey? {
        cards.lazy.flatMap(\.rows).first { $0.state == .draft }?.key
    }

    private func nextOpenRow(after key: RowKey) -> RowKey? {
        cards.first { $0.id == key.stepId }?.rows.first { $0.key.setIndex > key.setIndex && $0.state == .draft }?.key
            ?? firstOpenRow()
    }

    private func step(_ id: UUID) -> Step? { session.steps.first { $0.id == id } }

    private func previousText(for step: Step) -> String? {
        if let cached = previousTextByStep[step.id] { return cached }
        let text = session.previousPerformance(for: step).map(ProgressionPresentation.previousText)
        previousTextByStep[step.id] = text
        return text
    }

    /// Same rule as the Runner: timed or cardio movements take no load;
    /// custom / unknown exercises do.
    private func acceptsWeight(_ step: Step) -> Bool {
        guard let id = step.exerciseId, let exercise = ExerciseLibrary.exercise(for: ExerciseID(rawValue: id)) else { return true }
        return !exercise.isDurationBased && exercise.movementPattern != .cardio
    }

    private func weight(_ kg: Double?, step: Step) -> Double? {
        acceptsWeight(step) ? kg : nil
    }
}
