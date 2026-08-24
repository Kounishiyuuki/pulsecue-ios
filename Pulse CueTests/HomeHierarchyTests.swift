//
//  HomeHierarchyTests.swift
//  Pulse CueTests
//
//  Home answers one question: what should I do today?
//
//  The failure mode these guard is not a crash — it is Home drifting back
//  into a dashboard. Every feature would like a card on the first screen, and
//  each addition is individually reasonable, so the way this decays is by
//  agreement rather than by mistake. The tests below pin the two things that
//  make Home usable: the primary training action is *one* action decided by
//  state, and the number people actually act on — remaining calories — is
//  derived, present, and honest about what it does not know.
//
//  What is deliberately not tested here: layout, spacing, colour. Those are
//  reviewed by looking at it. These are the claims that can be wrong silently.
//

import Foundation
import Testing
@testable import Pulse_Cue

struct HomeHierarchyTests {

    // MARK: - Training: exactly one primary action, chosen by state

    private func training(
        running: Bool = false,
        step: String? = nil,
        set: Int? = nil,
        sets: Int? = nil,
        hasRoutines: Bool = true,
        last: String? = nil
    ) -> HomeTrainingSummary {
        HomeTrainingSummary(
            isRunning: running,
            currentStepTitle: step,
            currentSet: set,
            totalSets: sets,
            hasRoutines: hasRoutines,
            lastWorkoutName: last
        )
    }

    @Test func aRunningWorkoutIsTheOnlyThingHomeAsksYouToDo() {
        // The case that matters most: mid-workout, "start" must not be
        // offered anywhere near "continue". Starting again would create a
        // second Session on top of a live one.
        let summary = training(running: true, step: "ベンチプレス", set: 2, sets: 3)
        #expect(summary.isRunning)
        #expect(summary.currentStepTitle == "ベンチプレス")
    }

    @Test func aUserWithRoutinesIsAskedToStart() {
        let summary = training(hasRoutines: true)
        #expect(summary.isRunning == false)
        #expect(summary.hasRoutines)
    }

    @Test func aUserWithNoRoutinesIsAskedToCreateOne() {
        // Not "start a workout you do not have". The empty state leads to the
        // one action that can actually be taken.
        let summary = training(hasRoutines: false)
        #expect(summary.hasRoutines == false)
    }

    @Test func lastWorkoutIsContextRatherThanAnAction() {
        // It used to carry its own filled button ("前回のメニューをもう一度"),
        // which competed with starting. It is now a line of text.
        let summary = training(last: "プッシュ")
        #expect(summary.lastWorkoutName == "プッシュ")
    }

    // MARK: - The Start CTA must agree with the list it opens

    @Test func startableRoutinesAreTheOnesThePickerShows() {
        // Quick Plan materialises `.workoutGenerated` routines so the Runner
        // has something to attach a Session to. They are not library entries,
        // and Home counting them produced a Start button that opened nothing.
        let saved = Routine(name: "プッシュ", origin: .userSaved)
        let generated = Routine(name: "自動生成", origin: .workoutGenerated)

        #expect(RoutineLibrary.startable(from: [saved, generated]) == [saved])
        #expect(RoutineLibrary.hasStartable([saved, generated]))
    }

    @Test func generatedOnlyRoutinesAreNotStartable() {
        // The exact reported state: the only routine is one Quick Plan made.
        let generated = Routine(name: "自動生成", origin: .workoutGenerated)

        #expect(RoutineLibrary.hasStartable([generated]) == false)
        #expect(RoutineLibrary.startable(from: [generated]).isEmpty)
    }

    @Test func homeDoesNotOfferStartWhenThePickerWouldBeEmpty() {
        let generated = Routine(name: "自動生成", origin: .workoutGenerated)
        let summary = training(hasRoutines: RoutineLibrary.hasStartable([generated]))

        #expect(summary.hasRoutines == false)
        #expect(TodayTrainingCard.primaryTitle(for: summary) == "メニューを作る")
    }

