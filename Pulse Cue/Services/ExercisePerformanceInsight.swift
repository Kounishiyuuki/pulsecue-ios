//
//  ExercisePerformanceInsight.swift
//  Pulse Cue
//
//  Read-only derivation of "what did I do last time, and what should I aim for
//  this time" from the existing History source of truth (`Session` +
//  `StepResult`). No new persisted model, no schema change, and nothing here
//  ever writes: it turns already-recorded facts into in-workout guidance.
//
//  Each completed set carries its actual reps and, since V12, the load the
//  user recorded (`StepResult.weightKg`, nil when not entered). The guidance
//  suggests a heavier load only when last time is unambiguous — same weight on
//  every set, every set at target, same set count — and otherwise falls back
//  to the reps-only rule, so pre-weight history behaves exactly as before.
//

import Foundation

/// One completed set from History. Reps and load come from the same
/// `StepResult`, so they can never drift apart set for set.
struct PreviousSetPerformance: Equatable {
    let reps: Int
    /// `nil` when no weight was recorded (including all pre-V12 history).
    let weightKg: Double?
}

/// The most recent completed performance of one exercise: each completed set,
/// in set order, plus when it happened.
struct PreviousPerformance: Equatable {
    let date: Date
    /// Completed sets in `setIndex` order. Never empty for a non-nil value.
    let sets: [PreviousSetPerformance]

    init(date: Date, sets: [PreviousSetPerformance]) {
        self.date = date
        self.sets = sets
    }

    /// Convenience for reps-only history; `setWeightsKg` is matched by index
    /// and missing entries are treated as unrecorded.
    init(date: Date, setReps: [Int], setWeightsKg: [Double?] = []) {
        self.init(date: date, sets: setReps.enumerated().map { index, reps in
            PreviousSetPerformance(
                reps: reps,
                weightKg: index < setWeightsKg.count ? setWeightsKg[index] : nil
            )
        })
    }

    var setReps: [Int] { sets.map(\.reps) }
    var setWeightsKg: [Double?] { sets.map(\.weightKg) }

    /// The single load used on every set, when there is one: every set has a
    /// recorded weight and they are all equal. Mixed or partly missing loads
    /// return `nil` — no max/average/last weight is ever picked on the user's
    /// behalf.
    var uniformWeightKg: Double? {
        guard let first = sets.first?.weightKg else { return nil }
        return sets.allSatisfy({ $0.weightKg == first }) ? first : nil
    }
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

        // `relevant` only holds results with a rep count; each set is built
        // from one result, so reps and weight cannot misalign.
        let sets: [PreviousSetPerformance] = relevant
            .filter { $0.sessionId == sessionId }
            .sorted { $0.setIndex < $1.setIndex }
            .compactMap { result in
                guard let reps = result.actualReps else { return nil }
                return PreviousSetPerformance(reps: reps, weightKg: result.weightKg)
            }
        guard !sets.isEmpty else { return nil }

        return PreviousPerformance(date: date, sets: sets)
    }
}

/// What the suggestion asks for, so the UI can say why in one line.
enum ProgressionKind: Equatable {
    /// Same weight on every set and every set at target → +`weightIncrementKg`.
    case increaseWeight
    /// Same weight on every set but not every set at target → keep it.
    case holdWeight
    /// No usable load history, every set at target → one more rep.
    case increaseReps
    /// No usable load history (or not a like-for-like session) → same target.
    case holdReps
}

/// A conservative, explainable target for this session. Never a precise
/// prescription — surfaced to the user as a "目安" they can freely override.
struct ProgressionSuggestion: Equatable {
    /// This exercise's authored rep target (`Step.repsTarget`).
    let baselineReps: Int
    /// The reps to aim for this time.
    let suggestedReps: Int
    /// The load to use this time; `nil` for a reps-only suggestion.
    var suggestedWeightKg: Double? = nil
    /// Last time's single working weight, when the suggestion is load-based.
    var previousWorkingWeightKg: Double? = nil
    var kind: ProgressionKind

    /// True when the suggestion nudges up because last time was fully achieved.
    var isProgression: Bool { kind == .increaseWeight || kind == .increaseReps }
}

enum ProgressionRule {

    /// The only load step this version suggests. One place, so a later
    /// per-exercise increment has a single seam.
    static let weightIncrementKg = 2.5

