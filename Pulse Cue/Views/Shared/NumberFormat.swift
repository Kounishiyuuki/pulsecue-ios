//
//  NumberFormat.swift
//  Pulse Cue
//
//  The number formatting Home and Nutrition share.
//
//  `formatInt` was written out identically in `TodayView` and
//  `NutritionView`, and `formatWeight` in `TodayView` and the settings
//  chrome. Harmless as private helpers; not harmless once the cards that use
//  them live in files of their own, because the next copy is written by
//  whoever adds the next card.
//
//  Presentation only — no rounding decision here carries domain meaning.
//
//  `nonisolated`: these are pure functions over their arguments, so they have
//  no business requiring the main actor. Without it the module's default
//  isolation applies and every call from a nonisolated context — a static
//  helper on a card, for instance — becomes a warning about crossing into the
//  MainActor for arithmetic that touches nothing shared.
//

import Foundation

enum NumberFormat {

    /// Grouped integer: 1485 → "1,485".
    nonisolated static func int(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// One decimal place at most, trailing zero dropped: 72.0 → "72".
    ///
    /// Home, Health and the settings cells all show weight this way. Me does
    /// not — see `weightOneDecimal`.
    nonisolated static func weight(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }

    /// Always one decimal place, trailing zero kept: 72.0 → "72.0".
    ///
    /// Me's personal-status row and the goal delta beside it. Not a stylistic
    /// difference from `weight`: that row is the one place a weight is read
    /// against another weight, and a column that shows "72" one day and "71.4"
    /// the next makes a 0.6 kg change look like a change of format. The fixed
    /// decimal keeps the digits in the same place.
    ///
    /// `String(format:)` rather than a `NumberFormatter`, because that is what
    /// this screen has always used and the two round differently at the half.
    nonisolated static func weightOneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// Sleep as hours and minutes: 445 → "7h 25m".
    nonisolated static func sleepDuration(minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours > 0 && remainder > 0 { return "\(hours)h \(remainder)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(remainder)m"
    }
}
