//
//  RoutineFactory.swift
//  Pulse Cue
//
//  Adapter that turns a `GeneratedPlan` value into the existing
//  `Routine` + ordered `Step` records used by the Runner. Pure — does
//  not insert into a ModelContext. The caller (typically a ViewModel)
//  is responsible for `modelContext.insert(...)` so that creation can
//  be rolled back if the user dismisses the preview.
//
//  The mapping matches `Step.init` exactly: title comes from
//  `exerciseName`, `repsTarget` from `reps`, and `restSeconds` is
//  clamped by `Step.clampRest`. The plan's coaching cue is written
//  to `Step.note` so it surfaces inside the existing routine editor.
//

import Foundation

enum RoutineFactory {

    struct Output {
        let routine: Routine
        let steps: [Step]
    }

    static func makeRoutine(from plan: GeneratedPlan, now: Date = Date()) -> Output {
        let routine = Routine(
            name: plan.defaultTitle,
            createdAt: now,
            updatedAt: now
        )
        let steps = plan.exercises.enumerated().map { index, exercise in
            Step(
                routineId: routine.id,
                order: index,
                title: exercise.exerciseName,
                sets: exercise.sets,
                repsTarget: exercise.reps,
                restSeconds: exercise.restSeconds,
                note: exercise.cue
            )
        }
        return Output(routine: routine, steps: steps)
    }

    /// Builds a single-step `Routine` from a machine-derived
    /// `RoutineStepCandidate`. Like `makeRoutine(from:)` above this is
    /// pure — it does NOT insert into a `ModelContext`; the caller
    /// inserts only after the user explicitly confirms the save. The
    /// concrete sets / reps / rest come from the candidate's resolved
    /// values and are clamped by `Step.init`. A blank `title` falls back
    /// to the candidate's exercise name so the routine is never unnamed.
    static func makeRoutine(
        from candidate: RoutineStepCandidate,
        title: String,
        now: Date = Date()
    ) -> Output {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let routine = Routine(
            name: trimmedTitle.isEmpty ? candidate.exerciseName : trimmedTitle,
            createdAt: now,
            updatedAt: now
        )
        let step = Step(
            routineId: routine.id,
            order: 0,
            title: candidate.exerciseName,
            sets: candidate.resolvedSets,
            repsTarget: candidate.resolvedRepsTarget,
            restSeconds: candidate.resolvedRestSeconds,
            note: candidate.notes ?? ""
        )
        return Output(routine: routine, steps: [step])
    }
}
