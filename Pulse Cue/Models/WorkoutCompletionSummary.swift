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
    /// Sum of `actualReps` over done sets; a set with no reps adds 0.
    let totalReps: Int
    /// Sum of weight × reps, in kg, over done sets of load-bearing exercises
    /// that recorded both (see `WorkoutVolume`).
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
        let volume = done.reduce(0.0) { total, result in
            let exerciseId = result.exerciseIdAtExecution ?? stepById[result.stepId]?.exerciseId
            guard WorkoutVolume.countsLoad(exerciseId: exerciseId),
                  let weight = result.weightKg, let reps = result.actualReps
            else { return total }
            return total + weight * Double(reps)
        }
        return WorkoutCompletionSummary(
            sessionId: sessionId,
            duration: max(0, duration),
            completedExerciseCount: Set(done.map(\.stepId)).count,
            completedSetCount: done.count,
            totalReps: done.reduce(0) { $0 + max(0, $1.actualReps ?? 0) },
            // Weights are stored to 0.01 kg; rounding the sum drops float noise.
            totalVolumeKg: (volume * 100).rounded() / 100
        )
    }

    /// "6,420 kg", "6,420.5 kg" — grouped, no forced trailing zero.
    static func volumeText(_ kg: Double) -> String {
        "\(kg.formatted(.number.precision(.fractionLength(0...2)).grouping(.automatic).locale(Locale(identifier: "en_US")))) kg"
    }
}

/// Which exercises add to total volume. Only an added load counts: timed
/// exercises and bodyweight-only ones add 0 — a body weight is never
/// guessed in. An unknown or custom exercise counts whatever weight it
/// recorded.
enum WorkoutVolume {
    static func countsLoad(exerciseId: String?) -> Bool {
        guard let exerciseId, let exercise = ExerciseLibrary.exercise(for: ExerciseID(rawValue: exerciseId))
        else { return true }
        if exercise.isDurationBased { return false }
        let types = exercise.compatibleEquipment.compactMap { equipment -> EquipmentType? in
            switch equipment {
            case let .machine(id): return MachineCatalog.entry(for: id)?.equipmentType
            case let .anyOfType(type): return type
            }
        }
        return types.isEmpty || !types.allSatisfy { $0 == .bodyweight }
    }
}
