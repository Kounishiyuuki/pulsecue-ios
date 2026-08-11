//
//  WorkoutDurationEstimator.swift
//  Pulse Cue
//
//  The one place a workout's expected duration is estimated. Before this,
//  the Quick Plan preview and the routine cards each had their own formula
//  and disagreed by ~1.4× on the same plan (preview 36分 vs card 約25分).
//
//  Pure and value-only: no I/O, no SwiftData dependency in the core, no
//  schema. It estimates only — the Runner never times a working set, so
//  this can never be exact; it just has to be consistent and defensible.
//
//  The model follows what the Runner actually does:
//
//   - A set costs `reps × secondsPerRep`. Reps are the only per-set signal
//     the prescription carries, so a 4×8 press and a 3×12 fly are not
//     treated as the same effort.
//   - Rest follows every completed set, including the last set of an
//     exercise — `RunnerViewModel.completeCurrent` starts rest before
//     advancing to the next exercise, so inter-exercise rest is real time
//     the user spends.
//   - Except after the very last set of the workout, where the Runner
//     finishes instead of resting. That trailing rest is not counted.
//
//  Known limitation (unchanged from before, deliberately not "fixed" here):
//  the cardio / warm-up templates encode their duration in the cue text
//  ("10分。…") rather than in reps, so a treadmill warm-up is estimated as
//  an ordinary set. Modelling that needs prescription data this type does
//  not have.
//

import Foundation

enum WorkoutDurationEstimator {

    /// The only shape the estimate needs, so the core stays independent of
    /// `Step` (persisted) and `GeneratedExercise` (transient).
    struct Exercise: Equatable {
        let sets: Int
        let reps: Int
        let restSeconds: Int
        /// Set length for a movement measured in time rather than in
        /// repetitions. `nil` means rep-based and the length comes from
        /// `reps`.
        let workSecondsPerSet: Int?

        init(sets: Int, reps: Int, restSeconds: Int, workSecondsPerSet: Int? = nil) {
            self.sets = max(1, sets)
            self.reps = max(0, reps)
            self.restSeconds = max(0, restSeconds)
            self.workSecondsPerSet = workSecondsPerSet.map { max(0, $0) }
        }

        /// One set's working time, from whichever model the movement uses.
        var secondsPerSet: Int { workSecondsPerSet ?? reps * secondsPerRep }
    }

    /// Rough tempo for one repetition, including the turnaround. Whole
    /// seconds keep every estimate integral.
    static let secondsPerRep = 4

    /// Estimated wall-clock seconds for the whole workout, rest included.
    static func totalSeconds(_ exercises: [Exercise]) -> Int {
        guard let last = exercises.last else { return 0 }
        let work = exercises.reduce(0) { $0 + $1.sets * $1.secondsPerSet }
        let rest = exercises.reduce(0) { $0 + $1.sets * $1.restSeconds }
        // The workout ends on its final set; the Runner does not rest after it.
        return work + rest - last.restSeconds
    }

    /// Whole minutes, rounded up. `0` for an empty workout — an empty plan
    /// shows "0 種目", so claiming a minute would contradict it. Any real
    /// workout is at least 1 minute.
    static func minutes(_ exercises: [Exercise]) -> Int {
        guard !exercises.isEmpty else { return 0 }
        return max(1, Int(ceil(Double(totalSeconds(exercises)) / 60.0)))
    }

    /// The routine cards' label. Deliberately hedged ("約") — it is an
    /// estimate, and the cards have always presented it that way.
    static func approximateText(_ exercises: [Exercise]) -> String {
        guard !exercises.isEmpty else { return "時間未設定" }
        return "約\(minutes(exercises))分"
    }
}

// MARK: - Adapters
//
// Thin, so no screen re-derives the shape (or the formula) for itself.

extension WorkoutDurationEstimator {
    /// Normalises to `Step.order` before converting, because the estimate is
    /// order-sensitive: it drops the trailing rest of the *last* exercise, so
    /// a differently ordered array would drop a different one. Callers hand
    /// over unsorted arrays (`WorkoutView` / `RoutinePickerSheet` fetch every
    /// `Step` with an unsorted `@Query`), and `Step.order` is exactly the
    /// sequence `RunnerViewModel.fetchSteps` executes — so normalising here
    /// keeps the estimate identical to the workout the user will actually do,
    /// wherever it is shown. No tie-break: `order` is assigned from an
    /// enumerated index per routine, and the Runner sorts on it alone.
    static func exercises(fromSteps steps: [Step]) -> [Exercise] {
        steps
            .sorted { $0.order < $1.order }
            .map {
                Exercise(
                    sets: $0.sets,
                    reps: $0.repsTarget,
                    restSeconds: $0.restSeconds,
                    workSecondsPerSet: catalogWorkSeconds(exerciseId: $0.exerciseId)
                )
            }
    }

    static func exercises(fromPlan planExercises: [GeneratedExercise]) -> [Exercise] {
        planExercises.map {
            Exercise(
                sets: $0.sets,
                reps: $0.reps,
                restSeconds: $0.restSeconds,
                workSecondsPerSet: catalogWorkSeconds(exerciseId: $0.exerciseId?.rawValue)
            )
        }
    }

    /// Time-based set length declared by the catalog for this movement, or
    /// `nil` for a rep-based one (and for anything unresolvable, such as a
    /// custom machine). Resolution is by the persisted `ExerciseID` only —
    /// never by display name, cue text, or rep count — so a saved `Step`
    /// estimates exactly like the plan it came from.
    private static func catalogWorkSeconds(exerciseId: String?) -> Int? {
        guard let exerciseId else { return nil }
        return ExerciseLibrary.exercise(for: ExerciseID(rawValue: exerciseId))?.workSecondsPerSet
    }

    /// "約N分" / "時間未設定" for a saved routine's steps.
    static func approximateText(forSteps steps: [Step]) -> String {
        approximateText(exercises(fromSteps: steps))
    }

    /// Whole minutes for a generated plan.
    static func minutes(forPlan planExercises: [GeneratedExercise]) -> Int {
        minutes(exercises(fromPlan: planExercises))
    }
}
