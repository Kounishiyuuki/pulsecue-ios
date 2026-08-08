//
//  ExercisePerformanceInsight.swift
//  Pulse Cue
//
//  Read-only derivation of "what did I do last time, and what should I aim for
//  this time" from the existing History source of truth (`Session` +
//  `StepResult`). No new persisted model, no schema change, and nothing here
//  ever writes: it turns already-recorded facts into in-workout guidance.
//
//  Weight / load is not stored anywhere in the app today, so the insight is
//  reps-based: previous actual reps per completed set, and a conservative
//  reps target for this time.
//

import Foundation

/// The most recent completed performance of one exercise: the reps actually
/// done on each completed set, in set order, plus when it happened.
struct PreviousPerformance: Equatable {
    let date: Date
    /// Completed-set reps, in `setIndex` order. Never empty for a non-nil value.
    let setReps: [Int]
}

enum PreviousPerformanceQuery {

    /// The most recent completed performance of `exerciseId`, from a session
    /// other than `excludingSessionId` (the one in progress). Matching is by
    /// stable `Step.exerciseId` — resolved through the steps that still carry
    /// it — never by display name. Only completed sets with a recorded rep
    /// count are counted. Returns `nil` when there is no such history.
    ///
    /// Pure over the provided snapshots; the caller fetches them once (on
    /// workout start / exercise change), never per body render.
    static func latest(
        exerciseId: String,
        excludingSessionId: UUID?,
        steps: [Step],
        sessions: [Session],
        results: [StepResult]
    ) -> PreviousPerformance? {
        // Every step (across routines) that represents this exercise.
        let stepIds = Set(steps.filter { $0.exerciseId == exerciseId }.map(\.id))
        guard !stepIds.isEmpty else { return nil }

        let relevant = results.filter { result in
            result.done
                && result.actualReps != nil
                && result.sessionId != excludingSessionId
                && stepIds.contains(result.stepId)
        }
        guard !relevant.isEmpty else { return nil }

        let dateBySession = Dictionary(sessions.map { ($0.id, $0.startedAt) }, uniquingKeysWith: { first, _ in first })

        // Most recent session that has a completed set of this exercise.
        // Tie-break on session id so the result is fully deterministic.
        let sessionIds = Set(relevant.map(\.sessionId))
        let latest = sessionIds.max { lhs, rhs in
            let l = dateBySession[lhs] ?? .distantPast
            let r = dateBySession[rhs] ?? .distantPast
            if l != r { return l < r }
            return lhs.uuidString < rhs.uuidString
        }
        guard let sessionId = latest, let date = dateBySession[sessionId] else { return nil }

        let setReps = relevant
            .filter { $0.sessionId == sessionId }
            .sorted { $0.setIndex < $1.setIndex }
            .compactMap(\.actualReps)
        guard !setReps.isEmpty else { return nil }

        return PreviousPerformance(date: date, setReps: setReps)
    }
}

/// A conservative, explainable reps target for this session. Never a precise
/// prescription — surfaced to the user as a "目安" they can freely override.
struct ProgressionSuggestion: Equatable {
    /// This exercise's authored rep target (`Step.repsTarget`).
    let baselineReps: Int
    /// The reps to aim for this time: `baselineReps`, or `baselineReps + 1`
    /// when every set hit the target last time.
    let suggestedReps: Int

    /// True when the suggestion nudges up because last time was fully achieved.
    var isProgression: Bool { suggestedReps > baselineReps }
}

enum ProgressionRule {

    /// Conservative reps guidance:
    /// - no previous data → `nil` (nothing to suggest),
    /// - a non-rep exercise (e.g. cardio) → `nil` (rep progression makes no sense),
    /// - every set hit the target last time → aim for one more rep,
    /// - otherwise → hold the same target.
    ///
    /// Weight is never suggested (it is not tracked), so a "safe increment" is
    /// never invented.
    static func suggest(
        previous: PreviousPerformance?,
        baselineReps: Int,
        allowsRepProgression: Bool
    ) -> ProgressionSuggestion? {
        guard allowsRepProgression, baselineReps > 0,
              let previous, !previous.setReps.isEmpty else { return nil }

        let achievedEverySet = previous.setReps.allSatisfy { $0 >= baselineReps }
        let suggested = achievedEverySet ? baselineReps + 1 : baselineReps
        return ProgressionSuggestion(baselineReps: baselineReps, suggestedReps: suggested)
    }
}