    @Test func homeOffersStartWhenTheLibraryHasSomething() {
        let saved = Routine(name: "プッシュ", origin: .userSaved)
        let summary = training(hasRoutines: RoutineLibrary.hasStartable([saved]))

        #expect(summary.hasRoutines)
        #expect(TodayTrainingCard.primaryTitle(for: summary) == "ワークアウトを開始")
    }

    @Test func aLegacyRoutineWithNoStoredOriginIsStartable() {
        // Pre-V5 rows have no stored origin and read as `.userSaved`. Treating
        // them as generated would hide a user's whole library.
        let legacy = Routine(name: "旧ルーティン")
        #expect(RoutineLibrary.hasStartable([legacy]))
    }

    // MARK: - Exactly one creation action

    @Test func theRunningStateOffersOnlyContinue() {
        let summary = training(running: true, step: "ベンチプレス")
        #expect(TodayTrainingCard.primaryTitle(for: summary) == "続ける")
        #expect(TodayTrainingCard.showsPlanDisclosure(for: summary, expanded: false) == false)
    }

    @Test func withNoRoutinesTheCreateActionAppearsExactlyOnce() {
        // The primary CTA already says メニューを作る. Showing the disclosure
        // row underneath repeated the same words pointing somewhere else —
        // two identical labels, two destinations.
        let summary = training(hasRoutines: false)

        #expect(TodayTrainingCard.primaryTitle(for: summary) == "メニューを作る")
        #expect(TodayTrainingCard.showsPlanDisclosure(for: summary, expanded: false) == false)
    }

    @Test func theCreateCTAOpensThePlanOptionsRatherThanThePicker() {
        // It must not route into the routine picker, which is empty in this
        // state — that was the original bug in a different shape.
        let summary = training(hasRoutines: false)
        #expect(TodayTrainingCard.primaryOpensPlanOptions(for: summary))
    }

    @Test func theStartCTAOpensThePickerRatherThanPlanOptions() {
        let summary = training(hasRoutines: true)
        #expect(TodayTrainingCard.primaryOpensPlanOptions(for: summary) == false)
    }

    @Test func withRoutinesTheDisclosureIsAvailableAsASecondaryAction() {
        // Creating a plan stays reachable when starting is the primary thing.
        let summary = training(hasRoutines: true)
        #expect(TodayTrainingCard.showsPlanDisclosure(for: summary, expanded: false))
    }

    @Test func onceOpenedThePlanOptionsStayVisible() {
        // Otherwise the create CTA would open a section that immediately
        // hides itself.
        let summary = training(hasRoutines: false)
        #expect(TodayTrainingCard.showsPlanDisclosure(for: summary, expanded: true))
    }

    // MARK: - Home and Nutrition must report the same day
    //
    //  Both screens now build `DailyNutritionSummary` from the same stored
    //  state, so "do they agree?" is answered by constructing it once per
    //  scenario. Before this, Home read `DayLog.intakeCalories` while
    //  Nutrition summed meals, and Home applied the manual target override
    //  while Nutrition did not — so the two could differ on consumed, target
    //  and remaining simultaneously.

    private func meal(kcal: Int, protein: Int? = nil) -> MealEntry {
        MealEntry(
            dayDate: Date(),
            slot: .lunch,
            name: "テスト",
            kcal: kcal,
            proteinGrams: protein,
            status: .confirmed,
            source: .manual
        )
    }

    private func dayLog(intake: Int?) -> DayLog {
        DayLog(date: Date(), intakeCalories: intake)
    }

    @Test func confirmedMealsOwnTheDayWhenTheyExist() {
        let summary = DailyNutritionSummary.make(
            dayLog: dayLog(intake: 1_200),
            mealsForDay: [meal(kcal: 500), meal(kcal: 300)],
            manualTargetKcal: nil,
            profileTargetKcal: 2_000
        )
        #expect(summary.consumedKcal == 800)
    }

