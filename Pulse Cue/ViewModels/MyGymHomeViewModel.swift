//
//  MyGymHomeViewModel.swift
//  Pulse Cue
//
//  Backs the「マイジム」hub screen. Owns the list of registered gyms
//  and the active-gym invariant; defers actual persistence to
//  `GymRepository`. The view passes its `ModelContext` in via
//  `configure(modelContext:)` once it's known so the same VM survives
//  re-renders without rebuilding state.
//

import Foundation
import Combine
import SwiftData

@MainActor
final class MyGymHomeViewModel: ObservableObject {
    @Published private(set) var gyms: [Gym] = []
    @Published private(set) var activeGym: Gym?

    private var modelContext: ModelContext?
    private var repository: GymRepository? {
        modelContext.map(GymRepository.init(modelContext:))
    }

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        reload()
    }

    func reload() {
        guard let repository else { return }
        gyms = repository.allGyms()
        activeGym = repository.activeGym()
    }

    func setActive(_ gym: Gym) {
        repository?.setActive(gym)
        reload()
    }

    func delete(_ gym: Gym) {
        repository?.deleteGym(gym)
        reload()
    }

    /// Returns the count of saved `GymMachine` rows for a gym so the
    /// hub screen can show "12 台のマシン" without each row touching
    /// SwiftData.
    func machineCount(for gym: Gym) -> Int {
        repository?.machines(for: gym).count ?? 0
    }
}
