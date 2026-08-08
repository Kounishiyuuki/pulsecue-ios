//
//  GeneratedPlanViewModel.swift
//  Pulse Cue
//
//  Holds the most recently generated `GeneratedPlan` for a given gym
//  and body part, and converts it into a persisted `Routine` + `Step`
//  graph when the user taps「ルーティンとして保存」. The generator
//  itself is pure; this VM exists only to wire it to `ModelContext`
//  and to expose a save-state to SwiftUI.
//

import Foundation
import Combine
import SwiftData

@MainActor
final class GeneratedPlanViewModel: ObservableObject {

    enum State: Equatable {
        case idle
        case generated
        case saving
        case saved(routineId: UUID)
        case error(String)
    }

    let gym: Gym
    @Published private(set) var bodyPart: BodyPart
    /// Present for a Quick Plan (multi body part + duration + intensity);
    /// `nil` for the original single-body-part flow. When set, `regenerate`
    /// uses `WorkoutPlanGenerator.generate(request:)`.
    @Published private(set) var request: QuickPlanRequest?
    @Published private(set) var plan: GeneratedPlan?
    @Published private(set) var state: State = .idle

    private var modelContext: ModelContext?
    private var repository: GymRepository? {
        modelContext.map(GymRepository.init(modelContext:))
    }

    init(gym: Gym, bodyPart: BodyPart) {
        self.gym = gym
        self.bodyPart = bodyPart
    }

    init(gym: Gym, request: QuickPlanRequest) {
        self.gym = gym
        self.bodyPart = request.normalizedBodyParts.first ?? .fullBody
        self.request = request
    }

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        regenerate()
    }

    func update(bodyPart: BodyPart) {
        self.bodyPart = bodyPart
        regenerate()
    }

    func regenerate() {
        guard let repository else { return }
        // Standard selections + the gym's custom machines, already
        // narrowed to what is marked available. Pure read; nothing is
        // written and no Routine/Step is created until the user saves.
        let equipment = repository.availableEquipment(for: gym, availableOnly: true)
        if let request {
            plan = WorkoutPlanGenerator.generate(
                request: request,
                gym: gym,
                availableEquipment: equipment
            )
        } else {
            plan = WorkoutPlanGenerator.generate(
                bodyPart: bodyPart,
                gym: gym,
                availableEquipment: equipment
            )
        }
        state = .generated
    }

    /// The routine + steps this preview has already inserted, if any. Both
    /// "保存" and "この内容で開始" go through `materializeRoutine`, so the plan
    /// is turned into a `Routine` exactly once no matter how the two actions
    /// are combined — tapping one then the other never double-creates.
    private var materialized: RoutineFactory.Output?

    /// Creates and inserts the `Routine` + `Step` graph once, caching the
    /// result. Returns `nil` for a missing context or an empty plan.
    @discardableResult
    private func materializeRoutine() -> RoutineFactory.Output? {
        if let materialized { return materialized }
        guard let modelContext, let plan, !plan.isEmpty else { return nil }
        let output = RoutineFactory.makeRoutine(from: plan)
        modelContext.insert(output.routine)
        for step in output.steps {
            modelContext.insert(step)
        }
        materialized = output
        return output
    }

    /// Persists the current plan as a new `Routine` plus ordered `Step` rows.
    /// Refuses to save an empty plan so the user can't accidentally create a
    /// blank routine.
    func saveAsRoutine() {
        guard modelContext != nil else {
            state = .error("内部エラー: モデル未初期化")
            return
        }
        state = .saving
        guard let output = materializeRoutine() else {
            state = .error("保存できる種目がありません")
            return
        }
        state = .saved(routineId: output.routine.id)
    }

    /// Materializes the routine (once) and starts it through the shared
    /// `WorkoutStarter` — the same 3-layer-rest / Runner-init path the routine
    /// list uses. Reuses the already-saved routine if "保存" ran first.
    func startWorkout(
        restStore: RoutineRestPreferenceStore,
        appDefaultRestSeconds: Int,
        runner: RunnerViewModel
    ) {
        guard let modelContext, let output = materializeRoutine() else {
            state = .error("開始できる種目がありません")
            return
        }
        WorkoutStarter.start(
            routine: output.routine,
            steps: output.steps,
            modelContext: modelContext,
            restStore: restStore,
            appDefaultRestSeconds: appDefaultRestSeconds,
            runner: runner
        )
    }

    // MARK: - Exercise replacement

    /// Ranked alternatives for the exercise at `index`, from this gym's
    /// available equipment, excluding the other exercises already in the plan.
    /// Computed on demand (when the sheet opens), never per body render.
    func replacementCandidates(forExerciseAt index: Int) -> [GeneratedExercise] {
        guard let repository, let plan, plan.exercises.indices.contains(index) else { return [] }
        let equipment = repository.availableEquipment(for: gym, availableOnly: true)
        let original = plan.exercises[index]
        let others = Set(plan.exercises.enumerated().compactMap { $0.offset == index ? nil : $0.element.machineId })
        return WorkoutPlanGenerator.alternatives(
            toMachineId: original.machineId,
            bodyParts: bodyParts(for: original, equipment: equipment),
            usableEquipment: equipment,
            excludingMachineIds: others
        )
    }

    /// Replaces only the exercise at `index`, carrying over the original's
    /// sets / reps / rest (no "smart" auto-correction). The rest of the plan is
    /// untouched. Any already-materialized routine is discarded so a later
    /// 保存 / 開始 rebuilds from the updated plan.
    func replaceExercise(at index: Int, with candidate: GeneratedExercise) {
        guard let plan, plan.exercises.indices.contains(index) else { return }
        let original = plan.exercises[index]
        let replacement = GeneratedExercise(
            machineId: candidate.machineId,
            exerciseName: candidate.exerciseName,
            sets: original.sets,
            reps: original.reps,
            restSeconds: original.restSeconds,
            cue: candidate.cue,
            exerciseId: candidate.exerciseId
        )
        var exercises = plan.exercises
        exercises[index] = replacement
        self.plan = GeneratedPlan(
            bodyPart: plan.bodyPart,
            bodyParts: plan.bodyParts,
            gymId: plan.gymId,
            gymName: plan.gymName,
            exercises: exercises,
            warnings: plan.warnings
        )
        // The saved/started routine (if any) no longer matches the plan.
        materialized = nil
    }

    /// Body parts to search for alternatives: the machine's catalog parts,
    /// else its custom-equipment parts, else the plan's target parts.
    private func bodyParts(for exercise: GeneratedExercise, equipment: [AvailableEquipment]) -> Set<BodyPart> {
        if let entry = MachineCatalog.entry(for: exercise.machineId) {
            return entry.bodyParts
        }
        if let custom = equipment.first(where: { $0.id == exercise.machineId }) {
            return custom.bodyParts
        }
        return Set(plan?.bodyParts ?? [bodyPart])
    }
}
