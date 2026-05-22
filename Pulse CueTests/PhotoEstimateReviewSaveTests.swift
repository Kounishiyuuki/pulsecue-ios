//
//  PhotoEstimateReviewSaveTests.swift
//  Pulse CueTests
//
//  Confirm/save-flow tests for the mock photo estimation review
//  screen. They exercise `ConfirmedMealEntryFactory.make` with
//  `source: .ai` — the shared pure meal-construction step the
//  screen's `save()` uses — and the insert + `NutritionLedger` sync
//  that `save()` performs around it.
//
//  Boundary under test:
//   - confirm produces a `.confirmed`, `.ai` MealEntry on today's
//     local date, preserving the reviewed name / calories / protein /
//     carbs / fat / note
//   - DayLog intake updates only after the confirmed meal is inserted
//     and synced through the existing NutritionLedger path
//   - building the candidate entry persists nothing on its own:
//     backing out / cancelling the review screen leaves no MealEntry
//
//  Tests use an in-memory SwiftData ModelContainer and never run AI
//  or networking.
//

import Foundation
import SwiftData
import Testing
import UIKit
@testable import Pulse_Cue

@MainActor
struct PhotoEstimateReviewSaveTests {

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

    /// Builds a confirmed entry the same way
    /// `PhotoEstimateReviewView.save()` does, with overridable fields.
    private func makeEntry(
        day: Date = Date(),
        slot: MealSlot = .lunch,
        name: String = "推定された食事（モック）",
        kcalText: String = "480",
        proteinText: String = "",
        carbText: String = "",
        fatText: String = "",
        note: String = ""
    ) -> MealEntry {
        ConfirmedMealEntryFactory.make(
            day: day,
            slot: slot,
            name: name,
            kcalText: kcalText,
            proteinText: proteinText,
            carbText: carbText,
            fatText: fatText,
            note: note,
            source: .ai
        )
    }

    // MARK: - Confirmed entry shape

    @Test func confirmCreatesMealForTodaysLocalDate() {
        let entry = makeEntry(day: Date())
        #expect(entry.dayDate == DateUtils.startOfDay(Date()))
    }

    @Test func confirmUsesConfirmedStatus() {
        #expect(makeEntry().status == .confirmed)
    }

    @Test func confirmUsesAISource() {
        let entry = makeEntry()
        #expect(entry.source == .ai)
        #expect(entry.source.label == "AI 推定")
    }

    @Test func confirmKeepsEditedSlotAndName() {
        let entry = makeEntry(slot: .dinner, name: "  チキンサラダ  ")
        #expect(entry.slot == .dinner)
        #expect(entry.name == "チキンサラダ")
    }

    @Test func confirmPreservesProteinValue() {
        #expect(makeEntry(proteinText: "22").proteinGrams == 22)
    }

    @Test func confirmWithoutProteinLeavesProteinNil() {
        #expect(makeEntry(proteinText: "").proteinGrams == nil)
    }

    @Test func confirmPreservesCarbFatAndNote() {
        let entry = makeEntry(carbText: "40", fatText: "15", note: "写真から推定")
        #expect(entry.carbGrams == 40)
        #expect(entry.fatGrams == 15)
        #expect(entry.note == "写真から推定")
    }

    @Test func confirmWithBlankNameFallsBackToSlotLabel() {
        let entry = makeEntry(slot: .snack, name: "   ")
        #expect(entry.name == MealSlot.snack.label)
    }

    @Test func confirmTreatsNonNumericCaloriesAsZero() {
        // The 「食事として保存」 button is gated by isFormValid, but the
        // builder must still be total: a non-numeric field is 0.
        #expect(makeEntry(kcalText: "").kcal == 0)
    }

    // MARK: - Save → DayLog sync

    @Test func confirmSyncsDayLogIntakeThroughNutritionLedger() throws {
        let context = try Self.makeContext()
        let entry = makeEntry(slot: .lunch, name: "推定ランチ", kcalText: "480", proteinText: "22")

        // Mirrors save(): insert the confirmed meal, then sync.
        context.insert(entry)
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)

        #expect(DayLogStore.fetch(date: Date(), modelContext: context)?.intakeCalories == 480)
        #expect(NutritionLedger.confirmedTotal(for: Date(), modelContext: context) == 480)
    }

    // MARK: - No save before confirmation (cancel boundary)

    @Test func candidateBuildIsInertUntilExplicitlyInserted() throws {
        let context = try Self.makeContext()

        // Building the entry mirrors what the review screen holds
        // before the user taps 食事として保存. Until it is inserted,
        // the store stays empty — cancelling leaves no trace.
        let entry = makeEntry(slot: .lunch, name: "推定ランチ", kcalText: "480")
        #expect(try context.fetch(FetchDescriptor<MealEntry>()).isEmpty)
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)
        #expect(try context.fetch(FetchDescriptor<DayLog>()).isEmpty)

        // Confirm = insert + sync. This is the only path that writes.
        context.insert(entry)
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)
        #expect(try context.fetch(FetchDescriptor<MealEntry>()).count == 1)
        #expect(DayLogStore.fetch(date: Date(), modelContext: context)?.intakeCalories == 480)
    }

    @Test func mockEstimateCandidateDoesNotPersistAnything() async throws {
        let context = try Self.makeContext()

        // Running the mock estimator yields only a PhotoFoodEstimate
        // value. Holding one must never create a MealEntry on its own.
        _ = try await MockPhotoFoodEstimator()
            .estimate(input: PhotoFoodEstimationInput(image: nil))
        #expect(try context.fetch(FetchDescriptor<MealEntry>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<DayLog>()).isEmpty)
    }
}
