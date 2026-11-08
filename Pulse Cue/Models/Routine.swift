//
//  Routine.swift
//  Pulse Cue
//
//  Created by Codex.
//

import Foundation
import SwiftData

/// Why a `Routine` exists. Only `userSaved` routines appear in the routine
/// library; `workoutGenerated` ones are materialized solely to run a workout
/// (Quick Plan "この内容で開始") and stay out of the list, while remaining a
/// valid persistent target for the Runner / Session / History.
enum RoutineOrigin: String, Codable, CaseIterable, Sendable {
    case userSaved
    case workoutGenerated
}

@Model
final class Routine {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
    /// Added in schema V5. Optional on purpose: a lightweight V4 → V5
    /// migration leaves pre-existing rows with no value, and reading a
    /// non-optional enum keypath in that state fatal-crashes SwiftData
    /// (`Passed nil for a non-optional keypath \Routine.origin`). Never read
    /// this directly — go through `origin`, which maps legacy `nil` to
    /// `.userSaved`.
    var storedOrigin: RoutineOrigin?
    /// The `SavedTrainingPlan` this routine is a day of, if any (V11).
    /// Nil for every routine created outside a saved weekly plan.
    var savedTrainingPlanId: UUID?
    /// Zero-based day position inside that plan; nil when unlinked.
    var planDayIndex: Int?

    /// Effective origin. Legacy (pre-V5) rows have no stored value and are by
    /// definition library routines, so they read as `.userSaved`.
    var origin: RoutineOrigin {
        get { storedOrigin ?? .userSaved }
        set { storedOrigin = newValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isPinned: Bool = false,
        origin: RoutineOrigin = .userSaved
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        // Newly created routines always state their origin explicitly; only
        // rows written before V5 are allowed to be nil.
        self.storedOrigin = origin
    }
}

/// A weekly plan the user saved as one named unit (V11). Its days are
/// ordinary `Routine`s linked through `Routine.savedTrainingPlanId`, so the
/// Runner, editor and history keep working on them unchanged. Not owned by an
/// account and not synced, exactly like `Routine`.
@Model
final class SavedTrainingPlan {
    @Attribute(.unique) var id: UUID
    var name: String
    var goalRaw: String
    var splitRaw: String
    var daysPerWeek: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        goalRaw: String,
        splitRaw: String,
        daysPerWeek: Int,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.goalRaw = goalRaw
        self.splitRaw = splitRaw
        self.daysPerWeek = daysPerWeek
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Display copy for the stored raw values; unknown raws (a newer build's
    /// enum case) fall back to the raw string instead of crashing.
    var goalDisplayName: String { TrainingGoal(rawValue: goalRaw)?.displayName ?? goalRaw }
    var splitDisplayName: String { TrainingSplit(rawValue: splitRaw)?.displayName ?? splitRaw }
}

/// The only place that writes `SavedTrainingPlan` rows and their routine
/// links, so save / rename / delete rules live in one testable spot.
enum SavedTrainingPlanStore {

    /// e.g. "筋肥大・上下分割・週4日".
    static func defaultName(for plan: WeeklyTrainingPlanCandidate, split: TrainingSplit) -> String {
        "\(plan.goal.displayName)・\(split.displayName)・週\(plan.daysPerWeek)日"
    }

    /// Trimmed user input, or `fallback` when it is empty/whitespace.
    static func resolvedName(_ input: String, fallback: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Explicit save boundary: inserts one plan plus its routines/steps
    /// (linked, day-ordered) and commits them. Returns nil, touching nothing,
    /// when no session is savable.
    ///
    /// If `commit` throws, exactly the objects inserted here are deleted
    /// again before rethrowing, so a later autosave cannot persist a plan the
    /// user was told failed. Unrelated pending changes are left alone (no
    /// `rollback()`). `commit` is a seam for tests; production uses `save()`.
    @discardableResult
    static func save(
        _ candidate: WeeklyTrainingPlanCandidate,
        split: TrainingSplit,
        name: String,
        in context: ModelContext,
        now: Date = Date(),
        commit: (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> (plan: SavedTrainingPlan, routines: [Routine])? {
        let outputs = RoutineFactory.makeRoutines(from: candidate, now: now)
        guard !outputs.isEmpty else { return nil }
        let plan = SavedTrainingPlan(
            name: resolvedName(name, fallback: defaultName(for: candidate, split: split)),
            goalRaw: candidate.goal.rawValue,
            splitRaw: split.rawValue,
            daysPerWeek: candidate.daysPerWeek,
            createdAt: now,
            updatedAt: now
        )
        context.insert(plan)
        for (index, output) in outputs.enumerated() {
            output.routine.savedTrainingPlanId = plan.id
            output.routine.planDayIndex = index
            context.insert(output.routine)
            output.steps.forEach { context.insert($0) }
        }
        do {
            try commit(context)
        } catch {
            for output in outputs {
                output.steps.forEach { context.delete($0) }
                context.delete(output.routine)
            }
            context.delete(plan)
            throw error
        }
        return (plan, outputs.map(\.routine))
    }

    /// Renames the plan only; day routine names are untouched. Blank input
    /// keeps the current name.
    /// Renames and commits. If the commit fails, name and updatedAt are put
    /// back so a later save (autosave) cannot persist a rename the user was
    /// told had failed. Only this plan's two fields are restored — no
    /// `rollback()`, which would also discard unrelated pending edits.
    @discardableResult
    static func rename(
        _ plan: SavedTrainingPlan,
        to input: String,
        in context: ModelContext,
        now: Date = Date(),
        commit: (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> Bool {
        let name = resolvedName(input, fallback: plan.name)
        guard name != plan.name else { return false }
        let previous = (name: plan.name, updatedAt: plan.updatedAt)
        plan.name = name
        plan.updatedAt = now
        do {
            try commit(context)
        } catch {
            plan.name = previous.name
            plan.updatedAt = previous.updatedAt
            throw error
        }
        return true
    }

    /// The plan's routines in day order (index, then name for stability).
    static func routines(of plan: SavedTrainingPlan, in routines: [Routine]) -> [Routine] {
        routines
            .filter { $0.savedTrainingPlanId == plan.id }
            .sorted { ($0.planDayIndex ?? .max, $0.name) < ($1.planDayIndex ?? .max, $1.name) }
    }

    /// Deletes the plan only and commits. Its routines are unlinked and
    /// remain ordinary routines; steps/sessions/history are never touched.
    ///
    /// The work happens in a separate context on the same container, so a
    /// failed commit leaves `context` exactly as it was: nothing to restore,
    /// and no `rollback()` of unrelated pending edits. (Re-inserting a
    /// deleted-but-unsaved model does not cancel its deletion in SwiftData,
    /// so an in-place delete cannot be reliably undone.) A successful save is
    /// merged into the main context like any other store change.
    static func deletePlanKeepingRoutines(
        _ plan: SavedTrainingPlan,
        in context: ModelContext,
        commit: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        let work = ModelContext(context.container)
        work.autosaveEnabled = false
        let planId: UUID? = plan.id
        let targetId = plan.id
        let plans = try work.fetch(FetchDescriptor<SavedTrainingPlan>(
            predicate: #Predicate { $0.id == targetId }
        ))
        let linked = try work.fetch(FetchDescriptor<Routine>(
            predicate: #Predicate { $0.savedTrainingPlanId == planId }
        ))
        for routine in linked {
            routine.savedTrainingPlanId = nil
            routine.planDayIndex = nil
        }
        plans.forEach(work.delete)
        try commit(work)
    }
}
