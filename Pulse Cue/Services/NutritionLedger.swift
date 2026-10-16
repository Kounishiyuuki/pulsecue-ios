//
//  NutritionLedger.swift
//  Pulse Cue
//
//  Created by Codex.
//
//  Keeps DayLog.intakeCalories in sync with the sum of *confirmed*
//  MealEntry rows for a given local date. Called by NutritionView
//  and MealEntrySheet whenever a meal is added, edited, confirmed,
//  or deleted.
//
//  Source-of-truth rule (single field, two ownership modes):
//
//    1. The local day has **at least one MealEntry** (any status):
//         → meals own DayLog.intakeCalories for that day.
//         → intakeCalories = sum of `.confirmed` meals.
//         → intakeCalories = nil if only `.pending` meals exist
//           (pending / AI-estimated values must never contribute to
//           totals — see Docs/ai-privacy-and-safety.md and the
//           "estimate → confirm → finalize" requirement).
//
//    2. The local day has **no MealEntry rows at all**:
//         → DayLog.intakeCalories is left untouched so the legacy
//           `DayLogQuickInputSheet` quick-input value is preserved.
//
//  Why two write entry points:
//   - `syncDayLogIntake(for:modelContext:)` is the safe, idempotent
//     call after a meal is *added*, *edited*, or *confirmed*. It
//     never wipes a quick-input value because in those cases the
//     day still has at least one meal (the one that just changed).
//   - `reconcileAfterMealRemoval(for:modelContext:)` is the
//     follow-up to a *delete*. It forces meal-ownership: if no
//     confirmed meals remain (including "no meals at all"), it
//     clears the meal-derived intake so a stale total can't linger.
//
//  Scope: every entry point takes the health scope and reads only that
//  owner's meals and writes only that owner's DayLog. Guest meals total into
//  the guest log, account A's into A's — never a cross-owner sum. An
//  undetermined scope reads no meals and writes nothing.
//
//  Past versions returned early when the confirmed list was empty,
//  which left `DayLog.intakeCalories` stale after the last confirmed
//  meal was deleted. That bug is fixed by `reconcileAfterMealRemoval`.
//

import Foundation
import SwiftData

enum NutritionLedger {

    // MARK: - Write entry points

    /// Reconcile DayLog.intakeCalories after a meal is added,
    /// edited, or confirmed. Does **not** touch DayLog when the
    /// day has no MealEntry rows at all (preserves
    /// `DayLogQuickInputSheet` values).
    static func syncDayLogIntake(for date: Date, scope: HealthDataScope, modelContext: ModelContext) {
        let mealsForDay = mealsForDay(date, scope: scope, modelContext: modelContext)
        guard !mealsForDay.isEmpty else { return }
        writeMealOwnedIntake(for: date, mealsForDay: mealsForDay, scope: scope, modelContext: modelContext)
    }

    /// Reconcile DayLog.intakeCalories after a meal has been
    /// removed. Forces meal-ownership: if no confirmed meals remain
    /// (or no meals remain at all), clears the meal-derived intake.
    /// Existing DayLog rows with a previously-synced meal sum are
    /// reset to nil so a stale total cannot linger.
    static func reconcileAfterMealRemoval(for date: Date, scope: HealthDataScope, modelContext: ModelContext) {
        let mealsForDay = mealsForDay(date, scope: scope, modelContext: modelContext)
        writeMealOwnedIntake(
            for: date,
            mealsForDay: mealsForDay,
            scope: scope,
            modelContext: modelContext,
            clearIfEmpty: true,
        )
    }

    // MARK: - Read helpers

    /// Confirmed kcal total for `date`. Pure read — does not mutate
    /// DayLog. Useful when a view needs the authoritative
    /// meal-derived value independent of what's currently persisted
    /// on DayLog.
    static func confirmedTotal(for date: Date, scope: HealthDataScope, modelContext: ModelContext) -> Int {
        mealsForDay(date, scope: scope, modelContext: modelContext)
            .filter { $0.status == .confirmed }
            .reduce(0) { $0 + $1.kcal }
    }

    /// `true` if at least one MealEntry exists for the local day —
    /// regardless of status. Indicates that meals own the day's
    /// intake (see the file header). UI surfaces may use this to
    /// suppress duplicate manual entry paths when meals are active.
    static func hasAnyMeal(for date: Date, scope: HealthDataScope, modelContext: ModelContext) -> Bool {
        !mealsForDay(date, scope: scope, modelContext: modelContext).isEmpty
    }

    // MARK: - Internals

    /// Core write logic shared by both entry points.
    ///
    /// - Parameters:
    ///   - clearIfEmpty: when `true`, the call originated from a
    ///     delete and we should clear an existing DayLog row's
    ///     intakeCalories if no meals remain. When `false`, an
    ///     empty `mealsForDay` is a no-op (this branch is unreachable
    ///     from `syncDayLogIntake` thanks to the early-return guard,
    ///     but kept here so the function is total).
    private static func writeMealOwnedIntake(
        for date: Date,
        mealsForDay: [MealEntry],
        scope: HealthDataScope,
        modelContext: ModelContext,
        clearIfEmpty: Bool = false,
    ) {
        let day = DateUtils.startOfDay(date)
        let confirmedSum = mealsForDay
            .filter { $0.status == .confirmed }
            .reduce(0) { $0 + $1.kcal }

        if confirmedSum > 0 {
            // Confirmed meals exist → write the sum into DayLog
            // (creating the row if needed). Quick-input value is
            // intentionally overwritten because meals now own the day.
            let dayLog = DayLogStore.fetchOrCreate(date: day, scope: scope, modelContext: modelContext)
            dayLog?.intakeCalories = confirmedSum
            return
        }

        // From here, confirmedSum == 0.
        let ownershipTransferred = !mealsForDay.isEmpty || clearIfEmpty
        guard ownershipTransferred else { return }

        // Clear an existing DayLog row's intakeCalories, but don't
        // *create* a row just to hold nil. If the row never existed
        // there's nothing stale to wipe.
        if let dayLog = DayLogStore.fetch(date: day, scope: scope, modelContext: modelContext) {
            dayLog.intakeCalories = nil
        }
    }

    private static func mealsForDay(
        _ date: Date,
        scope: HealthDataScope,
        modelContext: ModelContext
    ) -> [MealEntry] {
        let day = DateUtils.startOfDay(date)
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        let all = (try? modelContext.fetch(FetchDescriptor<MealEntry>(
            predicate: #Predicate<MealEntry> { $0.dayDate >= day && $0.dayDate < nextDay }
        ))) ?? []
        return scope.visible(all)
    }
}
