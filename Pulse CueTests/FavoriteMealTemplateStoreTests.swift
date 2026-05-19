//
//  FavoriteMealTemplateStoreTests.swift
//  Pulse CueTests
//
//  Locks in the favorite-meal-template behavior used by NutritionView's
//  「よく使う食事」 quick-add card.
//
//  Coverage:
//   - empty store starts empty
//   - adding a template persists it
//   - duplicate (name, kcal) is rejected idempotently
//   - removing a template drops it
//   - removing a non-existent id is a safe no-op
//   - protein / slot survive a UserDefaults round-trip (app relaunch)
//   - templates remain independent from the MealEntry recent-meal flow
//   - tap-to-add from a template creates a confirmed manual MealEntry
//     anchored to today and DayLog tracks the new kcal via the
//     existing NutritionLedger ledger path
//   - ProteinTotals sees protein from a template-added MealEntry
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct FavoriteMealTemplateStoreTests {

    // MARK: - Helpers

    /// Fresh, in-memory UserDefaults backed by a unique suite name so
    /// tests do not leak templates into the real app domain.
    private static func makeDefaults(label: String = #function) -> UserDefaults {
        let suite = "FavoriteMealTemplateStoreTests.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static func makeStore(defaults: UserDefaults? = nil) -> FavoriteMealTemplateStore {
        FavoriteMealTemplateStore(
            defaults: defaults ?? makeDefaults(),
            storageKey: "favoriteMealTemplates.test"
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

    // MARK: - Basic store behavior

    @Test func emptyStoreStartsEmpty() {
        let store = Self.makeStore()
        #expect(store.templates.isEmpty)
    }

    @Test func addingTemplateAppendsIt() {
        let store = Self.makeStore()
        let added = store.add(.init(name: "鶏むね 200g", kcal: 320, proteinGrams: 45, slot: .lunch))
        #expect(added == true)
        #expect(store.templates.count == 1)
        #expect(store.templates.first?.name == "鶏むね 200g")
        #expect(store.templates.first?.kcal == 320)
        #expect(store.templates.first?.proteinGrams == 45)
        #expect(store.templates.first?.slot == .lunch)
    }

    @Test func duplicateNameAndKcalIsRejectedIdempotently() {
        let store = Self.makeStore()
        let first = store.add(.init(name: "鶏むね", kcal: 300, slot: .lunch))
        let second = store.add(.init(name: "鶏むね", kcal: 300, slot: .dinner))
        #expect(first == true)
        #expect(second == false) // dedup key already present
        #expect(store.templates.count == 1)
        // First-write wins so the original slot is preserved.
        #expect(store.templates.first?.slot == .lunch)
    }

    @Test func differentKcalProducesDistinctTemplates() {
        let store = Self.makeStore()
        store.add(.init(name: "鶏むね", kcal: 300, slot: .lunch))
        store.add(.init(name: "鶏むね", kcal: 400, slot: .lunch))
        #expect(store.templates.count == 2)
    }

    @Test func removeDropsMatchingTemplate() {
        let store = Self.makeStore()
        let target = FavoriteMealTemplate(name: "サラダ", kcal: 150, slot: .lunch)
        store.add(target)
        store.add(.init(name: "鶏むね", kcal: 300, slot: .dinner))
        store.remove(target)
        #expect(store.templates.count == 1)
        #expect(store.templates.first?.name == "鶏むね")
    }

    @Test func removeUnknownIdIsNoOp() {
        let store = Self.makeStore()
        store.add(.init(name: "サラダ", kcal: 150, slot: .lunch))
        store.remove(.init(id: UUID(), name: "ghost", kcal: 0, slot: .snack))
        #expect(store.templates.count == 1)
    }

    @Test func containsLooksUpByNameAndKcal() {
        let store = Self.makeStore()
        store.add(.init(name: "鶏むね", kcal: 300, slot: .lunch))
        #expect(store.contains(name: "鶏むね", kcal: 300) == true)
        #expect(store.contains(name: "鶏むね", kcal: 301) == false)
        #expect(store.contains(name: "サラダ", kcal: 300) == false)
    }

    // MARK: - Persistence

    /// Templates must survive app relaunch (i.e. a fresh store
    /// instantiated against the same UserDefaults). Round-trips
    /// protein + slot so callers can rely on those fields after
    /// reopening the app.
    @Test func roundTripsThroughUserDefaults() {
        let defaults = Self.makeDefaults()
        let key = "favoriteMealTemplates.relaunch.\(UUID().uuidString)"

        let original = FavoriteMealTemplateStore(defaults: defaults, storageKey: key)
        original.add(.init(name: "オートミール", kcal: 250, proteinGrams: 10, slot: .breakfast))
        original.add(.init(name: "鶏むね 200g", kcal: 320, proteinGrams: 45, slot: .dinner))

        // Simulate relaunch: brand-new store reads the same suite/key.
        let reopened = FavoriteMealTemplateStore(defaults: defaults, storageKey: key)
        #expect(reopened.templates.count == 2)

        let oats = reopened.templates.first(where: { $0.name == "オートミール" })
        #expect(oats?.kcal == 250)
        #expect(oats?.proteinGrams == 10)
        #expect(oats?.slot == .breakfast)

        let chicken = reopened.templates.first(where: { $0.name == "鶏むね 200g" })
        #expect(chicken?.proteinGrams == 45)
        #expect(chicken?.slot == .dinner)
    }

    @Test func removalPersistsAcrossRelaunch() {
        let defaults = Self.makeDefaults()
        let key = "favoriteMealTemplates.relaunch.remove.\(UUID().uuidString)"

        let original = FavoriteMealTemplateStore(defaults: defaults, storageKey: key)
        let pinned = FavoriteMealTemplate(name: "サラダ", kcal: 150, slot: .lunch)
        original.add(pinned)
        original.add(.init(name: "鶏むね", kcal: 300, slot: .dinner))
        original.remove(pinned)

        let reopened = FavoriteMealTemplateStore(defaults: defaults, storageKey: key)
        #expect(reopened.templates.count == 1)
        #expect(reopened.templates.first?.name == "鶏むね")
    }

    // MARK: - Integration with MealEntry / NutritionLedger / ProteinTotals

    /// Tap-to-add a template must create today's MealEntry as
    /// `.confirmed` + `.manual` (same contract as recent-meal shortcuts),
    /// anchored to today's local startOfDay, and run through
    /// `NutritionLedger.syncDayLogIntake` so DayLog.intakeCalories
    /// tracks the new kcal.
    @Test func tappingTemplateCreatesTodayConfirmedManualEntry() throws {
        let context = try Self.makeContext()
        let today = Date()
        let todayStart = Calendar.current.startOfDay(for: today)

        let template = FavoriteMealTemplate(
            name: "鶏むね 200g",
            kcal: 320,
            proteinGrams: 45,
            slot: .dinner
        )

        // Simulate the tap-to-add path from NutritionView.
        let fresh = MealEntry(
            dayDate: today,
            slot: template.slot,
            name: template.name,
            kcal: template.kcal,
            proteinGrams: template.proteinGrams,
            status: .confirmed,
            source: .manual
        )
        context.insert(fresh)
        NutritionLedger.syncDayLogIntake(for: today, modelContext: context)

        #expect(fresh.dayDate == todayStart)
        #expect(fresh.status == .confirmed)
        #expect(fresh.source == .manual)
        #expect(fresh.kcal == 320)
        #expect(fresh.proteinGrams == 45)
        #expect(fresh.slot == .dinner)
        #expect(fresh.name == "鶏むね 200g")

        let dayLog = DayLogStore.fetch(date: todayStart, modelContext: context)
        #expect(dayLog?.intakeCalories == 320)
    }

    @Test func proteinTotalsIncludeTemplateAddedMeal() throws {
        let context = try Self.makeContext()
        let today = Date()

        let template = FavoriteMealTemplate(
            name: "プロテインシェイク",
            kcal: 200,
            proteinGrams: 30,
            slot: .snack
        )
        let fresh = MealEntry(
            dayDate: today,
            slot: template.slot,
            name: template.name,
            kcal: template.kcal,
            proteinGrams: template.proteinGrams,
            status: .confirmed,
            source: .manual
        )
        context.insert(fresh)
        NutritionLedger.syncDayLogIntake(for: today, modelContext: context)

        let daily = ProteinTotals.daily(meals: [fresh], kcalTarget: 2000)
        #expect(daily.confirmedGrams == 30)
    }

    /// Favorite templates do NOT add themselves to recent-meal
    /// suggestions, and vice versa: removing a meal does not erase
    /// a pinned template. The two surfaces share no state.
    @Test func favoritesAndRecentMealsAreIndependent() throws {
        let store = Self.makeStore()
        let context = try Self.makeContext()
        let today = Date()
        let pastDay = Calendar.current.date(byAdding: .day, value: -3, to: today)!

        // A confirmed manual meal that produces a recent-meal suggestion.
        let recent = MealEntry(
            dayDate: pastDay, slot: .lunch, name: "サラダ", kcal: 150,
            status: .confirmed, source: .manual, createdAt: pastDay
        )
        context.insert(recent)

        let suggestions = RecentMealSuggestions.suggest(
            from: [recent], today: today, calendar: .current
        )
        #expect(suggestions.count == 1)

        // Pin a *different* template — store stays disjoint from
        // recent-meal suggestions.
        store.add(.init(name: "鶏むね", kcal: 300, slot: .dinner))
        #expect(store.templates.count == 1)
        #expect(store.templates.first?.name == "鶏むね")

        // Now delete the underlying recent meal. The pinned template
        // must survive.
        context.delete(recent)
        #expect(store.templates.count == 1)
        #expect(store.templates.first?.name == "鶏むね")
    }
}