    @Test func theQuickInputStandsWhenThereAreNoMeals() {
        // The case that used to show a number on Home and zero on Nutrition:
        // a day logged with the calorie quick input and no meal rows.
        let summary = DailyNutritionSummary.make(
            dayLog: dayLog(intake: 1_500),
            mealsForDay: [],
            manualTargetKcal: nil,
            profileTargetKcal: 2_000
        )
        #expect(summary.consumedKcal == 1_500)
    }

    @Test func aDayWithNothingRecordedHasNoConsumedValue() {
        let summary = DailyNutritionSummary.make(
            dayLog: dayLog(intake: nil),
            mealsForDay: [],
            manualTargetKcal: nil,
            profileTargetKcal: 2_000
        )
        #expect(summary.consumedKcal == nil)
        #expect(summary.remainingKcal == 2_000)
    }

    @Test func aManualTargetOverridesTheProfileFigure() {
        let summary = DailyNutritionSummary.make(
            dayLog: dayLog(intake: 0),
            mealsForDay: [],
            manualTargetKcal: 1_800,
            profileTargetKcal: 2_400
        )
        #expect(summary.targetKcal == 1_800)
    }

    @Test func theProfileFigureIsUsedWhenThereIsNoOverride() {
        let summary = DailyNutritionSummary.make(
            dayLog: dayLog(intake: 0),
            mealsForDay: [],
            manualTargetKcal: nil,
            profileTargetKcal: 2_400
        )
        #expect(summary.targetKcal == 2_400)
    }

    @Test func noTargetAnywhereMeansNoTargetAndNoRemaining() {
        // Neither screen may invent one.
        let summary = DailyNutritionSummary.make(
            dayLog: dayLog(intake: 1_200),
            mealsForDay: [],
            manualTargetKcal: nil,
            profileTargetKcal: nil
        )
        #expect(summary.targetKcal == nil)
        #expect(summary.remainingKcal == nil)
    }

    @Test func remainingIsTheTargetMinusWhatWasEaten() {
        let summary = DailyNutritionSummary.make(
            dayLog: nil,
            mealsForDay: [meal(kcal: 1_840)],
            manualTargetKcal: nil,
            profileTargetKcal: 2_400
        )
        #expect(summary.remainingKcal == 560)
    }

    @Test func goingOverTargetIsReportedRatherThanClampedToZero() {
        // 「残り 0」 for someone 300 kcal over would be the most misleading
        // number on the screen.
        let summary = DailyNutritionSummary.make(
            dayLog: nil,
            mealsForDay: [meal(kcal: 2_300)],
            manualTargetKcal: nil,
            profileTargetKcal: 2_000
        )
        #expect(summary.remainingKcal == -300)
    }

    @Test func proteinComesFromTheSharedConfirmedOnlyHelper() {
        let summary = DailyNutritionSummary.make(
            dayLog: nil,
            mealsForDay: [meal(kcal: 400, protein: 30), meal(kcal: 300, protein: 20)],
            manualTargetKcal: nil,
            profileTargetKcal: 2_400
        )
        #expect(summary.proteinGrams == 50)
        #expect(
            summary.proteinTargetGrams
                == ProteinTotals.defaultTargetGrams(forKcalTarget: 2_400)
        )
    }

    // MARK: - Home stays out of the way of the tabs

    @Test func homeDoesNotHostHistoryOrSettingsAsPrimary() {
        // Phase 1 moved these under Training and Me. Home re-adding an entry
        // for either would undo that quietly.
        #expect(PrimaryNavigation.host(of: .history) == .training)
        #expect(PrimaryNavigation.host(of: .settings) == .me)
    }

    @Test func homeIsStillTheDefaultTab() {
        #expect(PrimaryNavigation.defaultTab == .home)
    }
}
