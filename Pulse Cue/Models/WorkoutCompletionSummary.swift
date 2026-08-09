//
//  WorkoutCompletionSummary.swift
//  Pulse Cue
//
//  Transient snapshot of a workout that has just finished. It exists only to
//  drive the Workout Completion screen: it is never persisted, has no
//  SwiftData model, and adds nothing to the schema. Every value is derived
//  from the already-finalized `Session` and its `StepResult`s at the moment
//  the session ends, before the Runner resets its state.
//

import Foundation

struct WorkoutCompletionSummary: Equatable {
    let sessionId: UUID
    /// `endedAt - startedAt` of the finalized session.
    let duration: TimeInterval
    /// Exercises with at least one completed set. A skipped exercise (no set
    /// marked done) is not counted.
    let completedExerciseCount: Int
    /// `StepResult`s actually marked done. Skipped sets are not counted.
    let completedSetCount: Int
}
