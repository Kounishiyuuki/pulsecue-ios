//
//  TrainingHierarchyTests.swift
//  Pulse CueTests
//
//  What the Training tab leads with, and what it must not.
//
//  The tab used to open on a routine picker, and every occasional training
//  feature — gym setup, the exercise library, the weekly plan, AI planning —
//  had drifted into Settings. Neither was a decision anyone made; both were
//  where there happened to be room. These pin the arrangement so the next
//  addition has to argue for its level.
//
//  The CTA rules themselves are not restated here. They live in
//  `TodayTrainingCard` and are asserted in `HomeHierarchyTests`; Training
//  reuses that component precisely so there is one answer to "can I start a
//  workout" rather than two that can drift.
//

import Foundation
import Testing
@testable import Pulse_Cue

struct TrainingHierarchyTests {

    // MARK: - Levels

    @Test func todayIsTheOnlyPrimaryDestination() {
        let primary = TrainingSurface.Destination.allCases
            .filter { TrainingSurface.level(of: $0) == .primary }
        #expect(primary == [.today])
    }

    @Test func planAndHistoryAreSecondary() {
        #expect(TrainingSurface.level(of: .plan) == .secondary)
        #expect(TrainingSurface.level(of: .history) == .secondary)
    }

    @Test func advancedFeaturesAreNeverPrimary() {
        // Each of these has been somewhere more prominent than it earned at
        // some point. Named individually so promoting one is a visible diff.
        for destination in [
            TrainingSurface.Destination.gym,
            .exerciseLibrary,
            .progress,
            .weeklyPlan,
            .aiPlanning,
        ] {
            #expect(TrainingSurface.level(of: destination) == .more)
        }
    }

    @Test func todayOutranksEverythingElse() {
        let today = TrainingSurface.level(of: .today).rawValue
        for destination in TrainingSurface.Destination.allCases where destination != .today {
            #expect(today < TrainingSurface.level(of: destination).rawValue)
        }
    }

    @Test func thereIsExactlyOnePrimaryActionOnTheRoot() {
        #expect(TrainingSurface.primaryActions == 1)
    }

    // MARK: - Nothing became unreachable

    @Test func everythingMovedOutOfSettingsIsStillListed() {
        // Relocating is only defensible if none of it was lost on the way.
        for destination in TrainingSurface.relocatedFromSettings {
            #expect(TrainingSurface.Destination.allCases.contains(destination))
            #expect(TrainingSurface.level(of: destination) == .more)
        }
    }

    @Test func historyStaysOutOfTheTabBar() {
        // Phase 1 moved it under Training; this keeps it there rather than
        // letting it drift back to a fifth tab.
        #expect(PrimaryNavigation.host(of: .history) == .training)
        #expect(PrimaryNavigation.isPrimary(.history) == false)
    }

    @Test func gymAndFormGuideStayOutOfTheTabBar() {
        #expect(PrimaryNavigation.host(of: .gym) == .training)
        #expect(PrimaryNavigation.host(of: .formGuide) == .training)
        #expect(PrimaryNavigation.isPrimary(.gym) == false)
        #expect(PrimaryNavigation.isPrimary(.formGuide) == false)
    }

    // MARK: - The machine catalogue has a way in

    @Test func theMachineCatalogueIsListedUnderMore() {
        // It had none at all for a while: the Settings card it lived in held
        // *two* links, only the form-guide one was carried across, and the
        // card was then unreferenced — so nothing in the shipping app could
        // reach the catalogue and no test noticed.
        #expect(TrainingSurface.Destination.allCases.contains(.machineCatalog))
        #expect(TrainingSurface.level(of: .machineCatalog) == .more)
    }

    @Test func theMachineCatalogueIsNotTheExerciseLibrary() {
        // One is exercises and their form guides; the other is the machines.
        // Collapsing them is what hid the loss in the first place.
        #expect(TrainingSurface.Destination.machineCatalog != .exerciseLibrary)
        #expect(TrainingSurface.level(of: .exerciseLibrary) == .more)
    }

    @Test func theMachineCatalogueCountsAsRelocatedFromSettings() {
        #expect(TrainingSurface.relocatedFromSettings.contains(.machineCatalog))
    }

    @Test func nothingRelocatedIsListedTwice() {
        // Restoring a route by adding it back to Settings as well would give
        // two ways to one screen, which is the habit this reorganisation is
        // undoing.
        let relocated = TrainingSurface.relocatedFromSettings
        #expect(Set(relocated).count == relocated.count)
    }

    // MARK: - The startable universe is still one rule

