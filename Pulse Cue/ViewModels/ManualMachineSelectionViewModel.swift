//
//  ManualMachineSelectionViewModel.swift
//  Pulse Cue
//
//  Drives the machine list that lets the user mark which catalog
//  machines exist at the current gym. Loads the saved selection from
//  SwiftData on configure, mutates it locally as the user taps, and
//  pushes the resulting set back through `GymRepository.setMachines`
//  on save.
//
//  Search / body-part filtering reuse the pure `MachineCatalogQuery`
//  helpers (same behavior as the read-only `MachineCatalogListView`).
//  The filtered results are computed here rather than in the View so a
//  complex SwiftUI body never recomputes the query, and so body-part
//  mapping logic lives in one place. `selectedIds` always holds the
//  complete selection independent of the active filter, so hiding a
//  selected machine via search/filter never drops it on save.
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

    // MARK: - Filter state
    @Published var searchText: String = ""
    @Published var selectedBodyParts: Set<BodyPart> = []
    /// When on, the list is narrowed to already-selected machines so the
    /// user can review the current selection without a secondary screen.
    @Published var showSelectedOnly: Bool = false

    /// Body-part chips shown in the filter row. `fullBody` is relabeled to
    /// 有酸素 at the View layer only (matches `MachineCatalogListView`).
    let bodyPartFilters: [BodyPart] = [
        .chest, .back, .shoulders, .arms, .legs, .core, .fullBody
    ]

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

    // MARK: - Derived catalog results

    private var query: MachineCatalogQuery {
        MachineCatalogQuery(
            searchText: searchText,
            bodyParts: Array(selectedBodyParts)
        )
    }

    /// Catalog entries matching the current search + body-part filter,
    /// before the "selected only" narrowing is applied.
    var queryResults: [MachineCatalogEntry] {
        MachineCatalog.filteredEntries(matching: query)
    }

    /// The rows the list actually renders.
    var visibleEntries: [MachineCatalogEntry] {
        guard showSelectedOnly else { return queryResults }
        return queryResults.filter { selectedIds.contains($0.id) }
    }

    var totalCount: Int { MachineCatalog.all.count }
    var visibleCount: Int { visibleEntries.count }
    var selectedCount: Int { selectedIds.count }
    var hasSelection: Bool { !selectedIds.isEmpty }

    /// Selected machines that the current search + body-part filter hides,
    /// so the View can reassure the user they are still saved.
    var hiddenSelectedCount: Int {
        let shown = Set(queryResults.map(\.id))
        return selectedIds.subtracting(shown).count
    }

    var hasActiveFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !selectedBodyParts.isEmpty
            || showSelectedOnly
    }

    // MARK: - Mutations

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

    func toggleBodyPart(_ part: BodyPart) {
        if selectedBodyParts.contains(part) {
            selectedBodyParts.remove(part)
        } else {
            selectedBodyParts.insert(part)
        }
    }

    func clearFilters() {
        searchText = ""
        selectedBodyParts.removeAll()
        showSelectedOnly = false
    }

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
