//
//  StepResult.swift
//  Pulse Cue
//
//  Created by Codex.
//

import Foundation
import SwiftData

@Model
final class StepResult {
    @Attribute(.unique) var id: UUID
    var sessionId: UUID
    var stepId: UUID
    var setIndex: Int
    var done: Bool
    var actualReps: Int?
    var memo: String?
    /// Sync owner, mirroring `Session.ownerAccountID` for the parent session.
    ///
    /// The truth lives on the session; it is duplicated here because the
    /// server's `step_results` row carries `user_id` of its own (composite key
    /// `(user_id, id)`, composite FK `(user_id, session_id)`), and because
    /// there is no SwiftData relationship to traverse — `sessionId` is a plain
    /// UUID. `AccountScopedSyncStore` is the only writer, and it never leaves
    /// a result owned by an account other than its session's.
    var ownerAccountID: UUID?
    /// Load actually used for this set, in kilograms (schema V12+). `nil` means
    /// not recorded — every pre-V12 result, skipped sets, and sets the user
    /// left blank. `0` is a real value ("no added load"), never a stand-in for
    /// "unknown". Not the body weight on `DayLog.weightKg`.
    var weightKg: Double?
    /// How many sets this step was planned for when this session ran it
    /// (schema V13+). `Step.sets` is the live, editable value, so it cannot
    /// say what an earlier session planned. Every result of one
    /// (session, step) carries the same value: the first one written takes
    /// `step.sets`, later ones copy it. `nil` for every pre-V13 result —
    /// unknown, and never backfilled or guessed.
    var plannedSetsAtExecution: Int?
    /// The exercise this step was when this session ran it (schema V14+):
    /// `Step.exerciseId` / `Step.title` are live and change on a Runner
    /// replacement or a Routine edit, so they cannot say what an earlier
    /// session did. Same rule as `plannedSetsAtExecution`: the first result of
    /// one (session, step) takes the step's values, later ones copy them, and
    /// an existing result's values are never rewritten. `nil` for every
    /// pre-V14 result — unknown, never backfilled from the live step.
    var exerciseIdAtExecution: String?
    var exerciseTitleAtExecution: String?
    /// How long a done set of a timed exercise actually ran, in seconds
    /// (schema V15+). Always > 0 when present; `nil` for every other set, and
    /// for every timed set recorded before V15 or without a duration — such a
    /// set still reads as "実施済み", never as a guessed time.
    var actualDurationSeconds: Int?
    /// Reps in reserve (RIR) the user reported for a done rep-counted set
    /// (schema V16+): 0...4, where 4 means "4+". `nil` means not recorded —
    /// every pre-V16 result, skipped sets, timed sets, and sets the user left
    /// blank — never a guessed value. Not required to complete a set; set
    /// only through `StepResultWriter.recordRepsInReserve`.
    var repsInReserve: Int?

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        stepId: UUID,
        setIndex: Int,
        done: Bool,
        actualReps: Int? = nil,
        memo: String? = nil,
        ownerAccountID: UUID? = nil,
        weightKg: Double? = nil,
        plannedSetsAtExecution: Int? = nil,
        exerciseIdAtExecution: String? = nil,
        exerciseTitleAtExecution: String? = nil,
        actualDurationSeconds: Int? = nil,
        repsInReserve: Int? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.stepId = stepId
        self.setIndex = setIndex
        self.done = done
        self.actualReps = actualReps
        self.memo = memo
        self.ownerAccountID = ownerAccountID
        self.weightKg = weightKg
        self.plannedSetsAtExecution = plannedSetsAtExecution
        self.exerciseIdAtExecution = exerciseIdAtExecution
        self.exerciseTitleAtExecution = exerciseTitleAtExecution
        self.actualDurationSeconds = actualDurationSeconds
        self.repsInReserve = repsInReserve
    }
}

