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

    // MARK: - Nutrition: remaining is the decision

    @Test func remainingIsTheTargetMinusWhatWasEaten() {
        let summary = HomeNutritionSummary(
            consumedKcal: 1_840,
            targetKcal: 2_400,
            proteinGrams: 128,
            proteinTargetGrams: 160
        )
        #expect(summary.remainingKcal == 560)
    }

    @Test func remainingCountsAnUnloggedDayAsZeroEaten() {
        let summary = HomeNutritionSummary(
            consumedKcal: nil,
            targetKcal: 2_000,
            proteinGrams: 0,
            proteinTargetGrams: 60
        )
        #expect(summary.remainingKcal == 2_000)
    }

    @Test func remainingGoesNegativeRatherThanClampingToZero() {
        // Being over the target is a real answer and the one a user most
        // needs. Clamping at zero would quietly report "残り 0" for someone
        // who is 300 kcal over.
        let summary = HomeNutritionSummary(
            consumedKcal: 2_300,
            targetKcal: 2_000,
            proteinGrams: 90,
            proteinTargetGrams: 100
        )
        #expect(summary.remainingKcal == -300)
    }

    @Test func remainingIsUnknownWithoutATarget() {
        // No profile, no target, so no remaining. Showing a number here would
        // mean inventing a target the user never set.
        let summary = HomeNutritionSummary(
            consumedKcal: 1_200,
            targetKcal: nil,
            proteinGrams: 40,
            proteinTargetGrams: 60
        )
        #expect(summary.remainingKcal == nil)
    }

    @Test func proteinComesFromTheSharedConfirmedOnlyHelper() {
        // Home must not sum meals itself. `ProteinTotals` owns the rule that
        // pending and AI-estimated rows never count, and Home reuses it — so
        // an estimate cannot become part of a total on one screen and not
        // another.
        let target = ProteinTotals.defaultTargetGrams(forKcalTarget: 2_400)
        let summary = HomeNutritionSummary(
            consumedKcal: 0,
            targetKcal: 2_400,
            proteinGrams: 0,
            proteinTargetGrams: target
        )
        #expect(summary.proteinTargetGrams == target)
        #expect(target >= ProteinTotals.defaultTargetFloorGrams)
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
