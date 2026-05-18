//
//  NutritionLedgerTests.swift
//  Pulse CueTests
//
//  Boundary tests for the MealEntry / NutritionLedger / DayLog
//  contract:
//
//   - Estimated (.pending) meals must NOT be counted toward today's
//     intake.
//   - Confirmed (.confirmed) meals contribute additively to
//     DayLog.intakeCalories via NutritionLedger.syncDayLogIntake.
//   - Discarding (deleting) a pending estimate must not move the
//     confirmed total.
//   - Mixed pending + confirmed meals must only count the confirmed
//     subset.
//   - The ledger is safe to call on an empty store (no crash, no
//     DayLog row created when there are no confirmed meals).
//
//  Tests use an in-memory SwiftData ModelContainer and do not call
//  any external service.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct NutritionLedgerTests {

    private static func makeContext() throws -> ModelContext {
        let schema = Schema([
            Routine.self,
            Step.self,
            Session.self,
            StepResult.self,
            DayLog.self,
            MealEntry.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private func insertMeal(
        in context: ModelContext,
        date: Date = Date(),
        slot: MealSlot = .lunch,
        name: String = "テスト食",
        kcal: Int,
        status: MealStatus,
        source: MealSource = .manual
    ) -> MealEntry {
        let meal = MealEntry(
            dayDate: date,
            slot: slot,
            name: name,
            kcal: kcal,
            status: status,
            source: source
        )
        context.insert(meal)
        return meal
    }

    // MARK: - Pending must not count

    @Test
    func pendingAIMealDoesNotAffectDayLog() throws {
        let context = try Self.makeContext()
        _ = insertMeal(in: context, kcal: 650, status: .pending, source: .ai)

        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)

        // No confirmed meals → the ledger must not create a DayLog row.
        let logs = try context.fetch(FetchDescriptor<DayLog>())
        #expect(logs.isEmpty)
        #expect(NutritionLedger.confirmedTotal(for: Date(), modelContext: context) == 0)
    }

    @Test
    func pendingManualDraftDoesNotAffectDayLog() throws {
        let context = try Self.makeContext()
        _ = insertMeal(in: context, kcal: 400, status: .pending, source: .manual)

        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)
        #expect(NutritionLedger.confirmedTotal(for: Date(), modelContext: context) == 0)
    }

    // MARK: - Confirmed contributes

    @Test
    func confirmedMealContributesToDayLog() throws {
        let context = try Self.makeContext()
        _ = insertMeal(in: context, slot: .breakfast, kcal: 320, status: .confirmed)

        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)

        let logs = try context.fetch(FetchDescriptor<DayLog>())
        #expect(logs.count == 1)
        #expect(logs.first?.intakeCalories == 320)
        #expect(NutritionLedger.confirmedTotal(for: Date(), modelContext: context) == 320)
    }

    @Test
    func multipleConfirmedMealsSumIntoDayLog() throws {
        let context = try Self.makeContext()
        _ = insertMeal(in: context, slot: .breakfast, kcal: 320, status: .confirmed)
        _ = insertMeal(in: context, slot: .lunch, kcal: 650, status: .confirmed)
        _ = insertMeal(in: context, slot: .dinner, kcal: 480, status: .confirmed)

        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)

        let log = try #require(try context.fetch(FetchDescriptor<DayLog>()).first)
        #expect(log.intakeCalories == 320 + 650 + 480)
    }

    // MARK: - Discard

    @Test
    func discardingPendingEstimateDoesNotChangeConfirmedTotal() throws {
        let context = try Self.makeContext()
        _ = insertMeal(in: context, slot: .breakfast, kcal: 300, status: .confirmed)
        let pending = insertMeal(in: context, slot: .lunch, kcal: 650, status: .pending, source: .ai)

        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)
        #expect(NutritionLedger.confirmedTotal(for: Date(), modelContext: context) == 300)

        // Discard: delete the pending entry.
        context.delete(pending)
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)
        #expect(NutritionLedger.confirmedTotal(for: Date(), modelContext: context) == 300)
        let log = try #require(try context.fetch(FetchDescriptor<DayLog>()).first)
        #expect(log.intakeCalories == 300)
    }

    // MARK: - Mixed states

    @Test
    func mixedPendingAndConfirmedCountsOnlyConfirmed() throws {
        let context = try Self.makeContext()
        _ = insertMeal(in: context, slot: .breakfast, kcal: 320, status: .confirmed)
        _ = insertMeal(in: context, slot: .lunch, kcal: 650, status: .pending, source: .ai)
        _ = insertMeal(in: context, slot: .dinner, kcal: 480, status: .confirmed)
        _ = insertMeal(in: context, slot: .snack, kcal: 150, status: .pending, source: .manual)

        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)

        // Only the two .confirmed meals (320 + 480 = 800).
        #expect(NutritionLedger.confirmedTotal(for: Date(), modelContext: context) == 800)
        let log = try #require(try context.fetch(FetchDescriptor<DayLog>()).first)
        #expect(log.intakeCalories == 800)
    }

    // MARK: - Confirming a pending estimate updates the day total

    @Test
    func promotingPendingToConfirmedUpdatesDayLog() throws {
        let context = try Self.makeContext()
        let meal = insertMeal(in: context, slot: .lunch, kcal: 650, status: .pending, source: .ai)
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)
        #expect(NutritionLedger.confirmedTotal(for: Date(), modelContext: context) == 0)

        // User confirms the AI estimate.
        meal.statusRaw = MealStatus.confirmed.rawValue
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)
        let log = try #require(try context.fetch(FetchDescriptor<DayLog>()).first)
        #expect(log.intakeCalories == 650)
    }

    // MARK: - Other-day meals must not bleed in

    @Test
    func confirmedMealOnAnotherDayDoesNotContributeToToday() throws {
        let context = try Self.makeContext()
        let cal = Calendar.current
        let today = DateUtils.startOfDay(Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        _ = insertMeal(in: context, date: yesterday, kcal: 999, status: .confirmed)

        NutritionLedger.syncDayLogIntake(for: today, modelContext: context)
        #expect(NutritionLedger.confirmedTotal(for: today, modelContext: context) == 0)
        // Yesterday's total is still correct.
        #expect(NutritionLedger.confirmedTotal(for: yesterday, modelContext: context) == 999)
    }

    // MARK: - Robustness

    @Test
    func emptyStoreIsSafeAndDoesNotCrash() throws {
        let context = try Self.makeContext()
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)
        #expect(NutritionLedger.confirmedTotal(for: Date(), modelContext: context) == 0)
        let logs = try context.fetch(FetchDescriptor<DayLog>())
        #expect(logs.isEmpty)
    }

    // MARK: - Edit / delete reconcile

    @Test
    func editingConfirmedMealKcalUpdatesDayLog() throws {
        let context = try Self.makeContext()
        let meal = insertMeal(in: context, kcal: 400, status: .confirmed)
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)
        #expect(DayLogStore.fetch(date: Date(), modelContext: context)?.intakeCalories == 400)

        meal.kcal = 650
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)

        #expect(DayLogStore.fetch(date: Date(), modelContext: context)?.intakeCalories == 650)
        #expect(NutritionLedger.confirmedTotal(for: Date(), modelContext: context) == 650)
    }

    @Test
    func deletingOneOfManyConfirmedMealsUpdatesDayLogToNewSum() throws {
        let context = try Self.makeContext()
        let breakfast = insertMeal(in: context, slot: .breakfast, kcal: 400, status: .confirmed)
        _ = insertMeal(in: context, slot: .lunch, kcal: 800, status: .confirmed)
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)
        #expect(DayLogStore.fetch(date: Date(), modelContext: context)?.intakeCalories == 1200)

        context.delete(breakfast)
        NutritionLedger.reconcileAfterMealRemoval(for: Date(), modelContext: context)

        #expect(DayLogStore.fetch(date: Date(), modelContext: context)?.intakeCalories == 800)
    }

    /// Regression for the bug PR #33 fixes: deleting the *last*
    /// confirmed meal of the day must clear DayLog.intakeCalories,
    /// not leave the old sum stale.
    @Test
    func deletingTheLastConfirmedMealClearsDayLogIntake() throws {
        let context = try Self.makeContext()
        let meal = insertMeal(in: context, kcal: 500, status: .confirmed)
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)
        #expect(DayLogStore.fetch(date: Date(), modelContext: context)?.intakeCalories == 500)

        context.delete(meal)
        NutritionLedger.reconcileAfterMealRemoval(for: Date(), modelContext: context)

        // DayLog row may still exist (other fields might have been
        // populated independently), but the meal-derived intake must
        // be cleared so Today/Balance doesn't show a stale 500.
        if let dayLog = DayLogStore.fetch(date: Date(), modelContext: context) {
            #expect(dayLog.intakeCalories == nil)
        }
        #expect(NutritionLedger.confirmedTotal(for: Date(), modelContext: context) == 0)
    }

    @Test
    func deletingLastConfirmedMealWithPendingRemainingClearsIntake() throws {
        let context = try Self.makeContext()
        let confirmed = insertMeal(in: context, kcal: 600, status: .confirmed)
        _ = insertMeal(in: context, kcal: 350, status: .pending, source: .ai)
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)
        #expect(DayLogStore.fetch(date: Date(), modelContext: context)?.intakeCalories == 600)

        context.delete(confirmed)
        NutritionLedger.reconcileAfterMealRemoval(for: Date(), modelContext: context)

        // Pending-only state: intake must be nil so the pending AI
        // estimate doesn't accidentally read as confirmed.
        #expect(DayLogStore.fetch(date: Date(), modelContext: context)?.intakeCalories == nil)
    }

    // MARK: - Source-of-truth rule

    /// Adding the first confirmed meal must overwrite a stale
    /// DayLogQuickInputSheet value so Today/Balance and Nutrition
    /// display the same number.
    @Test
    func firstConfirmedMealOverwritesQuickInputValue() throws {
        let context = try Self.makeContext()
        // Simulate a prior DayLogQuickInputSheet write.
        let existing = DayLogStore.fetchOrCreate(date: Date(), modelContext: context)
        existing.intakeCalories = 2000
        try context.save()

        _ = insertMeal(in: context, kcal: 450, status: .confirmed)
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)

        #expect(DayLogStore.fetch(date: Date(), modelContext: context)?.intakeCalories == 450)
    }

    /// `syncDayLogIntake` must not wipe a quick-input value on a day
    /// that has never had any MealEntry — the no-meals branch is a
    /// no-op so Today/Balance keeps showing the manual number.
    @Test
    func syncDoesNotAffectDayLogWhenNoMealsExist() throws {
        let context = try Self.makeContext()
        let log = DayLogStore.fetchOrCreate(date: Date(), modelContext: context)
        log.intakeCalories = 1800
        try context.save()

        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)

        #expect(DayLogStore.fetch(date: Date(), modelContext: context)?.intakeCalories == 1800)
    }

    @Test
    func hasAnyMealReflectsAnyStatusForTheLocalDay() throws {
        let context = try Self.makeContext()
        #expect(NutritionLedger.hasAnyMeal(for: Date(), modelContext: context) == false)

        _ = insertMeal(in: context, kcal: 100, status: .pending, source: .ai)
        #expect(NutritionLedger.hasAnyMeal(for: Date(), modelContext: context) == true)

        // A different day still reports false.
        let twoDaysAgo = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        #expect(NutritionLedger.hasAnyMeal(for: twoDaysAgo, modelContext: context) == false)
    }

    // MARK: - Multi-day isolation

    @Test
    func multipleMealsAcrossDaysSumIndependently() throws {
        let context = try Self.makeContext()
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!

        _ = insertMeal(in: context, date: today, slot: .breakfast, kcal: 300, status: .confirmed)
        _ = insertMeal(in: context, date: today, slot: .lunch, kcal: 700, status: .confirmed)
        _ = insertMeal(in: context, date: yesterday, slot: .dinner, kcal: 900, status: .confirmed)

        NutritionLedger.syncDayLogIntake(for: today, modelContext: context)
        NutritionLedger.syncDayLogIntake(for: yesterday, modelContext: context)

        #expect(DayLogStore.fetch(date: today, modelContext: context)?.intakeCalories == 1000)
        #expect(DayLogStore.fetch(date: yesterday, modelContext: context)?.intakeCalories == 900)
    }

    @Test
    func reconcileAfterMealRemovalIsSafeWhenNoMealsAndNoDayLog() throws {
        let context = try Self.makeContext()
        // No DayLog row, no meals — must not crash, must not create a
        // DayLog just to hold nil.
        NutritionLedger.reconcileAfterMealRemoval(for: Date(), modelContext: context)
        let logs = try context.fetch(FetchDescriptor<DayLog>())
        #expect(logs.isEmpty)
    }

    // MARK: - Date boundary handling

    /// A meal entered late at night (23:59) and a meal entered just
    /// after midnight (00:01) must land on different local days.
    /// `MealEntry.init` normalizes `dayDate` via `DateUtils.startOfDay`,
    /// so the ledger sees them in different buckets.
    @Test
    func mealsAt2359And0001AreCountedAsDifferentLocalDays() throws {
        let context = try Self.makeContext()
        let cal = Calendar.current

        // Anchor: 2026-04-10 23:59 local.
        var lateComponents = DateComponents()
        lateComponents.year = 2026
        lateComponents.month = 4
        lateComponents.day = 10
        lateComponents.hour = 23
        lateComponents.minute = 59
        let late = cal.date(from: lateComponents)!

        // 2026-04-11 00:01 local — same wall-clock minute group but
        // crosses midnight.
        var earlyComponents = lateComponents
        earlyComponents.day = 11
        earlyComponents.hour = 0
        earlyComponents.minute = 1
        let early = cal.date(from: earlyComponents)!

        _ = insertMeal(in: context, date: late, kcal: 500, status: .confirmed)
        _ = insertMeal(in: context, date: early, kcal: 700, status: .confirmed)

        NutritionLedger.syncDayLogIntake(for: late, modelContext: context)
        NutritionLedger.syncDayLogIntake(for: early, modelContext: context)

        let day10 = cal.startOfDay(for: late)
        let day11 = cal.startOfDay(for: early)
        #expect(day10 != day11)
        #expect(DayLogStore.fetch(date: day10, modelContext: context)?.intakeCalories == 500)
        #expect(DayLogStore.fetch(date: day11, modelContext: context)?.intakeCalories == 700)
        #expect(NutritionLedger.confirmedTotal(for: late, modelContext: context) == 500)
        #expect(NutritionLedger.confirmedTotal(for: early, modelContext: context) == 700)
    }

    @Test
    func mealEntryNormalizesDayDateToStartOfDay() throws {
        let context = try Self.makeContext()
        let cal = Calendar.current
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 4
        comps.day = 15
        comps.hour = 14
        comps.minute = 30
        let afternoon = cal.date(from: comps)!

        let meal = insertMeal(in: context, date: afternoon, kcal: 320, status: .confirmed)

        // `MealEntry.init` should have collapsed 14:30 → start-of-day.
        #expect(meal.dayDate == cal.startOfDay(for: afternoon))
        #expect(meal.dayDate.timeIntervalSince(cal.startOfDay(for: afternoon)) == 0)
    }

    /// The half-open day filter (`dayDate >= day && dayDate < nextDay`)
    /// must keep three consecutive days separate when synced
    /// individually.
    @Test
    func threeConsecutiveDaysDoNotBleedIntoEachOther() throws {
        let context = try Self.makeContext()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: today)!

        _ = insertMeal(in: context, date: today, kcal: 800, status: .confirmed)
        _ = insertMeal(in: context, date: yesterday, kcal: 600, status: .confirmed)
        _ = insertMeal(in: context, date: twoDaysAgo, kcal: 1100, status: .confirmed)

        NutritionLedger.syncDayLogIntake(for: today, modelContext: context)
        NutritionLedger.syncDayLogIntake(for: yesterday, modelContext: context)
        NutritionLedger.syncDayLogIntake(for: twoDaysAgo, modelContext: context)

        #expect(DayLogStore.fetch(date: today, modelContext: context)?.intakeCalories == 800)
        #expect(DayLogStore.fetch(date: yesterday, modelContext: context)?.intakeCalories == 600)
        #expect(DayLogStore.fetch(date: twoDaysAgo, modelContext: context)?.intakeCalories == 1100)

        #expect(NutritionLedger.confirmedTotal(for: today, modelContext: context) == 800)
        #expect(NutritionLedger.confirmedTotal(for: yesterday, modelContext: context) == 600)
        #expect(NutritionLedger.confirmedTotal(for: twoDaysAgo, modelContext: context) == 1100)
    }

    @Test
    func hasAnyMealUsesLocalDayBoundary() throws {
        let context = try Self.makeContext()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        _ = insertMeal(in: context, date: yesterday, kcal: 400, status: .confirmed)

        #expect(NutritionLedger.hasAnyMeal(for: yesterday, modelContext: context) == true)
        #expect(NutritionLedger.hasAnyMeal(for: today, modelContext: context) == false)
    }

    @Test
    func mealEntryClampsNegativeValuesAndKeepsNameFallback() throws {
        let context = try Self.makeContext()
        let meal = MealEntry(
            dayDate: Date(),
            slot: .breakfast,
            name: "",                 // empty → fallback to slot label
            kcal: -100,                // negative → clamp to 0
            proteinGrams: -5,
            carbGrams: nil,
            fatGrams: 20,
            status: .pending,
            source: .ai
        )
        context.insert(meal)

        #expect(meal.kcal == 0)
        #expect(meal.proteinGrams == 0)
        #expect(meal.carbGrams == nil)
        #expect(meal.fatGrams == 20)
        #expect(meal.name == MealSlot.breakfast.label)
        #expect(meal.slot == .breakfast)
        #expect(meal.status == .pending)
        #expect(meal.source == .ai)
    }
}