/// Validation for a set's reps in reserve.
enum RepsInReserve {
    /// 0...4; the top value reads as "4+". Anything outside is rejected, never
    /// clamped: 5 is not stored as 4.
    static let range = 0...4

    /// `nil` (clearing it) is always acceptable.
    static func isValid(_ value: Int?) -> Bool {
        guard let value else { return true }
        return range.contains(value)
    }

    /// A stored value as shown: "2", and the top of the range as "4+".
    static func valueText(_ value: Int) -> String {
        value >= range.upperBound ? "\(range.upperBound)+" : "\(value)"
    }

    /// A stored value as read by VoiceOver: "2", and the top as "4以上".
    static func spokenValueText(_ value: Int) -> String {
        value >= range.upperBound ? "\(range.upperBound)以上" : "\(value)"
    }

    /// "RIR 2" / "RIR 4+" for one set.
    static func displayText(_ value: Int) -> String { "RIR \(valueText(value))" }

    /// "RIR 2" / "RIR 4以上" for one set.
    static func spokenText(_ value: Int) -> String { "RIR \(spokenValueText(value))" }
}

/// Validation and display for a timed set's actual duration.
enum SetDuration {
    /// Only a positive number of seconds is a duration; 0 or less is no
    /// recording at all.
    static func validated(_ seconds: Int?) -> Int? {
        guard let seconds, seconds > 0 else { return nil }
        return seconds
    }

    /// "30秒", "1分", "1分30秒", "12分30秒", "1時間", "1時間1分5秒" — zero
    /// parts omitted. Also read as is by VoiceOver. Not `DateUtils.formatDuration`
    /// ("12:30"), which is the session clock: a set's time reads as an amount.
    static func text(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours)時間") }
        if minutes > 0 { parts.append("\(minutes)分") }
        if secs > 0 || parts.isEmpty { parts.append("\(secs)秒") }
        return parts.joined()
    }
}

/// A timed set's duration as typed: minutes and seconds kept as entered, so
/// an out-of-range value is shown back with its reason instead of being
/// silently corrected — 90 seconds is never turned into 59 or into 1:30.
/// Both empty is "not entered yet": a new set has no fake default.
struct DurationEntry: Equatable {
    /// 24 hours: anything longer is a typo, not a set.
    static let maximumMinutes = 24 * 60

    enum Issue: Equatable {
        case empty, invalidMinutes, invalidSeconds, zero

        /// Why the set cannot be completed yet, in one line.
        var message: String {
            switch self {
            case .empty: return "時間を入力してください"
            case .invalidMinutes: return "分は0〜\(DurationEntry.maximumMinutes)で入力してください"
            case .invalidSeconds: return "秒は0〜59で入力してください"
            case .zero: return "0秒より長い時間を入力してください"
            }
        }
    }

    var minutes: String = ""
    var seconds: String = ""

    init(minutes: String = "", seconds: String = "") {
        self.minutes = minutes
        self.seconds = seconds
    }

    /// A recorded duration, shown as whole minutes and remaining seconds.
    init(totalSeconds: Int?) {
        guard let total = SetDuration.validated(totalSeconds) else { return }
        minutes = "\(total / 60)"
        seconds = total % 60 == 0 ? "" : "\(total % 60)"
    }

    var issue: Issue? {
        let m = minutes.trimmingCharacters(in: .whitespaces)
        let s = seconds.trimmingCharacters(in: .whitespaces)
        if m.isEmpty && s.isEmpty { return .empty }
        guard let mins = m.isEmpty ? 0 : Self.number(m), mins <= Self.maximumMinutes else { return .invalidMinutes }
        guard let secs = s.isEmpty ? 0 : Self.number(s), secs <= 59 else { return .invalidSeconds }
        return mins * 60 + secs > 0 ? nil : .zero
    }

