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

    // MARK: - Custom machines
    //
    // Custom machines live in their own SwiftData entity, so they are
    // loaded separately and rendered in their own section. Their
    // *availability* is staged exactly like the standard selection: it is
    // held in `availableCustomIds` and only written on「プランを保存」, so
    // the screen has one consistent save semantic. Create / edit / delete
    // are different — each is its own explicit action (a form save or a
    // destructive confirmation) and persists immediately.

    @Published private(set) var customMachines: [CustomMachine] = []
    @Published private(set) var availableCustomIds: Set<UUID> = []

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
        reloadCustomMachines()
    }

    /// Re-reads the gym's custom machines. Called after the form sheet
    /// saves or a delete is confirmed so counts and filters stay correct.
    /// Staged availability for machines that still exist is preserved;
    /// newly created machines adopt their persisted availability.
    func reloadCustomMachines() {
        guard let repository else { return }
        let rows = repository.customMachines(for: gym)
        let knownIds = Set(customMachines.map(\.id))
        var staged = availableCustomIds.intersection(Set(rows.map(\.id)))
        for row in rows where !knownIds.contains(row.id) && row.isAvailable {
            staged.insert(row.id)
        }
        customMachines = rows
        availableCustomIds = staged
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

    /// Custom machines passing the current search + body-part filter.
    /// Matching goes through the same `MachineCatalogQuery` the standard
    /// list uses (via `AvailableEquipment`), so text search and body-part
    /// filters combine identically for both sources.
    var customQueryResults: [CustomMachine] {
        let query = self.query
        return customMachines.filter { AvailableEquipment(custom: $0).matches(query) }
    }

    /// The custom rows the list actually renders.
    var visibleCustomMachines: [CustomMachine] {
        guard showSelectedOnly else { return customQueryResults }
        return customQueryResults.filter { availableCustomIds.contains($0.id) }
    }

    var totalCount: Int { MachineCatalog.all.count }
    var visibleCount: Int { visibleEntries.count }
    var selectedCount: Int { selectedIds.count }
    var customSelectedCount: Int { availableCustomIds.count }
    /// Standard + custom, so the save bar reflects everything being saved.
    var totalSelectedCount: Int { selectedCount + customSelectedCount }
    var hasCustomMachines: Bool { !customMachines.isEmpty }
    var hasSelection: Bool { !selectedIds.isEmpty || !availableCustomIds.isEmpty }

    /// Selected machines — standard and custom — that the current search +
    /// body-part filter hides, so the View can reassure the user they are
    /// still saved rather than silently dropped.
    var hiddenSelectedCount: Int {
        let shownStandard = Set(queryResults.map(\.id))
        let hiddenStandard = selectedIds.subtracting(shownStandard).count
        let shownCustom = Set(customQueryResults.map(\.id))
        let hiddenCustom = availableCustomIds.subtracting(shownCustom).count
        return hiddenStandard + hiddenCustom
    }

    /// True when the filter produced nothing at all on either side.
    var hasNoVisibleEquipment: Bool {
        visibleEntries.isEmpty && visibleCustomMachines.isEmpty
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

    // MARK: - Custom mutations

    func isCustomSelected(_ machine: CustomMachine) -> Bool {
        availableCustomIds.contains(machine.id)
    }

    /// Stages an availability change. Persisted on save, like the
    /// standard selection.
    func toggleCustom(_ machine: CustomMachine) {
        if availableCustomIds.contains(machine.id) {
            availableCustomIds.remove(machine.id)
        } else {
            availableCustomIds.insert(machine.id)
        }
    }

    /// Hard-deletes one custom machine by its UUID. Called only after the
    /// destructive confirmation dialog. Standard machines and all saved
    /// routines/sessions/history are untouched; a record that has already
    /// been deleted is simply ignored.
    func deleteCustom(_ machine: CustomMachine) {
        guard let repository else {
            state = .error("内部エラー: モデル未初期化")
            return
        }
        let id = machine.id
        guard let stored = repository.customMachine(withId: id) else {
            reloadCustomMachines()
            return
        }
        repository.deleteCustomMachine(stored)
        availableCustomIds.remove(id)
        reloadCustomMachines()
    }

    // MARK: - Save

    /// Writes both halves of the staged selection: the standard catalog
    /// ids through `setMachines`, and each custom machine's availability.
    func save() {
        guard let repository else {
            state = .error("内部エラー: モデル未初期化")
            return
        }
        state = .saving
        repository.setMachines(selectedIds, for: gym)
        for machine in customMachines {
            repository.setCustomMachineAvailability(
                machine,
                isAvailable: availableCustomIds.contains(machine.id)
            )
        }
        state = .saved
    }
}
