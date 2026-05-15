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
        let machines = repository.machines(for: gym)
        plan = WorkoutPlanGenerator.generate(
            bodyPart: bodyPart,
            gym: gym,
            availableMachines: machines
        )
        state = .generated
    }

    /// Persists the current plan as a new `Routine` plus ordered
    /// `Step` rows. Refuses to save an empty plan so the user can't
    /// accidentally create a blank routine.
    func saveAsRoutine() {
        guard let modelContext else {
            state = .error("内部エラー: モデル未初期化")
            return
        }
        guard let plan, !plan.isEmpty else {
            state = .error("保存できる種目がありません")
            return
        }

        state = .saving
        let output = RoutineFactory.makeRoutine(from: plan)
        modelContext.insert(output.routine)
        for step in output.steps {
            modelContext.insert(step)
        }
        state = .saved(routineId: output.routine.id)
    }
}
