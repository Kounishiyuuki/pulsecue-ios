//
//  NutritionLabelReviewSaveTests.swift
//  Pulse CueTests
//
//  Confirm/save-flow tests for the nutrition-label OCR review screen.
//  They exercise `ConfirmedMealEntryFactory.make` with `source: .ocr`
//  — the shared pure meal-construction step the screen's `save()`
//  uses — and the insert + `NutritionLedger` sync that `save()`
//  performs around it.
//
//  Boundary under test:
//   - confirm produces a `.confirmed`, `.ocr` MealEntry on today's
//     local date, preserving the reviewed name / calories / protein /
//     carbs / fat / note
//   - DayLog intake updates only after the confirmed meal is inserted
//     and synced through the existing NutritionLedger path
//   - building the candidate entry persists nothing on its own:
//     backing out of the review screen (cancel) leaves no MealEntry
//
//  Tests use an in-memory SwiftData ModelContainer and never run OCR.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct NutritionLabelReviewSaveTests {

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
    /// `NutritionLabelReviewView.save()` does, with overridable fields.
    private func makeEntry(
        day: Date = Date(),
        slot: MealSlot = .snack,
        name: String = "テスト商品",
        kcalText: String = "240",
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
            source: .ocr
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

    @Test func confirmUsesOCRSource() {
        let entry = makeEntry()
        #expect(entry.source == .ocr)
        #expect(entry.source.label == "OCR")
    }

    @Test func confirmKeepsEditedSlotAndName() {
        let entry = makeEntry(slot: .breakfast, name: "  プロテインバー  ")
        #expect(entry.slot == .breakfast)
        #expect(entry.name == "プロテインバー")
    }

    @Test func confirmPreservesProteinValue() {
        #expect(makeEntry(proteinText: "18").proteinGrams == 18)
    }

    @Test func confirmWithoutProteinLeavesProteinNil() {
        #expect(makeEntry(proteinText: "").proteinGrams == nil)
    }

    @Test func confirmPreservesCarbFatAndNote() {
        let entry = makeEntry(carbText: "30", fatText: "9", note: "ラベルから読み取り")
        #expect(entry.carbGrams == 30)
        #expect(entry.fatGrams == 9)
        #expect(entry.note == "ラベルから読み取り")
    }

    @Test func confirmWithBlankNameFallsBackToSlotLabel() {
        let entry = makeEntry(slot: .lunch, name: "   ")
        #expect(entry.name == MealSlot.lunch.label)
    }

    @Test func confirmTreatsNonNumericCaloriesAsZero() {
        // The 「食事として保存」 button is gated by isFormValid, but the
        // builder must still be total: a non-numeric field is 0.
        #expect(makeEntry(kcalText: "").kcal == 0)
    }

    // MARK: - Save → DayLog sync

    @Test func confirmSyncsDayLogIntakeThroughNutritionLedger() throws {
        let context = try Self.makeContext()
        let entry = makeEntry(slot: .lunch, name: "サラダチキン", kcalText: "115", proteinText: "24")

        // Mirrors save(): insert the confirmed meal, then sync.
        context.insert(entry)
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)

        #expect(DayLogStore.fetch(date: Date(), modelContext: context)?.intakeCalories == 115)
        #expect(NutritionLedger.confirmedTotal(for: Date(), modelContext: context) == 115)
    }

    // MARK: - No save before confirmation (cancel boundary)

    @Test func candidateBuildIsInertUntilExplicitlyInserted() throws {
        let context = try Self.makeContext()

        // Building the entry mirrors what the review screen holds
        // before the user taps 食事として保存. Until it is inserted,
        // the store stays empty — backing out (cancel) leaves no trace.
        let entry = makeEntry(slot: .snack, name: "ヨーグルト", kcalText: "90")
        #expect(try context.fetch(FetchDescriptor<MealEntry>()).isEmpty)
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)
        #expect(try context.fetch(FetchDescriptor<DayLog>()).isEmpty)

        // Confirm = insert + sync. This is the only path that writes.
        context.insert(entry)
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)
        #expect(try context.fetch(FetchDescriptor<MealEntry>()).count == 1)
        #expect(DayLogStore.fetch(date: Date(), modelContext: context)?.intakeCalories == 90)
    }

    @Test func ocrCandidateDoesNotPersistAnything() throws {
        let context = try Self.makeContext()

        // A recognized label yields only a NutritionLabelCandidate
        // value. Holding one must never create a MealEntry on its own.
        _ = NutritionLabelCandidate(kcal: 240, proteinGrams: 9)
        #expect(try context.fetch(FetchDescriptor<MealEntry>()).isEmpty)
    }
}
