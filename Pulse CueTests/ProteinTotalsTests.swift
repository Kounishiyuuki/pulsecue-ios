//
//  ProteinTotalsTests.swift
//  Pulse CueTests
//
//  Locks in the protein-gram calculation rule used by NutritionView:
//
//    confirmed sum = sum of proteinGrams over MealEntries where
//                    status == .confirmed. Pending (manual or AI)
//                    rows are excluded. Nil proteinGrams contribute 0.
//
//  Coverage:
//   - confirmed manual meals sum correctly
//   - confirmed AI meals sum correctly (matches kcal rule)
//   - pending manual rows excluded
//   - pending AI rows excluded
//   - nil proteinGrams contributes 0
//   - empty input returns 0
//   - default target floor (≥ 60 g)
//   - default target scales with kcal target
//   - nil kcal target uses baseline
//   - `daily(...)` convenience returns both numbers in one pass
//   - recent-meal suggestion carries protein into a fresh today entry,
//     and the resulting confirmed sum reflects it
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct ProteinTotalsTests {

    // MARK: - Helpers

    private static func meal(
        day: Int,
        name: String = "鶏むね",
        kcal: Int = 300,
        protein: Int? = nil,
        status: MealStatus = .confirmed,
        source: MealSource = .manual
    ) -> MealEntry {
        let cal = Calendar(identifier: .gregorian)
        var c = DateComponents(); c.year = 2026; c.month = 4; c.day = day
        let date = cal.date(from: c)!
        return MealEntry(
            dayDate: date,
            slot: .lunch,
            name: name,
            kcal: kcal,
            proteinGrams: protein,
            status: status,
            source: source
        )
    }

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

    // MARK: - Confirmed sum rule

    @Test func sumOfConfirmedManualMeals() {
        let meals = [
            Self.meal(day: 18, protein: 30),
            Self.meal(day: 18, protein: 20),
        ]
        #expect(ProteinTotals.confirmedSum(from: meals) == 50)
    }

    @Test func confirmedAiMealCountsTowardTotal() {
        // PR #33's kcal rule includes AI rows that were *confirmed*;
        // protein follows the same source-agnostic, status-based rule.
        let meals = [
            Self.meal(day: 18, protein: 25, status: .confirmed, source: .ai),
            Self.meal(day: 18, protein: 15, status: .confirmed, source: .manual),
        ]
        #expect(ProteinTotals.confirmedSum(from: meals) == 40)
    }

    @Test func pendingManualMealExcluded() {
        let meals = [
            Self.meal(day: 18, protein: 30, status: .confirmed),
            Self.meal(day: 18, protein: 50, status: .pending, source: .manual),
        ]
        #expect(ProteinTotals.confirmedSum(from: meals) == 30)
    }

    @Test func pendingAiMealExcluded() {
        // AI-suggested but unconfirmed rows must never leak into the
        // day's confirmed protein total.
        let meals = [
            Self.meal(day: 18, protein: 30, status: .confirmed),
            Self.meal(day: 18, protein: 999, status: .pending, source: .ai),
        ]
        #expect(ProteinTotals.confirmedSum(from: meals) == 30)
    }

    @Test func nilProteinGramsContributesZero() {
        // A confirmed meal that didn't capture protein leaves the
        // macro at 0 — not nil. The day total stays defined even
        // when not every row tracks PFC.
        let meals = [
            Self.meal(day: 18, protein: nil, status: .confirmed),
            Self.meal(day: 18, protein: 25, status: .confirmed),
        ]
        #expect(ProteinTotals.confirmedSum(from: meals) == 25)
    }

    @Test func emptyMealsReturnsZero() {
        #expect(ProteinTotals.confirmedSum(from: []) == 0)
    }

    // MARK: - Default target

    @Test func defaultTargetUsesFloorBelow1200KcalTarget() {
        // 1000 kcal × 20% / 4 = 50 g → below floor → 60 g.
        #expect(ProteinTotals.defaultTargetGrams(forKcalTarget: 1000) == 60)
    }

    @Test func defaultTargetScalesAbove1200KcalTarget() {
        // 2500 × 0.20 / 4 = 125 g.
        #expect(ProteinTotals.defaultTargetGrams(forKcalTarget: 2500) == 125)
    }

    @Test func defaultTargetUsesBaselineWhenKcalTargetIsNil() {
        // 2000 × 0.20 / 4 = 100 g.
        #expect(ProteinTotals.defaultTargetGrams(forKcalTarget: nil) == 100)
    }

    @Test func defaultTargetExactly1200KcalSitsOnFloor() {
        // 1200 × 0.20 / 4 = 60 g → exactly at floor.
        #expect(ProteinTotals.defaultTargetGrams(forKcalTarget: 1200) == 60)
    }

    // MARK: - daily(...) convenience

    @Test func dailyReturnsBothNumbersInOnePass() {
        let meals = [
            Self.meal(day: 18, protein: 30),
            Self.meal(day: 18, protein: 20),
        ]
        let daily = ProteinTotals.daily(meals: meals, kcalTarget: 2200)
        #expect(daily.confirmedGrams == 50)
        // 2200 × 0.20 / 4 = 110 g.
        #expect(daily.targetGrams == 110)
    }

    @Test func dailyHonorsKcalTargetFloor() {
        let daily = ProteinTotals.daily(meals: [], kcalTarget: 800)
        #expect(daily.confirmedGrams == 0)
        #expect(daily.targetGrams == 60)
    }

    // MARK: - Recent meal preservation (integration)

    /// Tapping a recent meal suggestion must preserve `proteinGrams`
    /// onto today's confirmed entry, and the resulting confirmed sum
    /// must reflect that protein.
    @Test func recentMealSuggestionPreservesProtein() throws {
        let context = try Self.makeContext()
        let today = Date()
        let todayStart = Calendar.current.startOfDay(for: today)
        let pastDay = Calendar.current.date(byAdding: .day, value: -3, to: todayStart)!

        let past = MealEntry(
            dayDate: pastDay,
            slot: .lunch,
            name: "鶏むね 200g",
            kcal: 320,
            proteinGrams: 45,
            status: .confirmed,
            source: .manual,
            createdAt: pastDay
        )
        context.insert(past)

        let suggestions = RecentMealSuggestions.suggest(
            from: [past],
            today: today,
            calendar: .current
        )
        #expect(suggestions.first?.proteinGrams == 45)

        // Simulate the NutritionView tap-to-add path:
        let resurrected = MealEntry(
            dayDate: today,
            slot: suggestions[0].slot,
            name: suggestions[0].name,
            kcal: suggestions[0].kcal,
            proteinGrams: suggestions[0].proteinGrams,
            carbGrams: suggestions[0].carbGrams,
            fatGrams: suggestions[0].fatGrams,
            status: .confirmed,
            source: .manual
        )
        context.insert(resurrected)

        // Today's confirmed protein sum should reflect the resurrected
        // entry (45 g), not the historical one (which lives on a
        // different dayDate).
        let todays = [resurrected]
        #expect(ProteinTotals.confirmedSum(from: todays) == 45)
    }
}
