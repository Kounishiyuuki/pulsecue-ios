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

        let metrics = BodyMetrics.derive(
            profile: profile,
            currentWeightKg: BodyMetrics.resolveCurrentWeightKg(modelContext: context)
        )

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

        let metrics = BodyMetrics.derive(
            profile: profile,
            currentWeightKg: BodyMetrics.resolveCurrentWeightKg(modelContext: context)
        )
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

        let metrics = BodyMetrics.derive(
            profile: profile,
            currentWeightKg: BodyMetrics.resolveCurrentWeightKg(modelContext: context)
        )
        #expect(metrics.currentWeightKg == 73)
        #expect(metrics.tdee == profile.tdee(currentWeightKg: 73))
    }

    @Test func theScreensMetricsInventNothingWithoutAWeighIn() throws {
        let context = try makeContext()
        let profile = insertProfile(context)

        let metrics = BodyMetrics.derive(
            profile: profile,
            currentWeightKg: BodyMetrics.resolveCurrentWeightKg(modelContext: context)
        )
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

    // MARK: - Noticing that the weigh-in changed

    @Test func theSignatureChangesWhenTheLatestWeightIsEditedInPlace() throws {
        // The case an array `onChange` misses: `@Model` elements compare by
        // identity, so editing `weightKg` on the same row leaves the array
        // "equal" and the screen keeps a weight that is no longer on disk.
        let context = try makeContext()
        insertProfile(context)
        insertWeight(context, daysAgo: 1, kg: 75)

        let logs = try context.fetch(FetchDescriptor<DayLog>())
        let before = LatestBodyWeightResolver.changeSignature(for: logs)

        logs.first(where: { $0.weightKg != nil })?.weightKg = 73
        let after = LatestBodyWeightResolver.changeSignature(for: logs)

        #expect(before != after)
    }

    @Test func theSignatureChangesWhenANewerWeighInArrives() throws {
        let context = try makeContext()
        insertProfile(context)
        insertWeight(context, daysAgo: 10, kg: 80)

        let before = LatestBodyWeightResolver.changeSignature(
            for: try context.fetch(FetchDescriptor<DayLog>())
        )

        insertWeight(context, daysAgo: 1, kg: 80)
        let after = LatestBodyWeightResolver.changeSignature(
            for: try context.fetch(FetchDescriptor<DayLog>())
        )

        // Same number, different row — "which weigh-in is latest" changed, and
        // that needs a refresh too.
        #expect(before != after)
    }

    @Test func theSignatureIsStableWhenNothingRelevantChanges() throws {
        // Otherwise every unrelated log edit would re-fetch.
        let context = try makeContext()
        insertProfile(context)
        insertWeight(context, daysAgo: 2, kg: 75)

        let logs = try context.fetch(FetchDescriptor<DayLog>())
        let before = LatestBodyWeightResolver.changeSignature(for: logs)

        context.insert(DayLog(date: Date(), intakeCalories: 1_500))
        let after = LatestBodyWeightResolver.changeSignature(
            for: try context.fetch(FetchDescriptor<DayLog>())
        )

        #expect(before == after)
    }

    @Test func theSignatureSaysSoWhenThereIsNoWeighIn() throws {
        let context = try makeContext()
        insertProfile(context)

        #expect(LatestBodyWeightResolver.changeSignature(for: []) == "none")
        let logs = try context.fetch(FetchDescriptor<DayLog>())
        #expect(LatestBodyWeightResolver.changeSignature(for: logs) == "none")
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

//
//  Editing the profile while the screen is open.
//
//  The Body screen cached BMR, TDEE and the target alongside the weight and
//  refreshed the lot only on appear and on `DayLog` changes. So changing your
//  height there left the three figures showing what they were before the
//  edit — not wrong when they were computed, just no longer about the profile
//  on screen — until something unrelated happened to a day log.
//
//  Each test below derives, mutates the same profile the view holds, and
//  derives again. A test that built a second profile would prove nothing: the
//  bug was reading a snapshot of the first one.
//
@MainActor
struct BodyMetricsLiveEditTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: DayLog.self, UserProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// A profile and a weigh-in older than any display window, so these also
    /// keep the previous fix honest.
    private func fixture(_ context: ModelContext) -> (UserProfile, Double?) {
        let profile = UserProfile()
        profile.heightCm = 170
        profile.ageYears = 30
        profile.goalWeightKg = 70
        context.insert(profile)

        let date = Calendar.current.date(
            byAdding: .day, value: -20, to: DateUtils.startOfDay(Date())
        ) ?? Date()
        context.insert(DayLog(date: date, weightKg: 75))

        return (profile, BodyMetrics.resolveCurrentWeightKg(modelContext: context))
    }

    @Test func editingHeightUpdatesBmrAndTdeeImmediately() throws {
        let context = try makeContext()
        let (profile, weight) = fixture(context)

        let before = BodyMetrics.derive(profile: profile, currentWeightKg: weight)
        profile.heightCm = 180
        let after = BodyMetrics.derive(profile: profile, currentWeightKg: weight)

        #expect(after.bmr != before.bmr)
        #expect(after.tdee != before.tdee)
        // The weigh-in is unaffected: only the profile changed.
        #expect(after.currentWeightKg == 75)
    }

    @Test func editingAgeUpdatesBmrAndTdeeImmediately() throws {
        let context = try makeContext()
        let (profile, weight) = fixture(context)

        let before = BodyMetrics.derive(profile: profile, currentWeightKg: weight)
        profile.ageYears = 55
        let after = BodyMetrics.derive(profile: profile, currentWeightKg: weight)

        #expect(after.bmr != before.bmr)
        #expect(after.tdee != before.tdee)
    }

    @Test func editingSexUpdatesBmrAndTdeeImmediately() throws {
        let context = try makeContext()
        let (profile, weight) = fixture(context)

        let before = BodyMetrics.derive(profile: profile, currentWeightKg: weight)
        profile.biologicalSex = profile.biologicalSex == .male ? .female : .male
        let after = BodyMetrics.derive(profile: profile, currentWeightKg: weight)

        #expect(after.bmr != before.bmr)
        #expect(after.tdee != before.tdee)
    }

    @Test func editingActivityFactorUpdatesTdeeAndTargetImmediately() throws {
        let context = try makeContext()
        let (profile, weight) = fixture(context)

        profile.activityFactor = .sedentary
        let before = BodyMetrics.derive(profile: profile, currentWeightKg: weight)
        profile.activityFactor = .veryActive
        let after = BodyMetrics.derive(profile: profile, currentWeightKg: weight)

        // BMR is weight/height/age/sex only, so it is unchanged by design.
        #expect(after.bmr == before.bmr)
        #expect(after.tdee != before.tdee)
        #expect(after.targetIntakeKcal != before.targetIntakeKcal)
    }

    @Test func theGoalWeightOnlyMovesTheTargetWhenNoWeightIsMeasured() throws {
        // Stating the real contract rather than the one that seems likely:
        // `targetIntake` is computed from the *measured* weight, and the goal
        // weight is only the fallback when there is none. So with a weigh-in
        // on file, editing the goal must not move the target — asserting
        // otherwise would have meant changing the formula to match a guess.
        let context = try makeContext()
        let (profile, weight) = fixture(context)

        let before = BodyMetrics.derive(profile: profile, currentWeightKg: weight)
        profile.goalWeightKg = 62
        let after = BodyMetrics.derive(profile: profile, currentWeightKg: weight)

        #expect(after.targetIntakeKcal == before.targetIntakeKcal)
    }

    @Test func withoutAWeighInTheGoalWeightMovesTheTargetImmediately() throws {
        // The case where the goal *is* the input. It still updates live, which
        // is what this fix is about.
        let context = try makeContext()
        let profile = UserProfile()
        profile.heightCm = 170
        profile.ageYears = 30
        profile.goalWeightKg = 70
        context.insert(profile)

        let noWeight = BodyMetrics.resolveCurrentWeightKg(modelContext: context)
        #expect(noWeight == nil)

        let before = BodyMetrics.derive(profile: profile, currentWeightKg: noWeight)
        profile.goalWeightKg = 60
        let after = BodyMetrics.derive(profile: profile, currentWeightKg: noWeight)

        #expect(before.targetIntakeKcal != nil)
        #expect(after.targetIntakeKcal != before.targetIntakeKcal)
    }

    @Test func editingTheWeeklyRateUpdatesTheTargetImmediately() throws {
        let context = try makeContext()
        let (profile, weight) = fixture(context)

        profile.weeklyChangeKg = -0.2
        let before = BodyMetrics.derive(profile: profile, currentWeightKg: weight)
        profile.weeklyChangeKg = -0.7
        let after = BodyMetrics.derive(profile: profile, currentWeightKg: weight)

        #expect(after.targetIntakeKcal != before.targetIntakeKcal)
    }

    @Test func consecutiveEditsEachTakeEffect() throws {
        // A cache refreshed once would pass a single-edit test and fail here.
        let context = try makeContext()
        let (profile, weight) = fixture(context)

        profile.heightCm = 165
        let first = BodyMetrics.derive(profile: profile, currentWeightKg: weight)
        profile.heightCm = 185
        let second = BodyMetrics.derive(profile: profile, currentWeightKg: weight)
        profile.heightCm = 175
        let third = BodyMetrics.derive(profile: profile, currentWeightKg: weight)

        #expect(first.bmr != second.bmr)
        #expect(second.bmr != third.bmr)
        #expect(third.bmr != first.bmr)
    }

    @Test func derivingDoesNotTouchTheStore() throws {
        // Editing a field must not cost a fetch. `derive` takes no context at
        // all, which is the structural guarantee — this states the intent.
        let context = try makeContext()
        let (profile, weight) = fixture(context)

        profile.heightCm = 181
        let metrics = BodyMetrics.derive(profile: profile, currentWeightKg: weight)

        #expect(metrics.currentWeightKg == weight)
    }

    @Test func theWeighInSurvivesEveryProfileEdit() throws {
        // The previous fix: a weight logged outside the dashboard window is
        // still the current one, and profile edits must not disturb it.
        let context = try makeContext()
        let (profile, weight) = fixture(context)

        profile.heightCm = 190
        profile.ageYears = 44
        profile.goalWeightKg = 65

        let metrics = BodyMetrics.derive(profile: profile, currentWeightKg: weight)
        #expect(metrics.currentWeightKg == 75)
        #expect(metrics.bmr == profile.bmr(currentWeightKg: 75))
    }
}
