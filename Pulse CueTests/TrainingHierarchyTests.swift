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
}