    @Test func trainingAsksTheSameStartQuestionAsTheRoutinePicker() {
        // Home, the picker and Training all go through `RoutineLibrary`. A
        // generated-only library must not produce a Start button anywhere.
        let generated = Routine(name: "自動生成", origin: .workoutGenerated)
        let saved = Routine(name: "プッシュ", origin: .userSaved)

        #expect(RoutineLibrary.hasStartable([generated]) == false)
        #expect(RoutineLibrary.hasStartable([generated, saved]))
        #expect(RoutineLibrary.startable(from: [generated, saved]) == [saved])
    }

    @Test func trainingUsesTheSameCTARulesAsHome() {
        // Asserted against the shared component, not a copy of its logic.
        let running = HomeTrainingSummary(
            isRunning: true, currentStepTitle: "ベンチプレス", currentSet: 1,
            totalSets: 3, hasRoutines: true, lastWorkoutName: nil
        )
        let startable = HomeTrainingSummary(
            isRunning: false, currentStepTitle: nil, currentSet: nil,
            totalSets: nil, hasRoutines: true, lastWorkoutName: nil
        )
        let empty = HomeTrainingSummary(
            isRunning: false, currentStepTitle: nil, currentSet: nil,
            totalSets: nil, hasRoutines: false, lastWorkoutName: nil
        )

        #expect(TodayTrainingCard.primaryTitle(for: running) == "続ける")
        #expect(TodayTrainingCard.primaryTitle(for: startable) == "ワークアウトを開始")
        #expect(TodayTrainingCard.primaryTitle(for: empty) == "メニューを作る")
    }

    @Test func anActiveWorkoutLeavesNoRoomForPlanCreation() {
        // Mid-workout the only offer is 続ける: a second Session started from
        // this screen would be a real corruption, not a UI annoyance.
        let running = HomeTrainingSummary(
            isRunning: true, currentStepTitle: "スクワット", currentSet: 2,
            totalSets: 4, hasRoutines: true, lastWorkoutName: nil
        )
        #expect(
            TodayTrainingCard.showsPlanDisclosure(for: running, expanded: false) == false
        )
    }

    // MARK: - The summary both screens build
    //
    //  Home and Training assembled `HomeTrainingSummary` from the same six
    //  expressions written out twice, so either was free to answer "is there
    //  anything to start" differently from the other. Nothing caught that:
    //  the CTA tests in `HomeHierarchyTests` take a summary as input, and the
    //  UI tests only see that *some* action is offered. These go through
    //  `HomeTrainingSummary.make`, which is now the one place both screens
    //  build it.

    @MainActor
    private func summary(
        routines: [Routine],
        lastWorkoutName: String? = nil
    ) -> HomeTrainingSummary {
        HomeTrainingSummary.make(
            runner: RunnerViewModel(settings: SettingsStore()),
            routines: routines,
            lastWorkoutName: lastWorkoutName
        )
    }

    @MainActor
    @Test func aSavedRoutineMeansThereIsSomethingToStart() {
        let saved = Routine(name: "Push", origin: .userSaved)
        #expect(summary(routines: [saved]).hasRoutines)
    }

    @MainActor
    @Test func generatedRoutinesAloneDoNotCountAsSomethingToStart() {
        // The bug this rule exists for: Quick Plan writes `.workoutGenerated`
        // routines that never appear in the library, and counting them gave a
        // Start button that opened an empty picker. `routines.isEmpty` is the
        // wrong question; `RoutineLibrary` asks the one the picker answers.
        let generated = Routine(name: "Quick Plan", origin: .workoutGenerated)
        #expect(summary(routines: [generated]).hasRoutines == false)
    }

    @MainActor
    @Test func noRoutinesAtAllMeansThereIsNothingToStart() {
        #expect(summary(routines: []).hasRoutines == false)
    }

    @MainActor
    @Test func aMixOfSavedAndGeneratedStillCounts() {
        let routines = [
            Routine(name: "Quick Plan", origin: .workoutGenerated),
            Routine(name: "Pull", origin: .userSaved)
        ]
        #expect(summary(routines: routines).hasRoutines)
    }

    @MainActor
    @Test func theSummaryAgreesWithTheLibraryTheButtonOpens() {
        // The invariant behind all of the above: whatever the card says about
        // whether a workout can be started must match what the picker will
        // actually list.
        let routines = [
            Routine(name: "Quick Plan", origin: .workoutGenerated),
            Routine(name: "Legs", origin: .userSaved)
        ]
        #expect(
            summary(routines: routines).hasRoutines
                == !RoutineLibrary.startable(from: routines).isEmpty
        )
    }

    @MainActor
    @Test func anIdleRunnerReportsNoWorkoutInProgress() {
        // Continue is offered only while something is running; a fresh runner
        // must not produce it.
        #expect(summary(routines: []).isRunning == false)
        #expect(summary(routines: []).currentStepTitle == nil)
        #expect(summary(routines: []).currentSet == nil)
    }
}