    /// The duration in seconds, or nil while `issue` is not nil.
    var totalSeconds: Int? {
        guard issue == nil else { return nil }
        let m = minutes.trimmingCharacters(in: .whitespaces), s = seconds.trimmingCharacters(in: .whitespaces)
        return (Self.number(m) ?? 0) * 60 + (Self.number(s) ?? 0)
    }

    /// −1分 / +1分: whole minutes, never below 0, seconds untouched. Empty
    /// minutes count as 0. Minutes that cannot be read, or are already past
    /// the maximum, are left exactly as typed — the step does nothing rather
    /// than replace them, so the validation message stays true.
    func adjustingMinutes(by delta: Int) -> DurationEntry {
        let typed = minutes.trimmingCharacters(in: .whitespaces)
        let current: Int
        if typed.isEmpty {
            current = 0
        } else if let value = Self.number(typed), value <= Self.maximumMinutes {
            current = value
        } else {
            return self
        }
        let next = min(Self.maximumMinutes, max(0, current + delta))
        return DurationEntry(minutes: "\(next)", seconds: seconds)
    }

    /// "12 分 30 秒", "12 分", "30 秒"; "未入力" when nothing was typed.
    var displayText: String {
        if issue == .empty { return "未入力" }
        let m = minutes.trimmingCharacters(in: .whitespaces), s = seconds.trimmingCharacters(in: .whitespaces)
        return [m.isEmpty ? nil : "\(m) 分", s.isEmpty ? nil : "\(s) 秒"].compactMap { $0 }.joined(separator: " ")
    }

