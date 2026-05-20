//
//  BarcodeReviewSaveTests.swift
//  Pulse CueTests
//
//  Confirm/save-flow tests for the barcode product review screen
//  (PR #45). They exercise `BarcodeProductReviewView.makeConfirmedEntry`
//  — the pure meal-construction step extracted from the screen's
//  `save()` so the confirm logic is testable without a SwiftUI host —
//  and the insert + `NutritionLedger` sync that `save()` performs
//  around it.
//
//  Boundary under test (PR #45):
//   - confirm produces a `.confirmed`, `.barcode` MealEntry on today's
//     local date, preserving the reviewed name / calories / protein /
//     carbs / fat / note
//   - DayLog intake updates only after the confirmed meal is inserted
//     and synced through the existing NutritionLedger path
//   - building the candidate entry persists nothing on its own:
//     backing out of the review screen (cancel) leaves no MealEntry
//
//  Tests use an in-memory SwiftData ModelContainer and never touch
//  the network.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct BarcodeReviewSaveTests {

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

    /// Builds a confirmed entry the same way `BarcodeProductReviewView.save()`
    /// does, with overridable form fields.
    private func makeEntry(
        day: Date = Date(),
        slot: MealSlot = .lunch,
        name: String = "テスト商品",
        kcalText: String = "250",
        proteinText: String = "",
        carbText: String = "",
        fatText: String = "",
        note: String = ""
    ) -> MealEntry {
        BarcodeProductReviewView.makeConfirmedEntry(
            day: day,
            slot: slot,
            name: name,
            kcalText: kcalText,
            proteinText: proteinText,
            carbText: carbText,
            fatText: fatText,
            note: note
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

    @Test func confirmUsesBarcodeSource() {
        let entry = makeEntry()
        #expect(entry.source == .barcode)
        #expect(entry.source.label == "バーコード")
    }

    @Test func confirmKeepsEditedSlotAndName() {
        let entry = makeEntry(slot: .breakfast, name: "  グラノーラ  ")
        #expect(entry.slot == .breakfast)
        #expect(entry.name == "グラノーラ")
    }

    @Test func confirmPreservesProteinValue() {
        let entry = makeEntry(proteinText: "13")
        #expect(entry.proteinGrams == 13)
    }

    @Test func confirmWithoutProteinLeavesProteinNil() {
        #expect(makeEntry(proteinText: "").proteinGrams == nil)
    }

    @Test func confirmPreservesCarbFatAndNote() {
        let entry = makeEntry(carbText: "55", fatText: "12", note: "半分だけ食べた")
        #expect(entry.carbGrams == 55)
        #expect(entry.fatGrams == 12)
        #expect(entry.note == "半分だけ食べた")
    }

    @Test func confirmWithBlankNameFallsBackToSlotLabel() {
        let entry = makeEntry(slot: .dinner, name: "   ")
        #expect(entry.name == MealSlot.dinner.label)
    }

    @Test func confirmWithBlankNoteStoresNil() {
        #expect(makeEntry(note: "   ").note == nil)
    }

    @Test func confirmTreatsNonNumericCaloriesAsZero() {
        // The 「記録する」 button is gated by isFormValid, but the
        // builder must still be total: a non-numeric field is 0.
        #expect(makeEntry(kcalText: "").kcal == 0)
    }

    // MARK: - Save → DayLog sync

    @Test func confirmSyncsDayLogIntakeThroughNutritionLedger() throws {
        let context = try Self.makeContext()
        let entry = makeEntry(slot: .lunch, name: "弁当", kcalText: "640", proteinText: "25")

        // Mirrors save(): insert the confirmed meal, then sync.
        context.insert(entry)
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)

        #expect(DayLogStore.fetch(date: Date(), modelContext: context)?.intakeCalories == 640)
        #expect(NutritionLedger.confirmedTotal(for: Date(), modelContext: context) == 640)
    }

    // MARK: - No save before confirmation (cancel boundary)

    @Test func candidateBuildIsInertUntilExplicitlyInserted() throws {
        let context = try Self.makeContext()

        // Building the entry mirrors what the review screen holds
        // before the user taps 記録する. Until it is inserted, the
        // store stays empty — backing out (cancel) leaves no trace.
        let entry = makeEntry(slot: .snack, name: "プロテインバー", kcalText: "180")
        #expect(try context.fetch(FetchDescriptor<MealEntry>()).isEmpty)
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)
        #expect(try context.fetch(FetchDescriptor<DayLog>()).isEmpty)

        // Confirm = insert + sync. This is the only path that writes.
        context.insert(entry)
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)
        #expect(try context.fetch(FetchDescriptor<MealEntry>()).count == 1)
        #expect(DayLogStore.fetch(date: Date(), modelContext: context)?.intakeCalories == 180)
    }

    @Test func lookupResultCandidateDoesNotPersistAnything() throws {
        let context = try Self.makeContext()

        // A successful lookup yields only a ProductLookupResult value.
        // Holding one must never create a MealEntry on its own.
        _ = ProductLookupResult(
            barcode: "4901234567894",
            name: "未確定の商品",
            kcal: 300,
            proteinGrams: 12,
            servingDescription: "100 g"
        )
        #expect(try context.fetch(FetchDescriptor<MealEntry>()).isEmpty)
    }
}
