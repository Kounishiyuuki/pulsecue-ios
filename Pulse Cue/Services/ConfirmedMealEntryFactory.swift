//
//  ConfirmedMealEntryFactory.swift
//  Pulse Cue
//
//  Shared construction of the confirmed `MealEntry` that a review
//  screen produces from its (string-typed) form fields. Used by the
//  barcode (`.barcode`), nutrition-label OCR (`.ocr`), and photo
//  estimate (`.ai`) review screens so the construction rules live in
//  exactly one place instead of being copied per screen.
//
//  Boundaries (locked for this PR):
//   - Pure construction only. It creates the `MealEntry` value and
//     nothing else — it never inserts into a ModelContext, never
//     touches DayLog / NutritionLedger / ProteinTotals. The caller's
//     `save()` inserts the result and runs the DayLog sync, only
//     after the user's explicit confirmation.
//   - Behaviour is identical to the per-screen `makeConfirmedEntry`
//     helpers it replaces — this is a refactor, not a behaviour
//     change.
//

import Foundation

enum ConfirmedMealEntryFactory {

    /// Builds the confirmed `MealEntry` a review screen produces from
    /// its form fields. Pure — it touches no SwiftUI or SwiftData
    /// state — so the confirm logic stays unit-testable without a
    /// view host.
    ///
    /// Behaviour locked across all three review flows:
    ///  - `status` is always `.confirmed`; `source` is the caller's
    ///    (`.barcode` / `.ocr` / `.ai`) — a reviewed meal is never a
    ///    draft.
    ///  - a blank name falls back to the slot label and a blank note
    ///    to `nil`, matching the manual-entry path in `MealEntrySheet`.
    ///  - calories parse leniently: a non-numeric field counts as 0,
    ///    clamped non-negative. The review screens gate the save
    ///    button on a valid calorie value, so a real value is present
    ///    in the UI.
    ///  - protein / carbs / fat parse to optional `Int`s.
    static func make(
        day: Date,
        slot: MealSlot,
        name: String,
        kcalText: String,
        proteinText: String,
        carbText: String,
        fatText: String,
        note: String,
        source: MealSource
    ) -> MealEntry {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return MealEntry(
            dayDate: day,
            slot: slot,
            name: trimmedName.isEmpty ? slot.label : trimmedName,
            kcal: max(0, Int(kcalText) ?? 0),
            proteinGrams: Int(proteinText),
            carbGrams: Int(carbText),
            fatGrams: Int(fatText),
            status: .confirmed,
            source: source,
            note: trimmedNote.isEmpty ? nil : trimmedNote
        )
    }
}
