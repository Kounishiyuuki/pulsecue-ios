//
//  BodyWeightTruthTests.swift
//  Pulse CueTests
//
//  Which weigh-in the app's calculations are based on.
//
//  The Body / Goals screen used to read its current weight out of a
//  fourteen-day query — the one it renders history from. A presentation
//  window has no business deciding domain truth, and this is what that costs:
//  someone who last weighed in three weeks ago had their BMR, TDEE and
//  calorie target computed as though no weight existed, while Home and Me
//  displayed the figure perfectly well. Same day, same stored row, two
//  answers.
//
//  These go through a real store and the same resolver the screens call, then
//  feed the result into the same `UserProfile` methods the screen feeds. A
//  test that rebuilt a window-free lookup of its own would pass while the
//  screen still looked in the wrong place.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct BodyWeightTruthTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: DayLog.self, UserProfile.self, MealEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @discardableResult
    private func insertProfile(_ context: ModelContext) -> UserProfile {
        let profile = UserProfile()
        profile.heightCm = 172
        profile.ageYears = 30
        profile.goalWeightKg = 70
        context.insert(profile)
        return profile
    }

    private func insertWeight(_ context: ModelContext, daysAgo: Int, kg: Double) {
        let date = Calendar.current.date(
            byAdding: .day, value: -daysAgo, to: DateUtils.startOfDay(Date())
        ) ?? Date()
        context.insert(DayLog(date: date, weightKg: kg))
    }

    /// What the fourteen-day dashboard query would have produced. Kept as the
    /// contrast: the tests below assert the app does *not* agree with it.
    private func fourteenDayWindowWeight(_ context: ModelContext) throws -> Double? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -13, to: today) ?? today
        let logs = try context.fetch(
            FetchDescriptor<DayLog>(
                predicate: #Predicate<DayLog> { $0.date >= start },
                sortBy: [SortDescriptor(\DayLog.date, order: .reverse)]
            )
        )
        return HealthSummary(logs: logs).latestWeight
    }

    // MARK: - A weigh-in older than the dashboard window

    @Test func aWeighInFromThreeWeeksAgoStillCountsAsCurrent() throws {
        let context = try makeContext()
        insertProfile(context)
        insertWeight(context, daysAgo: 20, kg: 75)

        // The old source saw nothing at all — that is the bug, stated.
        #expect(try fourteenDayWindowWeight(context) == nil)

        #expect(LatestBodyWeightResolver.latestWeightKg(modelContext: context) == 75)
    }

    @Test func bmrUsesTheOldWeighInRatherThanTreatingItAsMissing() throws {
        let context = try makeContext()
        let profile = insertProfile(context)
        insertWeight(context, daysAgo: 20, kg: 75)

        let resolved = LatestBodyWeightResolver.latestWeightKg(modelContext: context)
        let windowed = try fourteenDayWindowWeight(context)

        #expect(profile.bmr(currentWeightKg: resolved) == profile.bmr(currentWeightKg: 75))
        #expect(profile.bmr(currentWeightKg: resolved) != profile.bmr(currentWeightKg: windowed))
    }

    @Test func tdeeUsesTheOldWeighIn() throws {
        let context = try makeContext()
        let profile = insertProfile(context)
        insertWeight(context, daysAgo: 20, kg: 75)

        let resolved = LatestBodyWeightResolver.latestWeightKg(modelContext: context)
        #expect(profile.tdee(currentWeightKg: resolved) == profile.tdee(currentWeightKg: 75))
    }

    @Test func theCalorieTargetUsesTheOldWeighIn() throws {
        // The figure Home and Nutrition also derive. Divergence here is what
        // made the same day show two different targets.
        let context = try makeContext()
        let profile = insertProfile(context)
        insertWeight(context, daysAgo: 20, kg: 75)

        let resolved = LatestBodyWeightResolver.latestWeightKg(modelContext: context)
        #expect(
            profile.targetIntake(currentWeightKg: resolved)
                == profile.targetIntake(currentWeightKg: 75)
        )
    }

    // MARK: - Through the seam the screen actually uses

    @Test func theScreensMetricsUseTheOldWeighIn() throws {
        // `BodyMetrics.resolve` is what Body / Goals calls; asserting the
        // resolver alone would leave the screen free to look elsewhere, which
        // is exactly what it used to do.
        let context = try makeContext()
        let profile = insertProfile(context)
        insertWeight(context, daysAgo: 20, kg: 75)

        let metrics = BodyMetrics.resolve(modelContext: context, profile: profile)

        #expect(metrics.currentWeightKg == 75)
        #expect(metrics.bmr == profile.bmr(currentWeightKg: 75))
        #expect(metrics.tdee == profile.tdee(currentWeightKg: 75))
        #expect(metrics.targetIntakeKcal == profile.targetIntake(currentWeightKg: 75))
    }

    @Test func theScreensMetricsDisagreeWithTheDashboardWindow() throws {
        // Stated as a difference rather than a value: if the screen ever goes
        // back to the fourteen-day query, these become equal.
        let context = try makeContext()
        let profile = insertProfile(context)
        insertWeight(context, daysAgo: 20, kg: 75)

        let metrics = BodyMetrics.resolve(modelContext: context, profile: profile)
        let windowed = try fourteenDayWindowWeight(context)

        #expect(windowed == nil)
        #expect(metrics.currentWeightKg != windowed)
        #expect(metrics.bmr != profile.bmr(currentWeightKg: windowed))
        #expect(metrics.targetIntakeKcal != profile.targetIntake(currentWeightKg: windowed))
    }

    @Test func theScreensMetricsFollowTheNewestWeighIn() throws {
        let context = try makeContext()
        let profile = insertProfile(context)
        insertWeight(context, daysAgo: 20, kg: 75)
        insertWeight(context, daysAgo: 3, kg: 73)

        let metrics = BodyMetrics.resolve(modelContext: context, profile: profile)
        #expect(metrics.currentWeightKg == 73)
        #expect(metrics.tdee == profile.tdee(currentWeightKg: 73))
    }

    @Test func theScreensMetricsInventNothingWithoutAWeighIn() throws {
        let context = try makeContext()
        let profile = insertProfile(context)

        let metrics = BodyMetrics.resolve(modelContext: context, profile: profile)
        #expect(metrics.currentWeightKg == nil)
        #expect(metrics.bmr == profile.bmr(currentWeightKg: nil))
    }

    // MARK: - A newer weigh-in inside the window

    @Test func theMostRecentWeighInWinsAcrossTheWindowBoundary() throws {
        let context = try makeContext()
        insertProfile(context)
        insertWeight(context, daysAgo: 20, kg: 75)
        insertWeight(context, daysAgo: 3, kg: 73)

        #expect(LatestBodyWeightResolver.latestWeightKg(modelContext: context) == 73)
    }

    @Test func everyCalculationAgreesOnTheNewerWeighIn() throws {
        let context = try makeContext()
        let profile = insertProfile(context)
        insertWeight(context, daysAgo: 20, kg: 75)
        insertWeight(context, daysAgo: 3, kg: 73)

        let resolved = LatestBodyWeightResolver.latestWeightKg(modelContext: context)

        #expect(profile.bmr(currentWeightKg: resolved) == profile.bmr(currentWeightKg: 73))
        #expect(profile.tdee(currentWeightKg: resolved) == profile.tdee(currentWeightKg: 73))
        #expect(
            profile.targetIntake(currentWeightKg: resolved)
                == profile.targetIntake(currentWeightKg: 73)
        )
    }

    // MARK: - No weigh-in at all

    @Test func noWeighInResolvesToNilRatherThanAFabricatedWeight() throws {
        // The existing fallback inside `UserProfile` then applies, unchanged.
        let context = try makeContext()
        insertProfile(context)

        #expect(LatestBodyWeightResolver.latestWeightKg(modelContext: context) == nil)
    }

    @Test func everySurfaceSeesTheSameAbsence() throws {
        // Home, Me and Body must agree that there is no weight, rather than
        // one of them inventing one from a goal or a default.
        let context = try makeContext()
        let profile = insertProfile(context)

        let resolved = LatestBodyWeightResolver.latestWeightKg(modelContext: context)
        #expect(resolved == nil)
        #expect(profile.bmr(currentWeightKg: resolved) == profile.bmr(currentWeightKg: nil))
    }

    // MARK: - Logs without a weight

    @Test func aNewerLogCarryingNoWeightDoesNotHideAnOlderWeighIn() throws {
        // Otherwise recording calories would silently change the target.
        let context = try makeContext()
        insertProfile(context)
        insertWeight(context, daysAgo: 18, kg: 80)
        context.insert(DayLog(date: Date(), intakeCalories: 1_500))

        #expect(LatestBodyWeightResolver.latestWeightKg(modelContext: context) == 80)
    }
}
