//
//  HomeNutritionWiringTests.swift
//  Pulse CueTests
//
//  Whether the screens are actually wired to the shared truth.
//
//  The previous round's equality test called `DailyNutritionSummary.make`
//  twice with the same arguments and asserted the results matched, which is
//  true of any pure function and says nothing about whether Home or Nutrition
//  calls it. Both of the bugs that survived that test were wiring bugs: a
//  tile still reading `DayLog.intakeCalories` directly, and two screens
//  resolving "latest weight" from different windows.
//
//  So these tests go through a real `ModelContext` with real rows, and build
//  each screen's inputs the way the screen builds them — including the query
//  bounds. A test that constructs the inputs by hand cannot catch a screen
//  that looks in the wrong place for them.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct HomeNutritionWiringTests {

    // MARK: - Store

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: DayLog.self, MealEntry.self, UserProfile.self,
            Routine.self, Step.self, Session.self, StepResult.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func insertProfile(_ context: ModelContext) -> UserProfile {
        let profile = UserProfile()
        profile.heightCm = 172
        profile.goalWeightKg = 70
        context.insert(profile)
        return profile
    }

    private func insertLog(
        _ context: ModelContext,
        daysAgo: Int,
        weightKg: Double? = nil,
        intake: Int? = nil
    ) -> DayLog {
        let date = Calendar.current.date(
            byAdding: .day, value: -daysAgo, to: DateUtils.startOfDay(Date())
        ) ?? Date()
        let log = DayLog(date: date, intakeCalories: intake, weightKg: weightKg)
        context.insert(log)
        return log
    }

    private func insertMeal(_ context: ModelContext, kcal: Int, protein: Int? = nil) {
        context.insert(
            MealEntry(
                dayDate: Date(),
                slot: .lunch,
                name: "テスト",
                kcal: kcal,
                proteinGrams: protein,
                status: .confirmed,
                source: .manual
            )
        )
    }

    /// Every meal for today, scoped the way both screens scope them.
    ///
    /// Deliberately unfiltered: ownership depends on pending rows too, and
    /// filtering here would hide exactly the case these tests exist for.
    private func mealsToday(_ context: ModelContext) throws -> [MealEntry] {
        let today = DateUtils.startOfDay(Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
        return try context.fetch(
            FetchDescriptor<MealEntry>(
                predicate: #Predicate<MealEntry> {
                    $0.dayDate >= today && $0.dayDate < tomorrow
                }
            )
        )
    }

    private func todayLog(_ context: ModelContext) throws -> DayLog? {
        let today = DateUtils.startOfDay(Date())
        return try context.fetch(FetchDescriptor<DayLog>())
            .first { DateUtils.startOfDay($0.date) == today }
    }

    /// Builds the summary through the call both screens make.
    ///
    /// This used to assemble the target priority chain itself — resolve the
    /// override, ask the profile, hand both to `make`. That is a description
    /// of the wiring rather than the wiring, and it would keep passing if Home
    /// and Nutrition stopped resolving targets that way. `forDay` is the
    /// production entry point; the only thing left to arrange here is the
    /// stored state.
    private func screenSummary(
        _ context: ModelContext,
        manualTargetKcal: Int? = nil
    ) throws -> DailyNutritionSummary {
        DailyNutritionSummary.forDay(
            Date(),
            dayLog: try todayLog(context),
            mealsForDay: try mealsToday(context),
            profile: try context.fetch(FetchDescriptor<UserProfile>()).first,
            currentWeightKg: LatestBodyWeightResolver.latestWeightKg(modelContext: context),
            targetSettings: targetSettings(intakeOverride: manualTargetKcal)
        )
    }

    /// A settings value carrying the manual intake override, since that is how
    /// a typed target actually reaches the screens.
    private func targetSettings(intakeOverride: Int?) -> HealthTargetSettings {
        guard let intakeOverride else { return .empty }
        return HealthTargetSettings(
            defaults: HealthTargets(intakeCalories: intakeOverride)
        )
    }

    // MARK: - Consumed: one number everywhere on the day

    @Test func confirmedMealsOverrideAStaleManualIntakeEverywhere() throws {
        // The reported state: meals say 500, the raw DayLog field still says
        // 2000. Home's card, Home's lower tile and Nutrition must all say 500.
        let context = try makeContext()
        _ = insertProfile(context)
        _ = insertLog(context, daysAgo: 0, intake: 2_000)
        insertMeal(context, kcal: 500)

        let summary = try screenSummary(context)

        #expect(summary.consumedKcal == 500)
        #expect(summary.intakeSource == .meals)
        // And the lower tile renders exactly this, not the 2000 underneath.
        let storedRawValue = try todayLog(context)?.intakeCalories
        #expect(storedRawValue == 2_000)
        #expect(summary.consumedKcal != storedRawValue)
    }

    @Test func mealOwnedDaysDoNotOfferManualCalorieEntry() throws {
        // A value the user could save and no screen would ever show is worse
        // than no entry point at all.
        let context = try makeContext()
        _ = insertProfile(context)
        _ = insertLog(context, daysAgo: 0, intake: 2_000)
        insertMeal(context, kcal: 500)

        let summary = try screenSummary(context)
        #expect(summary.acceptsManualIntakeEntry == false)
    }

    @Test func manualOnlyDaysKeepTheQuickInput() throws {
        let context = try makeContext()
        _ = insertProfile(context)
        _ = insertLog(context, daysAgo: 0, intake: 800)

        let summary = try screenSummary(context)

        #expect(summary.consumedKcal == 800)
        #expect(summary.intakeSource == .manualDayLog)
        #expect(summary.acceptsManualIntakeEntry)
    }

    @Test func aPendingOnlyDayIsMealOwnedWithoutCountingTheEstimate() throws {
        // The rule that closes this round. `NutritionLedger` treats *any*
        // meal as taking ownership of the day, so a manual figure typed while
        // a pending estimate exists is cleared by the next confirm or delete.
        // The read side now agrees: the day is meal-owned, and the estimate
        // still does not count as intake.
        let context = try makeContext()
        _ = insertProfile(context)
        _ = insertLog(context, daysAgo: 0, intake: 1_200)
        context.insert(
            MealEntry(
                dayDate: Date(), slot: .lunch, name: "推定",
                kcal: 800, status: .pending, source: .ai
            )
        )

        let summary = try screenSummary(context)

        #expect(summary.intakeSource == .meals)
        // Not 800 — unconfirmed — and not the 1200 underneath either.
        #expect(summary.consumedKcal == 0)
        #expect(summary.acceptsManualIntakeEntry == false)
    }

    @Test func aPendingOnlyDayAgreesWithTheLedgersOwnershipPredicate() throws {
        // Read and write must key off the same question. This asserts they
        // do, rather than that they happen to today.
        let context = try makeContext()
        _ = insertProfile(context)
        context.insert(
            MealEntry(
                dayDate: Date(), slot: .lunch, name: "推定",
                kcal: 800, status: .pending, source: .ai
            )
        )

        let summary = try screenSummary(context)
        let ledgerSaysMealOwned = NutritionLedger.hasAnyMeal(
            for: Date(), modelContext: context
        )

        #expect(ledgerSaysMealOwned)
        #expect((summary.intakeSource == .meals) == ledgerSaysMealOwned)
    }

    // MARK: - The lower tile renders and routes from the same truth

    @Test func theLowerTileShowsTheSharedFigureNotTheStoredOne() throws {
        // The reviewer's exact case. The stored field still holds 2000; the
        // tile must render 500, the same as the card above it.
        let context = try makeContext()
        _ = insertProfile(context)
        _ = insertLog(context, daysAgo: 0, intake: 2_000)
        insertMeal(context, kcal: 500)

        let summary = try screenSummary(context)

        #expect(HomeIntakeTile.displayedKcal(for: summary) == 500)
        #expect(HomeIntakeTile.displayedKcal(for: summary) == summary.consumedKcal)
    }

    @Test func theLowerTileRoutesToNutritionOnMealOwnedDays() throws {
        let context = try makeContext()
        _ = insertProfile(context)
        _ = insertLog(context, daysAgo: 0, intake: 2_000)
        insertMeal(context, kcal: 500)

        let summary = try screenSummary(context)

        #expect(HomeIntakeTile.opensNutrition(for: summary))
        #expect(HomeIntakeTile.accessibilityHint(for: summary) == "栄養タブで食事を編集")
    }

    @Test func theLowerTileKeepsTheQuickInputWhenNoMealsOwnTheDay() throws {
        let context = try makeContext()
        _ = insertProfile(context)
        _ = insertLog(context, daysAgo: 0, intake: 800)

        let summary = try screenSummary(context)

        #expect(HomeIntakeTile.displayedKcal(for: summary) == 800)
        #expect(HomeIntakeTile.opensNutrition(for: summary) == false)
        #expect(HomeIntakeTile.accessibilityHint(for: summary) == "摂取を入力")
    }

    @Test func anEmptyDayStillOffersTheQuickInput() throws {
        let context = try makeContext()
        _ = insertProfile(context)

        let summary = try screenSummary(context)

        #expect(HomeIntakeTile.displayedKcal(for: summary) == nil)
        #expect(HomeIntakeTile.opensNutrition(for: summary) == false)
    }

    // MARK: - The meal lifecycle, through the real ledger
    //
    //  These drive `NutritionLedger` exactly as the app does — create,
    //  confirm, delete — and read the summary after each step. The bug this
    //  round fixed was a disagreement between the read side and the write
    //  side, which only shows up when both actually run.

    @Test func creatingAPendingMealTakesOwnershipFromTheManualValue() throws {
        let context = try makeContext()
        _ = insertProfile(context)
        _ = insertLog(context, daysAgo: 0, intake: 700)

        let before = try screenSummary(context)
        #expect(before.intakeSource == .manualDayLog)
        #expect(before.consumedKcal == 700)
        #expect(before.acceptsManualIntakeEntry)

        context.insert(
            MealEntry(
                dayDate: Date(), slot: .lunch, name: "推定",
                kcal: 800, status: .pending, source: .ai
            )
        )
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)

        let after = try screenSummary(context)
        #expect(after.intakeSource == .meals)
        #expect(after.consumedKcal == 0)
        #expect(after.acceptsManualIntakeEntry == false)
    }

    @Test func confirmingAPendingMealMovesConsumedFromZeroToTheTotal() throws {
        let context = try makeContext()
        _ = insertProfile(context)
        let meal = MealEntry(
            dayDate: Date(), slot: .lunch, name: "昼食",
            kcal: 500, status: .pending, source: .manual
        )
        context.insert(meal)
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)

        let before = try screenSummary(context)
        #expect(before.consumedKcal == 0)

        meal.statusRaw = MealStatus.confirmed.rawValue
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)

        let after = try screenSummary(context)
        #expect(after.consumedKcal == 500)
        #expect(after.intakeSource == .meals)
        // Never dips back through the manual fallback on the way.
        #expect(after.acceptsManualIntakeEntry == false)
    }

    @Test func deletingTheLastPendingMealDoesNotResurrectTheOldManualValue() throws {
        // The quietest failure available: a figure the user typed, hidden
        // while a pending estimate existed, reappearing days later as though
        // it had been the day's intake all along.
        let context = try makeContext()
        _ = insertProfile(context)
        _ = insertLog(context, daysAgo: 0, intake: 700)

        let meal = MealEntry(
            dayDate: Date(), slot: .lunch, name: "推定",
            kcal: 800, status: .pending, source: .ai
        )
        context.insert(meal)
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)

        context.delete(meal)
        NutritionLedger.reconcileAfterMealRemoval(for: Date(), modelContext: context)

        let after = try screenSummary(context)
        #expect(after.intakeSource != .meals)
        #expect(after.consumedKcal != 700, "the stale manual value must not come back")
        #expect(after.acceptsManualIntakeEntry, "manual entry is available again")
    }

    @Test func deletingTheLastConfirmedMealLeavesNoStaleTotal() throws {
        let context = try makeContext()
        _ = insertProfile(context)
        let meal = MealEntry(
            dayDate: Date(), slot: .lunch, name: "昼食",
            kcal: 500, status: .confirmed, source: .manual
        )
        context.insert(meal)
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: context)
        #expect(try screenSummary(context).consumedKcal == 500)

        context.delete(meal)
        NutritionLedger.reconcileAfterMealRemoval(for: Date(), modelContext: context)

        let after = try screenSummary(context)
        #expect(after.consumedKcal != 500, "the deleted meal must not linger")
        #expect(after.acceptsManualIntakeEntry)
    }

    @Test func pendingCaloriesNeverJoinTheConfirmedTotal() throws {
        let context = try makeContext()
        _ = insertProfile(context)
        _ = insertLog(context, daysAgo: 0, intake: 2_000)
        insertMeal(context, kcal: 500)
        context.insert(
            MealEntry(
                dayDate: Date(), slot: .dinner, name: "推定",
                kcal: 800, status: .pending, source: .ai
            )
        )

        let summary = try screenSummary(context)

        #expect(summary.consumedKcal == 500)
        #expect(summary.intakeSource == .meals)
        #expect(HomeIntakeTile.displayedKcal(for: summary) == 500)
        #expect(HomeIntakeTile.opensNutrition(for: summary))
    }

    // MARK: - Weight: the same weigh-in on both screens

    @Test func aWeighInOlderThanTheDashboardWindowStillDrivesTheTarget() throws {
        // Home's fourteen-day query is a presentation window. When it reached
        // into the target calculation, a weight logged twenty days ago existed
        // for Nutrition and not for Home, and the two targets diverged.
        let context = try makeContext()
        _ = insertProfile(context)
        _ = insertLog(context, daysAgo: 20, weightKg: 78)

        let resolved = LatestBodyWeightResolver.latestWeightKg(modelContext: context)
        #expect(resolved == 78)

        let summary = try screenSummary(context)
        let expected = try context.fetch(FetchDescriptor<UserProfile>())
            .first?.targetIntake(currentWeightKg: 78)
        #expect(summary.targetKcal == expected)
    }

    @Test func theMostRecentWeighInWinsAcrossTheWindowBoundary() throws {
        let context = try makeContext()
        _ = insertProfile(context)
        _ = insertLog(context, daysAgo: 20, weightKg: 75)
        _ = insertLog(context, daysAgo: 3, weightKg: 73)

        #expect(LatestBodyWeightResolver.latestWeightKg(modelContext: context) == 73)
    }

    @Test func logsWithoutAWeightAreSkipped() throws {
        // A newer log that only carries calories must not hide an older
        // weigh-in — that would silently change the target.
        let context = try makeContext()
        _ = insertProfile(context)
        _ = insertLog(context, daysAgo: 10, weightKg: 80)
        _ = insertLog(context, daysAgo: 0, intake: 1_500)

        #expect(LatestBodyWeightResolver.latestWeightKg(modelContext: context) == 80)
    }

    @Test func noWeighInAnywhereResolvesToNil() throws {
        // `UserProfile.targetIntake` then falls back to the goal weight, as
        // it always has. Nothing here invents a weight.
        let context = try makeContext()
        _ = insertProfile(context)
        _ = insertLog(context, daysAgo: 0, intake: 1_500)

        #expect(LatestBodyWeightResolver.latestWeightKg(modelContext: context) == nil)
    }

    // MARK: - Target source, named truthfully

    @Test func aTypedTargetIsNotDescribedAsCalculated() throws {
        let context = try makeContext()
        _ = insertProfile(context)
        _ = insertLog(context, daysAgo: 2, weightKg: 74)

        let summary = try screenSummary(context, manualTargetKcal: 1_800)

        #expect(summary.targetKcal == 1_800)
        #expect(summary.targetSource == .manualOverride)
    }

    @Test func aDerivedTargetIsDescribedAsCalculated() throws {
        let context = try makeContext()
        _ = insertProfile(context)
        _ = insertLog(context, daysAgo: 2, weightKg: 74)

        let summary = try screenSummary(context)
        #expect(summary.targetSource == .profileDerived)
    }

    @Test func noTargetHasNoSourceToName() throws {
        let context = try makeContext()
        _ = insertLog(context, daysAgo: 0, intake: 500)

        let summary = try screenSummary(context)

        #expect(summary.targetKcal == nil)
        #expect(summary.targetSource == .unset)
        #expect(summary.remainingKcal == nil)
    }

    // MARK: - The whole day, end to end

    @Test func everySurfaceAgreesOnAMixedDay() throws {
        // Meals, a stale manual value, an out-of-window weigh-in and a manual
        // target at once — the combination each individual bug hid inside.
        let context = try makeContext()
        _ = insertProfile(context)
        _ = insertLog(context, daysAgo: 25, weightKg: 82)
        _ = insertLog(context, daysAgo: 0, intake: 2_000)
        insertMeal(context, kcal: 700, protein: 40)

        let summary = try screenSummary(context, manualTargetKcal: 1_900)

        #expect(summary.consumedKcal == 700)
        #expect(summary.targetKcal == 1_900)
        #expect(summary.remainingKcal == 1_200)
        #expect(summary.proteinGrams == 40)
        #expect(summary.intakeSource == .meals)
        #expect(summary.acceptsManualIntakeEntry == false)
        #expect(LatestBodyWeightResolver.latestWeightKg(modelContext: context) == 82)
    }
}
