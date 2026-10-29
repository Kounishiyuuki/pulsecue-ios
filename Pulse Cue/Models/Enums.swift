//
//  Enums.swift
//  Pulse Cue
//
//  Created by Codex.
//

import Foundation

enum SessionStatus: String, Codable, CaseIterable {
    case inProgress
    case completed
    case abandoned
}

enum RunnerPhase: String, Codable, CaseIterable {
    case exercise
    case rest
    case done
}

enum DayLogField: String, Identifiable, CaseIterable {
    case workout
    case nutrition
    case sleep
    case weight

    var id: String { rawValue }
}

/// Which 今日の記録 field the continuous-entry flow opens next.
///
/// Pure so the order and the nutrition rule can be tested without a store.
/// Nutrition is offered only while the day accepts manual intake: once meals
/// own the day, `NutritionLedger` overwrites `intakeCalories`, so a number
/// typed into the quick input would be lost. Those days are skipped here and
/// left to the Nutrition tab.
enum DailyRecordSequence {
    static let order: [DayLogField] = [.nutrition, .workout, .sleep, .weight]

    static func filledFields(
        intakeCalories: Int?,
        exerciseCalories: Int?,
        sleepMinutes: Int?,
        weightKg: Double?
    ) -> Set<DayLogField> {
        var filled: Set<DayLogField> = []
        if intakeCalories != nil { filled.insert(.nutrition) }
        if exerciseCalories != nil { filled.insert(.workout) }
        if sleepMinutes != nil { filled.insert(.sleep) }
        if weightKg != nil { filled.insert(.weight) }
        return filled
    }

    /// The first missing field the quick input can take, skipping `visited`
    /// so a field saved empty (e.g. sleep at 0h) cannot reopen in a loop.
    static func nextField(
        filled: Set<DayLogField>,
        nutritionAcceptsManualEntry: Bool,
        visited: Set<DayLogField> = []
    ) -> DayLogField? {
        order.first { field in
            if filled.contains(field) || visited.contains(field) { return false }
            if field == .nutrition && !nutritionAcceptsManualEntry { return false }
            return true
        }
    }
}

enum RunnerAction {
    case complete
    case skip
    case extend
    case back
}
