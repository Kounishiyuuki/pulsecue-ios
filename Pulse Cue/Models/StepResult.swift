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

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        stepId: UUID,
        setIndex: Int,
        done: Bool,
        actualReps: Int? = nil,
        memo: String? = nil,
        ownerAccountID: UUID? = nil,
        weightKg: Double? = nil
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
    }
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
