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
//  every set, every set at target, a known like-for-like set count — and
//  otherwise falls back to the reps-only rule, so pre-weight history behaves
//  exactly as before. Since V13 each record also knows how many sets it was
//  planned for, so a changed set count can still be judged; records without
//  that snapshot keep the pre-V13 rule.
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
    /// How many sets that session planned for this step
    /// (`StepResult.plannedSetsAtExecution`, V13+). `nil` when unknown: every
    /// pre-V13 record, and any record whose results disagree. Never derived
    /// from the live `Step.sets`, the completed count, or `setIndex`.
    let plannedSetCount: Int?
    /// The record's results carried different snapshots (impossible under the
    /// V13 write rule). Such a record is never treated as complete and never
    /// progresses, because no one value can be trusted.
    let hasInconsistentPlannedSets: Bool

    init(
        date: Date,
        sets: [PreviousSetPerformance],
        plannedSetCount: Int? = nil,
        hasInconsistentPlannedSets: Bool = false
    ) {
        self.date = date
        self.sets = sets
        self.plannedSetCount = hasInconsistentPlannedSets ? nil : plannedSetCount
        self.hasInconsistentPlannedSets = hasInconsistentPlannedSets
    }

    /// Convenience for reps-only history; `setWeightsKg` is matched by index
    /// and missing entries are treated as unrecorded.
    init(date: Date, setReps: [Int], setWeightsKg: [Double?] = [], plannedSetCount: Int? = nil) {
        self.init(date: date, sets: setReps.enumerated().map { index, reps in
            PreviousSetPerformance(
                reps: reps,
                weightKg: index < setWeightsKg.count ? setWeightsKg[index] : nil
            )
        }, plannedSetCount: plannedSetCount)
    }

    /// Whether this record is a full one. With a snapshot, against what that
    /// session planned — today's `expectedSets` is irrelevant. Without one
    /// (legacy), the pre-V13 rule: the done count equals `expectedSets`; that
    /// match says nothing about what was planned back then.
    func isComplete(expectedSets: Int) -> Bool {
        if hasInconsistentPlannedSets { return false }
        if let plannedSetCount { return sets.count == plannedSetCount }
        return sets.count == expectedSets
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

/// Which exercise one recorded (session, step) was, as executed.
///
/// `Step.exerciseId` / `Step.title` are live and change on a Runner
/// replacement or a Routine edit, so a past record must be read from the V14
/// snapshot on its results (`exerciseIdAtExecution` /
/// `exerciseTitleAtExecution`). The one place that decides between snapshot
/// and live step, so History, Progress and previous performance cannot drift:
///
/// - every result carries the same non-empty snapshot → `.snapshot`. Its id may
///   be nil (the step had no exercise id when it ran): that is a real "no id",
///   never filled in from the live step;
/// - every result is nil / nil (recorded before V14) → `.legacyFallback`: the
///   live step's values, the pre-V14 behavior — the only case that reads it;
/// - results disagree (two snapshots, or a snapshot next to nil / nil) →
///   `.inconsistent`: no exercise id and no title, so the record is never
///   counted toward any exercise — no first / latest / min pick.
struct HistoricalExerciseIdentity: Equatable {
    enum Source: Equatable { case snapshot, legacyFallback, inconsistent }

    let exerciseId: String?
    let title: String?
    let source: Source

    /// `results` are all results of one (session, step) — skipped ones too;
    /// `step` is that step if it still exists.
    static func resolve(results: [StepResult], step: Step?) -> HistoricalExerciseIdentity {
        struct Pair: Hashable { let id: String?; let title: String? }
        let pairs = Set(results.map { Pair(id: $0.exerciseIdAtExecution, title: $0.exerciseTitleAtExecution) })
        if pairs.count > 1 {
            return HistoricalExerciseIdentity(exerciseId: nil, title: nil, source: .inconsistent)
        }
        if let pair = pairs.first, pair.id != nil || pair.title != nil {
            return HistoricalExerciseIdentity(exerciseId: pair.id, title: pair.title, source: .snapshot)
        }
        return HistoricalExerciseIdentity(exerciseId: step?.exerciseId, title: step?.title, source: .legacyFallback)
    }
}

enum PreviousPerformanceQuery {

    /// The most recent performance of `exerciseId` worth calling "last time",
    /// from a session other than `excludingSessionId` (the one in progress).
    /// Matching is by stable `Step.exerciseId` — resolved through the steps
    /// that still carry it — never by display name. Only completed sets with a
    /// recorded rep count are counted. Returns `nil` when there is no such
    /// history.
    ///
    /// Selection:
    /// - `.inProgress` sessions are never "last time" (still resumable, or
    ///   left behind), so they cannot hide an earlier record;
    /// - a record is one step's sets in one session — never the sets of two
    ///   steps that share this exercise (a routine can hold a duplicated step);
    /// - a record is this exercise by what it was when it ran
    ///   (`HistoricalExerciseIdentity`), not by what its step is now — a step
    ///   replaced since keeps its old sets on the old exercise;
    /// - among `.completed` / `.abandoned` sessions, the newest complete
    ///   record wins (`PreviousPerformance.isComplete`: done count equals the
    ///   record's own planned-sets snapshot, or `expectedSets` for legacy
    ///   records) — whether the session as a whole was finished is irrelevant;
    /// - with no such full record, the newest partial one is returned (the
    ///   set-count rule then holds the target);
    /// - order: session `startedAt`, then session id; within one session, the
    ///   step whose `order` equals `currentStepOrder`, then the lowest `order`,
    ///   then step id — so the same data always yields the same record.
    ///
    /// Pure over the provided snapshots; the caller fetches them once (on
    /// workout start / exercise change), never per body render.
    static func latest(
        exerciseId: String,
        excludingSessionId: UUID?,
        expectedSets: Int,
        currentStepOrder: Int? = nil,
        steps: [Step],
        sessions: [Session],
        results: [StepResult]
    ) -> PreviousPerformance? {
        // A timed set has no rep count to show; an older one that still
        // carries reps is not shown as reps either (see `lastPerformedDate`).
        guard WorkoutSetSemantics.countsReps(exerciseId: exerciseId) else { return nil }
        let orderByStep = Dictionary(steps.map { ($0.id, $0.order) }, uniquingKeysWith: { first, _ in first })
        let stepById = Dictionary(steps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Finished (completed or ended early) sessions only.
        let finished = Dictionary(
            sessions.filter { $0.status != .inProgress }.map { ($0.id, $0.startedAt) },
            uniquingKeysWith: { first, _ in first }
        )

        struct Record: Hashable { let sessionId: UUID; let stepId: UUID }
        // Every result of each finished record — skipped ones too — so the
        // exercise identity and the planned-sets snapshot are each judged
        // across the whole record.
        let allByRecord = Dictionary(
            grouping: results.filter { $0.sessionId != excludingSessionId && finished[$0.sessionId] != nil }
        ) { Record(sessionId: $0.sessionId, stepId: $0.stepId) }
        // A record belongs to this exercise only by what it was when it ran
        // (`HistoricalExerciseIdentity`), never by what its step is now.
        var byRecord: [Record: [StepResult]] = [:]
        for (record, recordResults) in allByRecord {
            let identity = HistoricalExerciseIdentity.resolve(results: recordResults, step: stepById[record.stepId])
            guard identity.exerciseId == exerciseId else { continue }
            let sets = recordResults.filter { $0.done && $0.actualReps != nil }
            if !sets.isEmpty { byRecord[record] = sets }
        }
        guard !byRecord.isEmpty else { return nil }

        let ranked = byRecord.keys.sorted { lhs, rhs in
            let l = finished[lhs.sessionId] ?? .distantPast
            let r = finished[rhs.sessionId] ?? .distantPast
            if l != r { return l > r }
            if lhs.sessionId != rhs.sessionId { return lhs.sessionId.uuidString > rhs.sessionId.uuidString }
            let lo = orderByStep[lhs.stepId] ?? .max
            let ro = orderByStep[rhs.stepId] ?? .max
            let lMatch = currentStepOrder != nil && lo == currentStepOrder
            let rMatch = currentStepOrder != nil && ro == currentStepOrder
            if lMatch != rMatch { return lMatch }
            if lo != ro { return lo < ro }
            return lhs.stepId.uuidString < rhs.stepId.uuidString
        }
        // `byRecord` only holds results with a rep count; each set is built
        // from one result of one step, so reps and weight cannot misalign and
        // no other step's sets are mixed in.
        func performance(_ record: Record) -> PreviousPerformance? {
            guard let date = finished[record.sessionId] else { return nil }
            let results = (byRecord[record] ?? []).sorted { $0.setIndex < $1.setIndex }
            let sets: [PreviousSetPerformance] = results.compactMap { result in
                guard let reps = result.actualReps else { return nil }
                return PreviousSetPerformance(reps: reps, weightKg: result.weightKg)
            }
            guard !sets.isEmpty else { return nil }
            // One value per record by the V13 write rule, checked across every
            // result of the record (skipped sets included). All nil → legacy;
            // any disagreement (two values, or a value next to nil) → unknown,
            // never a max/min/first pick that could unlock a progression.
            let snapshots = Set((allByRecord[record] ?? results).map(\.plannedSetsAtExecution))
            let inconsistent = snapshots.count > 1
            return PreviousPerformance(
                date: date,
                sets: sets,
                plannedSetCount: inconsistent ? nil : snapshots.first ?? nil,
                hasInconsistentPlannedSets: inconsistent
            )
        }

        let candidates = ranked.compactMap(performance)
        return candidates.first { $0.isComplete(expectedSets: expectedSets) } ?? candidates.first
    }
}

extension PreviousPerformanceQuery {
    /// When `exerciseId` was last performed (a done set in a finished
    /// session), with no claim about how much. Used for timed movements,
    /// whose duration is not recorded yet, so the UI can say "実施済み"
    /// without inventing reps, time, or load.
    static func lastPerformedDate(
        exerciseId: String,
        excludingSessionId: UUID?,
        steps: [Step],
        sessions: [Session],
        results: [StepResult]
    ) -> Date? {
        let finished = Dictionary(
            sessions.filter { $0.status != .inProgress }.map { ($0.id, $0.startedAt) },
            uniquingKeysWith: { first, _ in first }
        )
        let stepById = Dictionary(steps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        struct Record: Hashable { let sessionId: UUID; let stepId: UUID }
        let byRecord = Dictionary(
            grouping: results.filter { $0.sessionId != excludingSessionId && finished[$0.sessionId] != nil }
        ) { Record(sessionId: $0.sessionId, stepId: $0.stepId) }
        return byRecord.compactMap { record, recordResults -> Date? in
            guard recordResults.contains(where: \.done),
                  HistoricalExerciseIdentity.resolve(results: recordResults, step: stepById[record.stepId]).exerciseId == exerciseId
            else { return nil }
            return finished[record.sessionId]
        }.max()
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
    /// Last time's planned set count, set only when it is known (V13
    /// snapshot, complete record) and differs from `expectedSetCount`, so the
    /// reason line can say the set count changed. Display-only, never stored.
    var previousSetCount: Int? = nil
    var expectedSetCount: Int? = nil
    /// Whether every one of last time's sets reached the rep target; set
    /// together with `previousSetCount`, so a hold after fewer sets can say
    /// "未達" only when there really was a miss (not at the load ceiling).
    var previousAchievedEverySet: Bool? = nil

    /// True when the suggestion nudges up because last time was fully achieved.
    var isProgression: Bool { kind == .increaseWeight || kind == .increaseReps }
}

enum ProgressionRule {

    /// The only load step this version suggests. One place, so a later
    /// per-exercise increment has a single seam.
    static let weightIncrementKg = 2.5

    /// Conservative guidance, explainable in one sentence. With `p` the
    /// planned set count last time and `e` = `expectedSets`:
    /// - no previous data, or a non-rep exercise (e.g. cardio) → `nil`;
    /// - snapshot known (V13+), record complete:
    ///   - `p >= e`: judge every one of last time's `p` sets (never only the
    ///     first `e`) with the like-for-like rule below;
    ///   - `p < e`: more sets is already the increase → hold weight / reps;
    /// - snapshot known but record partial, or snapshots inconsistent → hold
    ///   (weight if a single positive one is clear, else reps), never up;
    /// - legacy (no snapshot): last time's done count differs from
    ///   `expectedSets` → hold the rep target, otherwise the like-for-like rule;
    /// - like-for-like rule: same positive weight on every set (and load is
    ///   tracked here): every set at target → +2.5 kg at the base reps,
    ///   otherwise hold that weight; never above `SetWeight.maximumKg` and
    ///   never down (no deload). Otherwise (no / mixed / partial / 0 kg load)
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

        let holdReps = ProgressionSuggestion(baselineReps: baselineReps, suggestedReps: baselineReps, kind: .holdReps)
        // 0 kg is a real record but may mean bodyweight / no added load, so it
        // never seeds a load suggestion.
        let loadWeight: Double? = allowsWeightProgression
            ? previous.uniformWeightKg.flatMap { $0 > 0 ? $0 : nil }
            : nil
        func hold() -> ProgressionSuggestion {
            guard let weight = loadWeight else { return holdReps }
            return ProgressionSuggestion(
                baselineReps: baselineReps, suggestedReps: baselineReps,
                suggestedWeightKg: weight, previousWorkingWeightKg: weight, kind: .holdWeight
            )
        }

        if previous.hasInconsistentPlannedSets { return hold() }

        guard let planned = previous.plannedSetCount else {
            // Legacy: what was planned is unknown, so only an equal done count
            // is like-for-like.
            guard previous.sets.count == expectedSets else { return holdReps }
            return likeForLike(previous, loadWeight: loadWeight, baselineReps: baselineReps, hold: hold())
        }

        guard previous.sets.count == planned else { return hold() }

        var suggestion = planned < expectedSets
            ? hold()
            : likeForLike(previous, loadWeight: loadWeight, baselineReps: baselineReps, hold: hold())
        if planned != expectedSets {
            suggestion.previousSetCount = planned
            suggestion.expectedSetCount = expectedSets
            suggestion.previousAchievedEverySet = previous.sets.allSatisfy { $0.reps >= baselineReps }
        }
        return suggestion
    }

    /// Every one of last time's sets counts: one miss anywhere holds.
    private static func likeForLike(
        _ previous: PreviousPerformance,
        loadWeight: Double?,
        baselineReps: Int,
        hold: ProgressionSuggestion
    ) -> ProgressionSuggestion {
        guard previous.sets.allSatisfy({ $0.reps >= baselineReps }) else { return hold }
        if let weight = loadWeight {
            let next = weight + weightIncrementKg
            guard next <= SetWeight.maximumKg else { return hold }
            return ProgressionSuggestion(
                baselineReps: baselineReps, suggestedReps: baselineReps,
                suggestedWeightKg: next, previousWorkingWeightKg: weight, kind: .increaseWeight
            )
        }
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
    /// Previous-performance line of a timed movement: that it was done, only.
    static let performedText = "実施済み"

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

    /// One short reason: for a load increase (the case that changes the
    /// user's plan most), and whenever the set count changed since last time
    /// (so a hold after adding sets is not a mystery).
    static func reasonText(_ s: ProgressionSuggestion) -> String? {
        if let p = s.previousSetCount, let e = s.expectedSetCount, p != e {
            switch s.kind {
            case .increaseWeight, .increaseReps:
                return "前回は\(p)セットをすべて達成。今回は\(e)セット"
            case .holdWeight, .holdReps:
                let keep = s.kind == .holdWeight ? "重量を維持" : "回数を維持"
                if p < e { return "前回は\(p)セット、今回は\(e)セットのため\(keep)" }
                if s.previousAchievedEverySet == false {
                    return "前回は\(p)セット中に未達あり。今回は\(e)セットのため\(keep)"
                }
                return "前回は\(p)セット、今回は\(e)セット"
            }
        }
        return s.kind == .increaseWeight ? "前回は同じ重量で全セット目標回数を達成" : nil
    }

    static func applyAccessibilityLabel(_ s: ProgressionSuggestion) -> String {
        s.suggestedWeightKg == nil ? "目安のレップ数を適用" : "目安の重量とレップ数を適用"
    }
}
