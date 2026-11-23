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
    /// The finalized session's duration (`Session.totalSeconds`), never
    /// recomputed from the current time.
    let duration: TimeInterval
    /// Exercises with at least one completed set. A skipped exercise (no set
    /// marked done) is not counted. Counted per step, so the same exercise
    /// added twice counts twice.
    let completedExerciseCount: Int
    /// `StepResult`s actually marked done. Skipped sets are not counted.
    let completedSetCount: Int
    /// Sum of `actualReps` over done sets of rep-counted exercises (see
    /// `WorkoutSetSemantics`); a set with no reps adds 0.
    let totalReps: Int
    /// Sum of weight × reps, in kg, over done sets of load-bearing exercises
    /// that recorded both (see `WorkoutSetSemantics`).
    let totalVolumeKg: Double

    init(
        sessionId: UUID,
        duration: TimeInterval,
        completedExerciseCount: Int,
        completedSetCount: Int,
        totalReps: Int = 0,
        totalVolumeKg: Double = 0
    ) {
        self.sessionId = sessionId
        self.duration = duration
        self.completedExerciseCount = completedExerciseCount
        self.completedSetCount = completedSetCount
        self.totalReps = totalReps
        self.totalVolumeKg = totalVolumeKg
    }

    /// The one calculation behind the Completion screen and History detail,
    /// for Runner and Free Workout sessions alike. `duration` is the
    /// finalized session's, supplied by the caller. `results` are the
    /// session's current results — an overwritten set counts with its new
    /// values, a deleted one not at all. `steps` only resolve the exercise of
    /// results that predate the V14 snapshot.
    static func make(sessionId: UUID, duration: TimeInterval, results: [StepResult], steps: [Step]) -> WorkoutCompletionSummary {
        let done = results.filter { $0.sessionId == sessionId && $0.done }
        let stepById = Dictionary(steps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var reps = 0
        var volume = 0.0
        for result in done {
            let exerciseId = result.exerciseIdAtExecution ?? stepById[result.stepId]?.exerciseId
            guard WorkoutSetSemantics.countsReps(exerciseId: exerciseId), let setReps = result.actualReps
            else { continue }
            reps += max(0, setReps)
            if let weight = WorkoutSetSemantics.volumeWeight(exerciseId: exerciseId, weightKg: result.weightKg) {
                volume += weight * Double(max(0, setReps))
            }
        }
        return WorkoutCompletionSummary(
            sessionId: sessionId,
            duration: max(0, duration),
            completedExerciseCount: Set(done.map(\.stepId)).count,
            completedSetCount: done.count,
            totalReps: reps,
            // Weights are stored to 0.01 kg; rounding the sum drops float noise.
            totalVolumeKg: (volume * 100).rounded() / 100
        )
    }

    /// "6,420 kg", "6,420.5 kg" — grouped, no forced trailing zero.
    static func volumeText(_ kg: Double) -> String {
        "\(kg.formatted(.number.precision(.fractionLength(0...2)).grouping(.automatic).locale(Locale(identifier: "en_US")))) kg"
    }
}

/// What a done set of an exercise contributes to the summary. Read from
/// catalog metadata keyed by the persisted exercise id, so stored results
/// are never rewritten — an older timed set that still carries reps, or an
/// assisted set that carries its assistance weight, is simply not counted.
enum WorkoutSetSemantics {
    /// Timed movements have no repetitions; any stored count is ignored.
    /// Custom / unknown exercises count what they recorded.
    static func countsReps(exerciseId: String?) -> Bool {
        guard let exercise = exercise(exerciseId) else { return true }
        return !exercise.isDurationBased
    }

    /// The weight that counts toward volume, or `nil` when the set adds none.
    /// Only external load counts: a body weight is never guessed in, so a
    /// bodyweight movement contributes just the weight added to it (none
    /// recorded → 0). Assistance helps rather than loads, and timed sets have
    /// no reps. Custom / unknown exercises count whatever weight they recorded.
    static func volumeWeight(exerciseId: String?, weightKg: Double?) -> Double? {
        guard let weightKg else { return nil }
        guard let exercise = exercise(exerciseId) else { return weightKg }
        if exercise.isDurationBased || exercise.loadSemantics == .assistance { return nil }
        return weightKg
    }

    private static func exercise(_ id: String?) -> Exercise? {
        id.flatMap { ExerciseLibrary.exercise(for: ExerciseID(rawValue: $0)) }
    }
}
