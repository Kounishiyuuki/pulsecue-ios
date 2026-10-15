//
//  DayLog.swift
//  Pulse Cue
//
//  Created by Codex.
//
//  Ownership (schema V8): `ownerAccountID == nil` is guest data; otherwise it
//  is the server-confirmed internal account UUID — never a provider subject or
//  email. Guest, account A and account B can each keep a log for the same day,
//  so `date` is no longer globally unique. Uniqueness is per owner instead,
//  carried by `scopedDayKey`, which SwiftData enforces (insert of a second row
//  with the same key upserts into the first, exactly as `date` used to).
//
//  Both are `private(set)`: the key must never drift from (owner, date), and
//  ownership only ever moves nil → account through an explicit adoption, which
//  does not exist yet.
//

import Foundation
import SwiftData

@Model
final class DayLog {
    var date: Date
    var intakeCalories: Int?
    var exerciseCalories: Int?
    var sleepMinutes: Int?
    var weightKg: Double?
    var note: String?
    private(set) var ownerAccountID: UUID?
    /// Optional only so the V7 → V8 migration can add the column before
    /// backfilling it; every row written by app code has it set.
    @Attribute(.unique) private(set) var scopedDayKey: String?

    init(
        date: Date,
        intakeCalories: Int? = nil,
        exerciseCalories: Int? = nil,
        sleepMinutes: Int? = nil,
        weightKg: Double? = nil,
        note: String? = nil,
        ownerAccountID: UUID? = nil
    ) {
        self.date = date
        self.intakeCalories = intakeCalories
        self.exerciseCalories = exerciseCalories
        self.sleepMinutes = sleepMinutes
        self.weightKg = weightKg
        self.note = note
        self.ownerAccountID = ownerAccountID
        self.scopedDayKey = Self.scopedDayKey(ownerAccountID: ownerAccountID, date: date)
    }

    /// Recomputes the key from the stored owner and date. Used by the V8
    /// backfill for rows that predate the column.
    func refreshScopedDayKey() {
        scopedDayKey = Self.scopedDayKey(ownerAccountID: ownerAccountID, date: date)
    }

    /// `<owner>|<date>` with both halves locale- and timezone-independent.
    ///
    /// The date half is the exact bit pattern of the stored instant, so two
    /// logs collide precisely when the old `@Attribute(.unique) date` would
    /// have made them collide — no calendar, no rounding, no formatting. The
    /// day normalization stays where it always was, in `DayLogStore`.
    static func scopedDayKey(ownerAccountID: UUID?, date: Date) -> String {
        let owner = ownerAccountID?.uuidString ?? "guest"
        let instant = String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
        return "\(owner)|\(instant)"
    }
}
