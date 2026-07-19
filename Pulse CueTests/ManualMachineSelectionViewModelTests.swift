//
//  ManualMachineSelectionViewModelTests.swift
//  Pulse CueTests
//
//  Covers the My Gym manual machine-selection view model: search and
//  body-part filtering (reusing `MachineCatalogQuery`), selection
//  stability while filters change, the "selected only" review mode, and
//  that saving writes the complete selected set — including machines
//  hidden by the active filter — through `GymRepository.setMachines`.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct ManualMachineSelectionViewModelTests {

    private static func makeContext() throws -> ModelContext {
        let schema = Schema([Routine.self, Step.self, Gym.self, GymMachine.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private static func makeConfiguredVM() throws -> (ManualMachineSelectionViewModel, GymRepository, Gym, ModelContext) {
        let context = try makeContext()
        let repo = GymRepository(modelContext: context)
        let gym = repo.createGym(name: "テストジム")
        let vm = ManualMachineSelectionViewModel(gym: gym)
        vm.configure(modelContext: context)
        return (vm, repo, gym, context)
    }

    // MARK: - Filtering

    @Test
    func initialResultsAreUnfiltered() {
        let vm = ManualMachineSelectionViewModel(gym: Gym(name: "T"))
        #expect(vm.visibleEntries.count == MachineCatalog.all.count)
        #expect(vm.visibleCount == vm.totalCount)
        #expect(vm.hasActiveFilters == false)
    }

    @Test
    func searchFiltersByStableId() {
        let vm = ManualMachineSelectionViewModel(gym: Gym(name: "T"))
        vm.searchText = "lat_pulldown"
        #expect(vm.visibleEntries.map(\.id) == ["lat_pulldown"])
        #expect(vm.hasActiveFilters)
    }

    @Test
    func searchIsWhitespaceTolerant() {
        let vm = ManualMachineSelectionViewModel(gym: Gym(name: "T"))
        vm.searchText = "   "
        // Whitespace-only search must not filter anything out.
        #expect(vm.visibleEntries.count == MachineCatalog.all.count)
        #expect(vm.hasActiveFilters == false)
    }

    @Test
    func bodyPartFilterReturnsMatchingMachines() {
        let vm = ManualMachineSelectionViewModel(gym: Gym(name: "T"))
        vm.selectedBodyParts = [.legs]
        #expect(!vm.visibleEntries.isEmpty)
        #expect(vm.visibleEntries.allSatisfy { $0.bodyParts.contains(.legs) })
        #expect(vm.visibleEntries.contains { $0.id == "leg_press" })
    }

    @Test
    func combinedSearchAndBodyPartFilter() {
        let vm = ManualMachineSelectionViewModel(gym: Gym(name: "T"))
        vm.searchText = "leg"
        vm.selectedBodyParts = [.legs]
        // ids containing "leg" that also train legs.
        #expect(Set(vm.visibleEntries.map(\.id)) == ["leg_curl", "leg_extension", "leg_press"])
    }

    @Test
    func clearFiltersRestoresFullList() {
        let vm = ManualMachineSelectionViewModel(gym: Gym(name: "T"))
        vm.searchText = "leg"
        vm.selectedBodyParts = [.legs]
        vm.showSelectedOnly = true
        vm.clearFilters()
        #expect(vm.searchText.isEmpty)
        #expect(vm.selectedBodyParts.isEmpty)
        #expect(vm.showSelectedOnly == false)
        #expect(vm.visibleEntries.count == MachineCatalog.all.count)
    }

    @Test
    func noResultStateForUnmatchedSearch() {
        let vm = ManualMachineSelectionViewModel(gym: Gym(name: "T"))
        vm.searchText = "zzz-no-such-machine"
        #expect(vm.visibleEntries.isEmpty)
        #expect(vm.hasActiveFilters)
    }

    // MARK: - Selection stability

    @Test
    func selectionSurvivesFilterChange() {
        let vm = ManualMachineSelectionViewModel(gym: Gym(name: "T"))
        let legPress = MachineCatalog.entry(for: "leg_press")!
        vm.toggle(legPress)
        #expect(vm.isSelected(legPress))

        // Filter to a body part that excludes leg_press.
        vm.selectedBodyParts = [.chest]
        #expect(!vm.visibleEntries.contains { $0.id == "leg_press" })
        // Still selected, just hidden.
        #expect(vm.isSelected(legPress))
        #expect(vm.selectedCount == 1)
        #expect(vm.hiddenSelectedCount == 1)
    }

    @Test
    func toggleSelectsAndDeselects() {
        let vm = ManualMachineSelectionViewModel(gym: Gym(name: "T"))
        let bench = MachineCatalog.entry(for: "bench_press")!
        vm.toggle(bench)
        #expect(vm.isSelected(bench))
        vm.toggle(bench)
        #expect(!vm.isSelected(bench))
        #expect(vm.selectedCount == 0)
    }

    @Test
    func selectedOnlyModeShowsOnlySelected() {
        let vm = ManualMachineSelectionViewModel(gym: Gym(name: "T"))
        vm.toggle(MachineCatalog.entry(for: "bench_press")!)
        vm.toggle(MachineCatalog.entry(for: "leg_press")!)
        vm.showSelectedOnly = true
        #expect(Set(vm.visibleEntries.map(\.id)) == ["bench_press", "leg_press"])
    }

    // MARK: - Save (persistence)

    @Test
    func saveWritesAllSelectedIncludingFilteredOut() throws {
        let (vm, repo, gym, _) = try Self.makeConfiguredVM()
        vm.toggle(MachineCatalog.entry(for: "bench_press")!)
        vm.toggle(MachineCatalog.entry(for: "leg_press")!)

        // Hide leg_press behind a body-part filter, then save.
        vm.selectedBodyParts = [.chest]
        #expect(!vm.visibleEntries.contains { $0.id == "leg_press" })
        vm.save()

        #expect(vm.state == .saved)
        let saved = Set(repo.machines(for: gym).map(\.machineId))
        #expect(saved == ["bench_press", "leg_press"])
    }

    @Test
    func reopeningRestoresSelection() throws {
        let context = try Self.makeContext()
        let repo = GymRepository(modelContext: context)
        let gym = repo.createGym(name: "テストジム")

        let first = ManualMachineSelectionViewModel(gym: gym)
        first.configure(modelContext: context)
        first.toggle(MachineCatalog.entry(for: "lat_pulldown")!)
        first.save()

        // A fresh view model over the same gym restores the saved ids.
        let second = ManualMachineSelectionViewModel(gym: gym)
        second.configure(modelContext: context)
        #expect(second.selectedIds == ["lat_pulldown"])
        #expect(second.selectedCount == 1)
    }

    @Test
    func selectionsAreScopedPerGym() throws {
        let context = try Self.makeContext()
        let repo = GymRepository(modelContext: context)
        let gymA = repo.createGym(name: "A")
        let gymB = repo.createGym(name: "B")

        let vmA = ManualMachineSelectionViewModel(gym: gymA)
        vmA.configure(modelContext: context)
        vmA.toggle(MachineCatalog.entry(for: "bench_press")!)
        vmA.save()

        let vmB = ManualMachineSelectionViewModel(gym: gymB)
        vmB.configure(modelContext: context)
        vmB.toggle(MachineCatalog.entry(for: "treadmill")!)
        vmB.save()

        #expect(Set(repo.machines(for: gymA).map(\.machineId)) == ["bench_press"])
        #expect(Set(repo.machines(for: gymB).map(\.machineId)) == ["treadmill"])
    }
}
