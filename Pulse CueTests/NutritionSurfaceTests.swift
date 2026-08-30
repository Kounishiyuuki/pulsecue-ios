//
//  NutritionSurfaceTests.swift
//  Pulse CueTests
//
//  What the Nutrition screen leads with, and what it must never recompute.
//
//  Two different risks, so two groups of tests.
//
//  The first is drift in what the screen *says*: the numbers here are owned by
//  `DailyNutritionSummary`, shared with Home, and a redesign is exactly the
//  moment someone reaches for a local sum because it is right there. These
//  assert the contract still holds through the screen's own inputs.
//
//  The second is drift in what the screen *emphasises*. Nutrition had five
//  ways to add a meal on the first screen — an AI chip, three scanner chips
//  and four empty slot cards — none of which was wrong on its own. That is how
//  it happens: each addition is reasonable, and nobody removes one. The
//  ordering rules are pinned so a sixth has to be argued for in a diff.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct NutritionSurfaceTests {

    // MARK: - Store

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: DayLog.self, MealEntry.self, UserProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func insertProfile(_ context: ModelContext) {
        let profile = UserProfile()
        profile.heightCm = 172
        profile.goalWeightKg = 70
        context.insert(profile)
    }

    private func insertMeal(
        _ context: ModelContext,
        kcal: Int,
        protein: Int? = nil,
        status: MealStatus = .confirmed
    ) {
        context.insert(
            MealEntry(
                dayDate: Date(),
                slot: .lunch,
                name: "テスト",
                kcal: kcal,
                proteinGrams: protein,
                status: status,
                source: .manual
            )
        )
    }

    /// The summary exactly as the screen builds it.
    private func screenSummary(
        _ context: ModelContext,
        manualTargetKcal: Int? = nil
    ) throws -> DailyNutritionSummary {
        let today = DateUtils.startOfDay(Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
        let meals = try context.fetch(
            FetchDescriptor<MealEntry>(
                predicate: #Predicate<MealEntry> {
                    $0.dayDate >= today && $0.dayDate < tomorrow
                }
            )
        )
        let log = try context.fetch(FetchDescriptor<DayLog>())
            .first { DateUtils.startOfDay($0.date) == today }
        let profile = try context.fetch(FetchDescriptor<UserProfile>()).first
        return DailyNutritionSummary.make(
            dayLog: log,
            mealsForDay: meals,
            manualTargetKcal: manualTargetKcal,
            profileTargetKcal: profile?.targetIntake(
                currentWeightKg: LatestBodyWeightResolver.latestWeightKg(
                    modelContext: context
                )
            )
        )
    }

    // MARK: - The screen still reads the shared truth

    @Test func anEmptyDayShowsNothingConsumedAndTheWholeTargetRemaining() throws {
        let context = try makeContext()
        insertProfile(context)

        let summary = try screenSummary(context)

        #expect(summary.consumedKcal == nil)
        #expect(summary.remainingKcal == summary.targetKcal)
    }

    @Test func confirmedMealsDriveConsumedAndRemaining() throws {
        let context = try makeContext()
        insertProfile(context)
        insertMeal(context, kcal: 700, protein: 40)

        let summary = try screenSummary(context, manualTargetKcal: 2_400)

        #expect(summary.consumedKcal == 700)
        #expect(summary.remainingKcal == 1_700)
        #expect(summary.proteinGrams == 40)
    }

    @Test func aPendingEstimateIsNotShownAsIntake() throws {
        // The screen shows pending rows in its list; it must not add them to
        // the figure the user is deciding against.
        let context = try makeContext()
        insertProfile(context)
        insertMeal(context, kcal: 800, status: .pending)

        let summary = try screenSummary(context)

        #expect(summary.consumedKcal == 0)
        #expect(summary.intakeSource == .meals)
    }

    @Test func aManualOnlyDayStillShowsItsIntake() throws {
        let context = try makeContext()
        insertProfile(context)
        context.insert(DayLog(date: Date(), intakeCalories: 900))

        let summary = try screenSummary(context)

        #expect(summary.consumedKcal == 900)
        #expect(summary.intakeSource == .manualDayLog)
    }

    @Test func goingOverTargetIsShownAsAnOverage() throws {
        let context = try makeContext()
        insertProfile(context)
        insertMeal(context, kcal: 2_600)

        let summary = try screenSummary(context, manualTargetKcal: 2_400)

        #expect(summary.remainingKcal == -200)
    }

    @Test func withNoTargetTheScreenHasNoRemainingToShow() throws {
        let context = try makeContext()
        insertMeal(context, kcal: 500)

        let summary = try screenSummary(context)

        #expect(summary.targetKcal == nil)
        #expect(summary.remainingKcal == nil)
    }

    @Test func aManualTargetIsNamedAsSetRatherThanCalculated() throws {
        let context = try makeContext()
        insertProfile(context)

        let summary = try screenSummary(context, manualTargetKcal: 1_800)

        #expect(summary.targetSource == .manualOverride)
    }

    // MARK: - Home and Nutrition still describe the same day

    @Test func nutritionAndHomeAgreeOnAMixedDay() throws {
        // Both screens build the same type from the same rows. The value of
        // asserting it here is that a redesign is when a local sum gets
        // reintroduced — this fails if Nutrition ever grows its own.
        let context = try makeContext()
        insertProfile(context)
        context.insert(DayLog(date: Date(), intakeCalories: 2_000))
        insertMeal(context, kcal: 600, protein: 35)
        insertMeal(context, kcal: 900, status: .pending)

        let summary = try screenSummary(context, manualTargetKcal: 2_100)

        #expect(summary.consumedKcal == 600)
        #expect(summary.remainingKcal == 1_500)
        #expect(summary.proteinGrams == 35)
        #expect(HomeIntakeTile.displayedKcal(for: summary) == 600)
        #expect(HomeIntakeTile.opensNutrition(for: summary))
    }

    // MARK: - What leads the screen

    @Test func remainingOutranksConsumedOnTheCard() throws {
        // Remaining is the figure being acted on, and it was not on this
        // screen at all before — you had to subtract it yourself.
        let context = try makeContext()
        insertProfile(context)
        insertMeal(context, kcal: 700)

        let summary = try screenSummary(context, manualTargetKcal: 2_400)

        #expect(NutritionSurface.leadingFigure(for: summary) == .remaining)
    }

    @Test func withoutATargetTheCardLeadsWithWhatWasEaten() throws {
        // No target, no remaining. Leading with a blank would be worse than
        // leading with the one real number there is.
        let context = try makeContext()
        insertMeal(context, kcal: 700)

        let summary = try screenSummary(context)

        #expect(NutritionSurface.leadingFigure(for: summary) == .consumed)
    }

    @Test func proteinIsFirstLevelAndTheOtherMacrosAreNot() {
        #expect(NutritionSurface.isFirstLevel(.protein))
        #expect(NutritionSurface.isFirstLevel(.carbs) == false)
        #expect(NutritionSurface.isFirstLevel(.fat) == false)
    }

    @Test func thereIsExactlyOnePrimaryActionOnTheRoot() {
        // Not five. Manual, AI, OCR, barcode and photo are all ways to do the
        // one thing, and asking which before the user has said they want to
        // do it is the choice this removes.
        #expect(NutritionSurface.primaryActions == 1)
    }

    @Test func everyInputMethodIsReachableAfterTheOneAction() {
        // Demoting them must not lose any of them.
        let methods = NutritionSurface.inputMethods
        #expect(methods.contains(.manual))
        #expect(methods.contains(.ai))
        #expect(methods.contains(.nutritionLabel))
        #expect(methods.contains(.barcode))
        #expect(methods.contains(.photo))
    }

    @Test func noInputMethodIsPromotedToTheRoot() {
        for method in NutritionSurface.inputMethods {
            #expect(NutritionSurface.isRootPrimary(method) == false)
        }
    }

    @Test func historyAndTrendsSitBelowTodaysFigures() {
        #expect(NutritionSurface.rank(.todayIntake) < NutritionSurface.rank(.todayMeals))
        #expect(NutritionSurface.rank(.todayMeals) < NutritionSurface.rank(.recentAndFavourites))
        #expect(NutritionSurface.rank(.recentAndFavourites) < NutritionSurface.rank(.weeklyTrend))
    }

    // MARK: - The order the screen renders

    @Test func theRenderedOrderIsTheRankedOrder() {
        // `NutritionView` iterates `orderedSections`. Before it did, this
        // file described an order the screen was free to ignore.
        let ordered = NutritionSurface.orderedSections
        let ranks = ordered.map { NutritionSurface.rank($0) }

        #expect(ranks == ranks.sorted())
    }

    @Test func everySectionIsRendered() {
        // A section that exists in the ranking but never reaches the screen is
        // the failure this whole file is meant to prevent, one level down.
        let expected: [NutritionSurface.Section] = [
            .todayIntake, .addMeal, .todayMeals,
            .pendingEstimates, .recentAndFavourites, .weeklyTrend
        ]
        #expect(NutritionSurface.orderedSections == expected)
    }

    @Test func todaysDecisionComesBeforeTodaysRecord() {
        let ordered = NutritionSurface.orderedSections
        let intake = ordered.firstIndex(of: .todayIntake)
        let meals = ordered.firstIndex(of: .todayMeals)
        let trend = ordered.firstIndex(of: .weeklyTrend)

        #expect(intake != nil && meals != nil && trend != nil)
        #expect(intake! < meals!)
        #expect(meals! < trend!)
    }
}
