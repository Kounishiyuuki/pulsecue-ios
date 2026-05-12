//
//  NutritionLedger.swift
//  Pulse Cue
//
//  Created by Codex.
//
//  Keeps DayLog.intakeCalories in sync with the sum of confirmed
//  MealEntry rows for a given local date. Called by NutritionView /
//  MealEntrySheet whenever a meal is confirmed, edited, or deleted.
//
//  Why a dedicated helper:
//  - DayLog is the authoritative source HealthSummary reads from.
//  - Mixing manual quick-input and meal-derived totals is messy; the
//    rule we settle on is simple: if any confirmed MealEntry exists
//    for the day, DayLog.intakeCalories is the sum of those meals.
//    If there are no confirmed meals, DayLog is left alone (so the
//    legacy DayLogQuickInputSheet number is preserved).
//

import Foundation
import SwiftData

enum NutritionLedger {
    /// Recompute DayLog.intakeCalories for `date` from confirmed
    /// MealEntries. If the day has no confirmed meals, do nothing.
    static func syncDayLogIntake(for date: Date, modelContext: ModelContext) {
        let day = DateUtils.startOfDay(date)
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day

        let descriptor = FetchDescriptor<MealEntry>()
        guard let allMeals = try? modelContext.fetch(descriptor) else { return }
        let confirmed = allMeals.filter {
            $0.status == .confirmed && $0.dayDate >= day && $0.dayDate < nextDay
        }
        guard !confirmed.isEmpty else { return }

        let total = confirmed.reduce(0) { $0 + $1.kcal }
        let dayLog = DayLogStore.fetchOrCreate(date: day, modelContext: modelContext)
        dayLog.intakeCalories = total
    }

    /// Confirmed kcal total for `date`, regardless of whether DayLog
    /// already has a manual override.
    static func confirmedTotal(for date: Date, modelContext: ModelContext) -> Int {
        let day = DateUtils.startOfDay(date)
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        let descriptor = FetchDescriptor<MealEntry>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all
            .filter { $0.status == .confirmed && $0.dayDate >= day && $0.dayDate < nextDay }
            .reduce(0) { $0 + $1.kcal }
    }
}