    /// Conservative guidance, explainable in one sentence:
    /// - no previous data, or a non-rep exercise (e.g. cardio) → `nil`;
    /// - last time had a different set count than `expectedSets` → hold the
    ///   rep target (not a like-for-like session, so never progress);
    /// - same positive weight on every set (and load is tracked here):
    ///   every set at target → +2.5 kg at the base reps, otherwise hold that
    ///   weight; never above `SetWeight.maximumKg` and never down (no deload);
    /// - otherwise (no / mixed / partial / 0 kg load) → the reps-only rule:
    ///   every set at target → one more rep, otherwise hold.
    static func suggest(
        previous: PreviousPerformance?,
        baselineReps: Int,
        expectedSets: Int,
        allowsRepProgression: Bool,
        allowsWeightProgression: Bool
    ) -> ProgressionSuggestion? {
        guard allowsRepProgression, baselineReps > 0, expectedSets > 0,
              let previous, !previous.sets.isEmpty else { return nil }

        let hold = ProgressionSuggestion(baselineReps: baselineReps, suggestedReps: baselineReps, kind: .holdReps)
        guard previous.sets.count == expectedSets else { return hold }

        let achievedEverySet = previous.sets.allSatisfy { $0.reps >= baselineReps }

        // 0 kg is a real record but may mean bodyweight / no added load, so it
        // never seeds a load increase.
        if allowsWeightProgression, let weight = previous.uniformWeightKg, weight > 0 {
            let next = weight + weightIncrementKg
            if achievedEverySet, next <= SetWeight.maximumKg {
                return ProgressionSuggestion(
                    baselineReps: baselineReps, suggestedReps: baselineReps,
                    suggestedWeightKg: next, previousWorkingWeightKg: weight, kind: .increaseWeight
                )
            }
            return ProgressionSuggestion(
                baselineReps: baselineReps, suggestedReps: baselineReps,
                suggestedWeightKg: weight, previousWorkingWeightKg: weight, kind: .holdWeight
            )
        }

        guard achievedEverySet else { return hold }
        return ProgressionSuggestion(baselineReps: baselineReps, suggestedReps: baselineReps + 1, kind: .increaseReps)
    }
}

/// Display strings for the Runner's 前回 / 今回の目安 card, kept pure so the
/// wording is unit-testable.
enum ProgressionPresentation {

    /// "62.5\u{00A0}kg": a load joined to its unit by a non-breaking space, so
    /// Dynamic Type wrapping never separates the number from "kg".
    static func weightText(_ kg: Double) -> String {
        "\(SetWeight.number(kg))\u{00A0}kg"
    }

    /// "60 kg × 10 / 10 / 10 回" for one load, "60 kg×10 / 57.5 kg×9" for
    /// mixed loads (a set without a load shows reps only), "10 / 10 回" when
    /// no load was recorded.
    static func previousText(_ previous: PreviousPerformance) -> String {
        let reps = previous.setReps.map(String.init).joined(separator: " / ")
        if let weight = previous.uniformWeightKg {
            return "\(weightText(weight)) × \(reps) 回"
        }
        guard previous.sets.contains(where: { $0.weightKg != nil }) else { return reps + " 回" }
        return previous.sets.map { set in
            set.weightKg.map { "\(weightText($0))×\(set.reps)" } ?? "\(set.reps)回"
        }.joined(separator: " / ")
    }

    static func suggestionText(_ s: ProgressionSuggestion) -> String {
        switch s.kind {
        case .increaseWeight, .holdWeight:
            let weight = s.suggestedWeightKg.map(weightText) ?? ""
            return "\(weight)・各セット \(s.suggestedReps) 回"
        case .increaseReps:
            return "各セット \(s.baselineReps)〜\(s.suggestedReps) 回"
        case .holdReps:
            return "各セット \(s.suggestedReps) 回"
        }
    }

    /// One short reason, only for a load increase (the case that changes the
    /// user's plan most).
    static func reasonText(_ s: ProgressionSuggestion) -> String? {
        s.kind == .increaseWeight ? "前回は同じ重量で全セット目標回数を達成" : nil
    }

    static func applyAccessibilityLabel(_ s: ProgressionSuggestion) -> String {
        s.suggestedWeightKg == nil ? "目安のレップ数を適用" : "目安の重量とレップ数を適用"
    }
}
