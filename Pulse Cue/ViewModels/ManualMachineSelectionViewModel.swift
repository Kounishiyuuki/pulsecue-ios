//
//  ManualMachineSelectionViewModel.swift
//  Pulse Cue
//
//  Drives the toggle list that lets the user mark which catalog
//  machines exist at the current gym. Loads the saved selection from
//  SwiftData on configure, mutates it locally as the user taps, and
//  pushes the resulting set back through `GymRepository.setMachines`
//  on save.
//

import Foundation
import Combine
import SwiftData

@MainActor
final class ManualMachineSelectionViewModel: ObservableObject {

    enum State: Equatable {
        case idle
        case saving
        case saved
        case error(String)
    }

    let gym: Gym

    @Published private(set) var state: State = .idle
    @Published private(set) var selectedIds: Set<String> = []

    let catalog: [MachineCatalogEntry] = MachineCatalog.all

    private var modelContext: ModelContext?
    private var repository: GymRepository? {
        modelContext.map(GymRepository.init(modelContext:))
    }

    init(gym: Gym) {
        self.gym = gym
    }

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        guard let repository else { return }
        selectedIds = Set(repository.machines(for: gym).map(\.machineId))
    }

    func isSelected(_ entry: MachineCatalogEntry) -> Bool {
        selectedIds.contains(entry.id)
    }

    func toggle(_ entry: MachineCatalogEntry) {
        if selectedIds.contains(entry.id) {
            selectedIds.remove(entry.id)
        } else {
            selectedIds.insert(entry.id)
        }
    }

    var hasSelection: Bool { !selectedIds.isEmpty }

    func save() {
        guard let repository else {
            state = .error("内部エラー: モデル未初期化")
            return
        }
        state = .saving
        repository.setMachines(selectedIds, for: gym)
        state = .saved
    }
}
