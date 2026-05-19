//
//  RecentMealSuggestionsTests.swift
//  Pulse CueTests
//
//  Locks in the recent-meal suggestion rules used by NutritionView's
//  「最近の食事」 quick-add row.
//
//  Coverage:
//   - confirmed manual meals from prior days surface
//   - pending meals are excluded
//   - AI-sourced meals are excluded
//   - today's meals are excluded
//   - same (name, kcal) collapses to a single suggestion
//   - newest occurrence wins (its slot / PFC carry over)
//   - results are sorted newest-first
//   - limit is respected
//   - empty input + zero limit are handled
//
//  Plus a SwiftData integration test for tap-to-add semantics:
//   - tapping a suggestion creates a confirmed manual MealEntry
//     anchored to today's local startOfDay
//   - the new entry feeds NutritionLedger.syncDayLogIntake so
//     DayLog.intakeCalories tracks the resurrected meal
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct RecentMealSuggestionsTests {

    // MARK: - Helpers

    private static var calendar: Calendar { Calendar(identifier: .gregorian) }

    private static func makeContext() throws -> ModelContext {
        let schema = Schema([
            Routine.self,
            Step.self,
            Session.self,
            StepResult.self,
            DayLog.self,
            MealEntry.self,
            UserProfile.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    /// 2026-04-19 12:00 (Sunday) — the "today" anchor.
    private static func todayDate() -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 4; c.day = 19; c.hour = 12
        return calendar.date(from: c)!
    }

    /// Convenience builder for fixture meals.
    private static func meal(
        day: Int,
        name: String,
        kcal: Int,
        slot: MealSlot = .lunch,
        status: MealStatus = .confirmed,
        source: MealSource = .manual,
        createdAt: Date? = nil
    ) -> MealEntry {
        var c = DateComponents(); c.year = 2026; c.month = 4; c.day = day
        let dayDate = calendar.date(from: c)!
        let created = createdAt ?? dayDate
        return MealEntry(
            dayDate: dayDate,
            slot: slot,
            name: name,
            kcal: kcal,
            status: status,
            source: source,
            createdAt: created
        )
    }

    // MARK: - Filtering

    @Test func suggestsConfirmedManualMealsFromPastDays() {
        let meals = [
            Self.meal(day: 17, name: "鶏むね", kcal: 300),
            Self.meal(day: 18, name: "サラダ", kcal: 150),
        ]
        let out = RecentMealSuggestions.suggest(from: meals, today: Self.todayDate(), calendar: Self.calendar)
        #expect(out.count == 2)
        #expect(out.map(\.name) == ["サラダ", "鶏むね"]) // newest first
    }

    @Test func excludesPendingMeals() {
        let meals = [
            Self.meal(day: 17, name: "鶏むね", kcal: 300, status: .pending),
            Self.meal(day: 18, name: "サラダ", kcal: 150, status: .confirmed),
        ]
        let out = RecentMealSuggestions.suggest(from: meals, today: Self.todayDate(), calendar: Self.calendar)
        #expect(out.map(\.name) == ["サラダ"])
    }

    @Test func excludesAiSourcedMealsEvenWhenConfirmed() {
        // AI estimates must never bubble up as quick-add suggestions —
        // a confirmed AI entry was confirmed *for that day*, not as a
        // template to re-fire on later days.
        let meals = [
            Self.meal(day: 17, name: "鶏むね", kcal: 300, source: .ai),
            Self.meal(day: 18, name: "サラダ", kcal: 150, source: .manual),
        ]
        let out = RecentMealSuggestions.suggest(from: meals, today: Self.todayDate(), calendar: Self.calendar)
        #expect(out.map(\.name) == ["サラダ"])
    }

    @Test func excludesTodayMeals() {
        let meals = [
            Self.meal(day: 19, name: "今日のサラダ", kcal: 120), // today
            Self.meal(day: 18, name: "サラダ", kcal: 150),
        ]
        let out = RecentMealSuggestions.suggest(from: meals, today: Self.todayDate(), calendar: Self.calendar)
        #expect(out.map(\.name) == ["サラダ"])
    }

    // MARK: - Dedup + sort

    @Test func dedupesByNameAndKcalKeepingMostRecent() {
        // Three 鶏むね/300 entries across multiple days. Newest entry's
        // slot / PFC must win.
        var older = DateComponents(); older.year = 2026; older.month = 4; older.day = 10
        let olderDate = Self.calendar.date(from: older)!
        var newer = DateComponents(); newer.year = 2026; newer.month = 4; newer.day = 18
        let newerDate = Self.calendar.date(from: newer)!

        let oldOne = MealEntry(
            dayDate: olderDate, slot: .lunch, name: "鶏むね", kcal: 300,
            proteinGrams: 30, status: .confirmed, source: .manual, createdAt: olderDate
        )
        let newOne = MealEntry(
            dayDate: newerDate, slot: .dinner, name: "鶏むね", kcal: 300,
            proteinGrams: 35, status: .confirmed, source: .manual, createdAt: newerDate
        )
        let out = RecentMealSuggestions.suggest(from: [oldOne, newOne], today: Self.todayDate(), calendar: Self.calendar)
        #expect(out.count == 1)
        #expect(out.first?.slot == .dinner)
        #expect(out.first?.proteinGrams == 35)
    }

    @Test func differentKcalProducesDistinctSuggestions() {
        // Same name but different kcal → two separate suggestions.
        let meals = [
            Self.meal(day: 17, name: "鶏むね", kcal: 300),
            Self.meal(day: 18, name: "鶏むね", kcal: 400),
        ]
        let out = RecentMealSuggestions.suggest(from: meals, today: Self.todayDate(), calendar: Self.calendar)
        #expect(out.count == 2)
    }

    @Test func sortedByMostRecentFirst() {
        let meals = [
            Self.meal(day: 10, name: "古い", kcal: 100),
            Self.meal(day: 18, name: "新しい", kcal: 200),
            Self.meal(day: 14, name: "中間", kcal: 150),
        ]
        let out = RecentMealSuggestions.suggest(from: meals, today: Self.todayDate(), calendar: Self.calendar)
        #expect(out.map(\.name) == ["新しい", "中間", "古い"])
    }

    // MARK: - Limit / empty

    @Test func respectsLimit() {
        let meals = (1...10).map { day in
            Self.meal(day: day, name: "meal\(day)", kcal: 100 + day)
        }
        let out = RecentMealSuggestions.suggest(from: meals, today: Self.todayDate(), limit: 3, calendar: Self.calendar)
        #expect(out.count == 3)
    }

    @Test func emptyMealsReturnsEmpty() {
        let out = RecentMealSuggestions.suggest(from: [], today: Self.todayDate(), calendar: Self.calendar)
        #expect(out.isEmpty)
    }

    @Test func zeroLimitReturnsEmpty() {
        let meals = [Self.meal(day: 17, name: "鶏むね", kcal: 300)]
        let out = RecentMealSuggestions.suggest(from: meals, today: Self.todayDate(), limit: 0, calendar: Self.calendar)
        #expect(out.isEmpty)
    }

    // MARK: - Integration: tap-to-add semantics

    /// Resurrecting a suggestion onto today must create a NEW
    /// `MealEntry` whose `dayDate` is today's local startOfDay, status
    /// = .confirmed, source = .manual, and feed
    /// `NutritionLedger.syncDayLogIntake` so DayLog.intakeCalories
    /// reflects the resurrected kcal.
    @Test func tappingSuggestionCreatesTodayConfirmedManualEntry() throws {
        let context = try Self.makeContext()
        let today = Date()
        let todayStart = Calendar.current.startOfDay(for: today)

        // Seed: a confirmed manual meal 3 days ago.
        let pastDay = Calendar.current.date(byAdding: .day, value: -3, to: todayStart)!
        let past = MealEntry(
            dayDate: pastDay, slot: .lunch, name: "鶏むね 200g", kcal: 320,
            proteinGrams: 45, status: .confirmed, source: .manual,
            createdAt: pastDay
        )
        context.insert(past)

        let suggestions = RecentMealSuggestions.suggest(
            from: [past],
            today: today,
            calendar: .current
        )
        #expect(suggestions.count == 1)
        let suggestion = suggestions[0]

        // Simulate tap-to-add: build a fresh entry from the suggestion
        // anchored to today, confirmed manual.
        let resurrected = MealEntry(
            dayDate: today,
            slot: suggestion.slot,
            name: suggestion.name,
            kcal: suggestion.kcal,
            proteinGrams: suggestion.proteinGrams,
            carbGrams: suggestion.carbGrams,
            fatGrams: suggestion.fatGrams,
            status: .confirmed,
            source: .manual
        )
        context.insert(resurrected)
        NutritionLedger.syncDayLogIntake(for: today, modelContext: context)

        // Check the new entry's invariants.
        #expect(resurrected.dayDate == todayStart)
        #expect(resurrected.status == .confirmed)
        #expect(resurrected.source == .manual)
        #expect(resurrected.kcal == 320)
        #expect(resurrected.name == "鶏むね 200g")

        // DayLog should reflect today's confirmed total = 320.
        let dayLog = DayLogStore.fetch(date: todayStart, modelContext: context)
        #expect(dayLog?.intakeCalories == 320)
    }

    /// Adding multiple suggestions stacks them via the ledger sum.
    @Test func addingMultipleSuggestionsAccumulatesDayLogIntake() throws {
        let context = try Self.makeContext()
        let today = Date()
        let todayStart = Calendar.current.startOfDay(for: today)
        let pastDay = Calendar.current.date(byAdding: .day, value: -3, to: todayStart)!

        // Two historical confirmed manual meals.
        let pastA = MealEntry(
            dayDate: pastDay, slot: .breakfast, name: "オートミール", kcal: 250,
            status: .confirmed, source: .manual, createdAt: pastDay
        )
        let pastB = MealEntry(
            dayDate: pastDay, slot: .lunch, name: "サラダ", kcal: 180,
            status: .confirmed, source: .manual, createdAt: pastDay
        )
        context.insert(pastA)
        context.insert(pastB)

        let suggestions = RecentMealSuggestions.suggest(
            from: [pastA, pastB],
            today: today,
            calendar: .current
        )
        #expect(suggestions.count == 2)

        for s in suggestions {
            let fresh = MealEntry(
                dayDate: today, slot: s.slot, name: s.name, kcal: s.kcal,
                status: .confirmed, source: .manual
            )
            context.insert(fresh)
        }
        NutritionLedger.syncDayLogIntake(for: today, modelContext: context)

        let dayLog = DayLogStore.fetch(date: todayStart, modelContext: context)
        #expect(dayLog?.intakeCalories == 250 + 180)
    }
}
