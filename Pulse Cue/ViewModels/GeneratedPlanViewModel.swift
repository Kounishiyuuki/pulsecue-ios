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
