//
//  WorkoutStarter.swift
//  Pulse Cue
//
//  The single Runner-start path, shared by the routine list and Quick Plan.
//  Only the *start* is extracted here — Runner initialization itself stays in
//  `RunnerViewModel` (not duplicated), and there is no Quick-Plan-specific
//  session source of truth.
//
//  It preserves the existing 3-layer rest hierarchy: the steps' current rest
//  values seed `RoutineRestPreferenceStore.prepareRoutine`, then each step's
//  rest is resolved as step-override → routine-default → app-default before
//  the workout begins — exactly what `WorkoutView.startRoutine` did.
//

import Foundation
import SwiftData

enum WorkoutStarter {

    /// Seeds rest preferences from `steps`, resolves each step's rest through
    /// the 3-layer hierarchy, persists, then hands the routine to the runner.
    /// A no-op for an empty routine so an emptily-generated plan can never
    /// start a blank session.
    @MainActor
    static func start(
        routine: Routine,
        steps: [Step],
        modelContext: ModelContext,
        restStore: RoutineRestPreferenceStore,
        appDefaultRestSeconds: Int,
        runner: RunnerViewModel
    ) {
        guard !steps.isEmpty else { return }
        restStore.prepareRoutine(
            routine.id,
            existingStepRests: steps
                .sorted { $0.order < $1.order }
                .map { (id: $0.id, seconds: $0.restSeconds) },
            appDefault: appDefaultRestSeconds
        )
        let routineRest = restStore.routineDefault(for: routine.id, appDefault: appDefaultRestSeconds)
        for step in steps {
            step.restSeconds = restStore.stepOverride(for: step.id) ?? routineRest
        }
        try? modelContext.save()
        runner.start(routine: routine)
    }
}
