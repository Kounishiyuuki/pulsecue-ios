//
//  Step+ExerciseResolution.swift
//  Pulse Cue
//
//  Read-time resolution from a persisted `Step` back to bundled Exercise
//  Library metadata. Kept OUT of the `Step` @Model file so the persistence
//  model stays dependency-light: the stored value is just an optional
//  string, and this extension is the only place that maps it to typed
//  metadata.
//
//  Pure and forward-compatible:
//   - no persistence, no network, no title fallback, no inference,
//   - an unknown / deprecated / future raw id safely resolves to `nil`,
//   - `title` remains the runtime/display value; resolution is purely
//     additive metadata used by Form Guide / (future) 3D lookup.
//
//  This is the lookup surface the next Runner → Form Guide / 3D PR needs:
//    Step.exerciseId (String?) → ExerciseID → Exercise → ExerciseGuide.
//

import Foundation

extension Step {
    /// The persisted id as a typed `ExerciseID`, or `nil` when the step
    /// carries no identity. Does not validate membership — an unknown/future
    /// raw value still round-trips as a well-formed-or-not `ExerciseID`.
    var typedExerciseId: ExerciseID? {
        guard let exerciseId else { return nil }
        return ExerciseID(rawValue: exerciseId)
    }

    /// The bundled `Exercise` this step refers to, or `nil` when there is no
    /// id or the id is not in the current Exercise Library (deprecated /
    /// unknown / from a newer app). Never crashes, never guesses from title.
    var resolvedExercise: Exercise? {
        guard let typedExerciseId else { return nil }
        return ExerciseLibrary.exercise(for: typedExerciseId)
    }

    /// The text `ExerciseGuide` for this step, when a guide exists for the
    /// resolved exercise. `nil` for steps with no id, unresolved ids, or
    /// known exercises that simply have no authored guide yet.
    var resolvedGuide: ExerciseGuide? {
        guard let typedExerciseId else { return nil }
        return FormGuideLibrary.guide(for: typedExerciseId)
    }

    /// Whether a Form Guide can be opened for this saved step. Safe gate for
    /// a future Runner/Routine「フォームを見る」entry point — no title match.
    var hasResolvableGuide: Bool { resolvedGuide != nil }
}
