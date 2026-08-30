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

import Foundation

enum NumberFormat {

    /// Grouped integer: 1485 → "1,485".
    static func int(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// One decimal place at most, trailing zero dropped: 72.0 → "72".
    static func weight(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }

    /// Sleep as hours and minutes: 445 → "7h 25m".
    static func sleepDuration(minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours > 0 && remainder > 0 { return "\(hours)h \(remainder)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(remainder)m"
    }
}
