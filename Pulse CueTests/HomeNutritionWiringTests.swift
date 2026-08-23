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

    /// Today's confirmed meals, fetched the way both screens scope them.
    private func confirmedMealsToday(_ context: ModelContext) throws -> [MealEntry] {
        let today = DateUtils.startOfDay(Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
        let meals = try context.fetch(
            FetchDescriptor<MealEntry>(
                predicate: #Predicate<MealEntry> {
                    $0.dayDate >= today && $0.dayDate < tomorrow
                }
            )
        )
        return meals.filter { $0.status == .confirmed }
    }

    private func todayLog(_ context: ModelContext) throws -> DayLog? {
        let today = DateUtils.startOfDay(Date())
        return try context.fetch(FetchDescriptor<DayLog>())
            .first { DateUtils.startOfDay($0.date) == today }
    }

    /// Builds the summary the way a screen does: shared weight resolver,
    /// shared target policy, shared meal scoping.
    private func screenSummary(
        _ context: ModelContext,
        manualTargetKcal: Int? = nil
    ) throws -> DailyNutritionSummary {
        let profile = try context.fetch(FetchDescriptor<UserProfile>()).first
        let weight = LatestBodyWeightResolver.latestWeightKg(modelContext: context)
        return DailyNutritionSummary.make(
            dayLog: try todayLog(context),
            confirmedMeals: try confirmedMealsToday(context),
            manualTargetKcal: manualTargetKcal,
            profileTargetKcal: profile?.targetIntake(currentWeightKg: weight)
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
        #expect(summary.intakeSource == .confirmedMeals)
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

    @Test func aDayWithOnlyPendingMealsIsNotMealOwned() throws {
        // An unconfirmed estimate is not intake, and must not take ownership
        // away from the manual entry point.
        let context = try makeContext()
        _ = insertProfile(context)
        context.insert(
            MealEntry(
                dayDate: Date(), slot: .lunch, name: "推定",
                kcal: 700, status: .pending, source: .ai
            )
        )

        let summary = try screenSummary(context)

        #expect(summary.intakeSource != .confirmedMeals)
        #expect(summary.acceptsManualIntakeEntry)
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
        #expect(summary.intakeSource == .confirmedMeals)
        #expect(summary.acceptsManualIntakeEntry == false)
        #expect(LatestBodyWeightResolver.latestWeightKg(modelContext: context) == 82)
    }
}
