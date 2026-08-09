//
//  WorkoutDurationEstimatorTests.swift
//  Pulse CueTests
//
//  Locks the single duration estimate: rest belongs between sets (including
//  between exercises) but never after the workout's final set, and the Quick
//  Plan preview and the routine cards must agree on the same prescription.
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct WorkoutDurationEstimatorTests {

    private typealias Exercise = WorkoutDurationEstimator.Exercise

    // MARK: - Core formula

    @Test
    func emptyWorkoutHasNoDuration() {
        #expect(WorkoutDurationEstimator.totalSeconds([]) == 0)
        #expect(WorkoutDurationEstimator.minutes([]) == 0)
        #expect(WorkoutDurationEstimator.approximateText([]) == "時間未設定")
    }

    @Test
    func singleSetCountsWorkButNoRest() {
        // One set is the whole workout: the Runner finishes instead of
        // resting, so the prescribed 90s rest is never spent.
        let one = [Exercise(sets: 1, reps: 10, restSeconds: 90)]
        #expect(WorkoutDurationEstimator.totalSeconds(one) == 10 * 4)
        #expect(WorkoutDurationEstimator.minutes(one) == 1)
    }

    @Test
    func restFallsBetweenSetsOfOneExercise() {
        // 3 sets → work ×3, rest ×2.
        let sets3 = [Exercise(sets: 3, reps: 10, restSeconds: 60)]
        #expect(WorkoutDurationEstimator.totalSeconds(sets3) == 3 * 40 + 2 * 60)
    }

    @Test
    func restIsAlsoCountedBetweenExercises() {
        // The Runner rests after the last set of an exercise before moving
        // on, so that rest is real time.
        let plan = [
            Exercise(sets: 1, reps: 10, restSeconds: 60),
            Exercise(sets: 1, reps: 10, restSeconds: 90),
        ]
        #expect(WorkoutDurationEstimator.totalSeconds(plan) == 40 + 60 + 40)
    }

    @Test
    func trailingRestOfTheFinalSetIsNeverCounted() {
        let short = [
            Exercise(sets: 2, reps: 8, restSeconds: 60),
            Exercise(sets: 2, reps: 8, restSeconds: 60),
        ]
        let sameButLongerFinalRest = [
            Exercise(sets: 2, reps: 8, restSeconds: 60),
            Exercise(sets: 2, reps: 8, restSeconds: 300),
        ]
        // Only the final exercise's *trailing* rest differs, and exactly one
        // of its two rests is trailing — so the totals differ by one 60s vs
        // one 300s in-between rest, never by the final one.
        #expect(WorkoutDurationEstimator.totalSeconds(short) == 4 * 32 + 3 * 60)
        #expect(WorkoutDurationEstimator.totalSeconds(sameButLongerFinalRest) == 4 * 32 + 2 * 60 + 300)
    }

    @Test
    func multipleExercisesAccumulate() {
        let plan = [
            Exercise(sets: 3, reps: 10, restSeconds: 90),
            Exercise(sets: 3, reps: 10, restSeconds: 90),
            Exercise(sets: 2, reps: 12, restSeconds: 60),
        ]
        let work = 3 * 40 + 3 * 40 + 2 * 48
        let rest = 3 * 90 + 3 * 90 + 2 * 60 - 60
        #expect(WorkoutDurationEstimator.totalSeconds(plan) == work + rest)
        #expect(WorkoutDurationEstimator.minutes(plan) == 16)
    }

    // MARK: - Rounding

    @Test
    func minutesRoundUpAndNeverReachZeroForRealWork() {
        // 15 reps × 4s = 60s exactly → 1 minute; one more rep spills over.
        #expect(WorkoutDurationEstimator.minutes([Exercise(sets: 1, reps: 15, restSeconds: 0)]) == 1)
        #expect(WorkoutDurationEstimator.minutes([Exercise(sets: 1, reps: 16, restSeconds: 0)]) == 2)
        // A prescription with no reps is still a set the user performs.
        #expect(WorkoutDurationEstimator.minutes([Exercise(sets: 1, reps: 0, restSeconds: 0)]) == 1)
    }

    @Test
    func approximateTextIsHedged() {
        #expect(WorkoutDurationEstimator.approximateText([Exercise(sets: 1, reps: 15, restSeconds: 0)]) == "約1分")
    }

    // MARK: - Degenerate input

    @Test
    func degenerateValuesAreClamped() {
        let zeroSets = Exercise(sets: 0, reps: 10, restSeconds: 60)
        #expect(zeroSets.sets == 1)
        let negatives = Exercise(sets: 2, reps: -5, restSeconds: -30)
        #expect(negatives.reps == 0)
        #expect(negatives.restSeconds == 0)
        #expect(WorkoutDurationEstimator.totalSeconds([negatives]) == 0)
        #expect(WorkoutDurationEstimator.minutes([negatives]) == 1)
    }

    // MARK: - The two screens agree

    @Test
    func previewAndRoutineCardAgreeOnTheSamePrescription() {
        let prescription = [(sets: 4, reps: 8, rest: 120), (sets: 3, reps: 10, rest: 90), (sets: 3, reps: 12, rest: 75)]

        let planExercises = prescription.enumerated().map { index, p in
            GeneratedExercise(
                machineId: "m\(index)", exerciseName: "E\(index)",
                sets: p.sets, reps: p.reps, restSeconds: p.rest, cue: ""
            )
        }
        let routineId = UUID()
        let steps = prescription.enumerated().map { index, p in
            Step(
                routineId: routineId, order: index, title: "E\(index)",
                sets: p.sets, repsTarget: p.reps, restSeconds: p.rest
            )
        }

        let fromPlan = WorkoutDurationEstimator.exercises(fromPlan: planExercises)
        let fromSteps = WorkoutDurationEstimator.exercises(fromSteps: steps)
        #expect(fromPlan == fromSteps)
        #expect(WorkoutDurationEstimator.minutes(forPlan: planExercises)
                == WorkoutDurationEstimator.minutes(fromSteps))
        #expect(WorkoutDurationEstimator.approximateText(forSteps: steps)
                == "約\(WorkoutDurationEstimator.minutes(forPlan: planExercises))分")
    }

    @Test
    func stepsWithNoExercisesShowUnsetRatherThanAMinute() {
        #expect(WorkoutDurationEstimator.approximateText(forSteps: []) == "時間未設定")
        #expect(WorkoutDurationEstimator.minutes(forPlan: []) == 0)
    }
}