    /// Plain digits only: no sign, no decimals.
    private static func number(_ text: String) -> Int? {
        guard !text.isEmpty, text.count <= 6, text.allSatisfy(\.isASCIIDigit) else { return nil }
        return Int(text)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// Validation and display for a per-set load in kilograms. One place so the
/// Runner, History, and tests agree on what is storable and how it reads.
enum SetWeight {
    /// Generous sanity ceiling: only rejects obvious input mistakes (an extra
    /// digit), not any real lift.
    static let maximumKg: Double = 1000

    /// The value if it is storable — finite, not negative, within the ceiling —
    /// rounded to 0.01 kg so repeated ± steps cannot accumulate float noise.
    /// `nil` for anything else.
    static func validated(_ kg: Double?) -> Double? {
        guard let kg, kg.isFinite, kg >= 0, kg <= maximumKg else { return nil }
        return (kg * 100).rounded() / 100
    }

    /// "60", "62.5", "61.25" — no forced trailing zero, always "." as separator.
    static func number(_ kg: Double) -> String {
        kg.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    /// "60 kg".
    static func display(_ kg: Double) -> String { "\(number(kg)) kg" }

    /// Parses typed input ("62.5" or "62,5"). `nil` when blank or invalid.
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, let value = Double(trimmed) else { return nil }
        return validated(value)
    }
}

/// The one place a set's `StepResult` is written, so the Runner and Free
/// Workout cannot drift on the execution snapshots.
///
/// Rules (V12–V14, unchanged from the Runner):
/// - re-recording a (session, step, setIndex) overwrites done / reps / weight
///   only; the `…AtExecution` snapshots stay as first written;
/// - a new result copies the exercise id / title snapshot from the step's
///   first sibling in this session — so one record never carries two
///   identities — and reads the live step only when it is the first;
/// - the owner comes from the parent session, never the current account.
///
/// The planned set count is the one rule that differs by caller, see
/// `PlannedSets`.
enum StepResultWriter {

    enum PlannedSets {
        /// Routine Runner: the first result snapshots `step.sets`, later ones
        /// copy it, so a mid-session routine edit cannot split one record
        /// across two plans.
        case firstWritten
        /// Free Workout: the plan *is* the live set list, which changes while
        /// the workout runs. Every result of the record is kept equal to
        /// `step.sets`, so the record can never be inconsistent or stale.
        case currentStepSets
    }

    @discardableResult
    static func record(
        in context: ModelContext,
        sessionId: UUID,
        ownerAccountID: UUID?,
        step: Step,
        setIndex: Int,
        done: Bool,
        actualReps: Int?,
        weightKg: Double?,
        actualDurationSeconds: Int? = nil,
        plannedSets: PlannedSets = .firstWritten
    ) -> StepResult {
        let siblings = results(in: context, sessionId: sessionId, stepId: step.id)
        // What the set was when it ran decides what it can carry: a timed set
        // has no reps, any other set has no duration, and a duration is kept
        // only on a done set and only when positive.
        let existingSet = siblings.first(where: { $0.setIndex == setIndex })
        let recordExerciseId = (existingSet ?? siblings.first).map(\.exerciseIdAtExecution) ?? step.exerciseId
        let isTimed = !WorkoutSetSemantics.countsReps(exerciseId: recordExerciseId ?? step.exerciseId)
        let reps = isTimed ? nil : actualReps
        let duration = (isTimed && done) ? SetDuration.validated(actualDurationSeconds) : nil
        defer {
            if case .currentStepSets = plannedSets {
                for result in self.results(in: context, sessionId: sessionId, stepId: step.id) {
                    result.plannedSetsAtExecution = step.sets
                }
            }
        }
        if let existing = existingSet {
            existing.done = done
            existing.actualReps = reps
            existing.weightKg = weightKg
            existing.actualDurationSeconds = duration
            // Re-recording a done rep set keeps its RIR; it is changed only
            // through `recordRepsInReserve`. A skipped or timed set has none.
            if !done || isTimed { existing.repsInReserve = nil }
            return existing
        }
        let firstSibling = siblings.min { $0.setIndex < $1.setIndex }
        // A sibling's nil (a session begun before V13 / V14) is copied as is,
        // never filled in from the live step.
        let planned: Int?
        switch plannedSets {
        case .firstWritten: planned = firstSibling.map(\.plannedSetsAtExecution) ?? step.sets
        case .currentStepSets: planned = step.sets
        }
        let exerciseId = firstSibling.map(\.exerciseIdAtExecution) ?? step.exerciseId
        let exerciseTitle = firstSibling.map(\.exerciseTitleAtExecution) ?? step.title
        let result = StepResult(
            sessionId: sessionId,
            stepId: step.id,
            setIndex: setIndex,
            done: done,
            actualReps: reps,
            ownerAccountID: ownerAccountID,
            weightKg: weightKg,
            plannedSetsAtExecution: planned,
            exerciseIdAtExecution: exerciseId,
            exerciseTitleAtExecution: exerciseTitle,
            actualDurationSeconds: duration
        )
        context.insert(result)
        return result
    }

    /// Sets or clears (`nil`) the reps in reserve of an already done
    /// rep-counted set, leaving every other value as it was. Refused (nil,
    /// nothing written) when the set has no result yet, was skipped, is
    /// timed, or the value is outside `RepsInReserve.range`. The latest value
    /// replaces the previous one; no history is kept.
    @discardableResult
    static func recordRepsInReserve(
        _ value: Int?,
        in context: ModelContext,
        sessionId: UUID,
        step: Step,
        setIndex: Int
    ) -> StepResult? {
        guard RepsInReserve.isValid(value),
              let result = results(in: context, sessionId: sessionId, stepId: step.id).first(where: { $0.setIndex == setIndex }),
              result.done,
              WorkoutSetSemantics.countsReps(exerciseId: result.exerciseIdAtExecution ?? step.exerciseId)
        else { return nil }
        result.repsInReserve = value
        return result
    }

    /// Every result of one (session, step) record, pending inserts included.
    static func results(in context: ModelContext, sessionId: UUID, stepId: UUID) -> [StepResult] {
        let descriptor = FetchDescriptor<StepResult>(
            predicate: #Predicate<StepResult> { $0.sessionId == sessionId && $0.stepId == stepId }
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}
