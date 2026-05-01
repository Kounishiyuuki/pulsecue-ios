//
//  DayLog.swift
//  Pulse Cue
//
//  Created by Codex.
//

import Foundation
import SwiftData

@Model
final class DayLog {
    @Attribute(.unique) var date: Date
    var intakeCalories: Int?
    var exerciseCalories: Int?
    var sleepMinutes: Int?
    var weightKg: Double?
    var note: String?

    init(
        date: Date,
        intakeCalories: Int? = nil,
        exerciseCalories: Int? = nil,
        sleepMinutes: Int? = nil,
        weightKg: Double? = nil,
        note: String? = nil
    ) {
        self.date = date
        self.intakeCalories = intakeCalories
        self.exerciseCalories = exerciseCalories
        self.sleepMinutes = sleepMinutes
        self.weightKg = weightKg
        self.note = note
    }
}
