//
//  GymEquipmentSetupTests.swift
//  Pulse CueTests
//
//  Covers the first-time gym equipment setup: the common-machine
//  suggestion is staged only for a newly registered gym with nothing
//  saved, never reaches `GymMachine` before the user saves, leaves
//  existing gyms and custom machines alone, and the one-time My Gym
//  review prompt does not come back once answered.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct GymEquipmentSetupTests {

    private static func makeContext() throws -> ModelContext {
        let schema = Schema([Gym.self, GymMachine.self, CustomMachine.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    /// Fresh, isolated defaults so tests never see each other's flags
    /// or the simulator's real `.standard` domain.
    private static func makeStore() -> GymEquipmentSetupStore {
        let suite = "GymEquipmentSetupTests.\(UUID().uuidString)"
        return GymEquipmentSetupStore(defaults: UserDefaults(suiteName: suite)!)
    }

    private static let common = Set(MachineCatalog.commonGymMachineIds)

    @Test
    func commonMachineIdsAllExistInCatalog() {
        for id in MachineCatalog.commonGymMachineIds {
            #expect(MachineCatalog.entry(for: id) != nil, "missing \(id)")
        }
        #expect(Self.common.count == MachineCatalog.commonGymMachineIds.count)
    }

    @Test
    func newGymStagesSuggestionWithoutPersisting() throws {
        let context = try Self.makeContext()
        let repo = GymRepository(modelContext: context)
        let store = Self.makeStore()
        let gym = repo.createGym(name: "新規ジム")
        store.markNewGym(gym.id)

        let vm = ManualMachineSelectionViewModel(gym: gym, setupStore: store)
        vm.configure(modelContext: context)

        #expect(vm.selectedIds == Self.common)
        #expect(vm.isShowingSuggestedSelection)
        // Not yet saved → nothing the plan generator could read.
        #expect(repo.machines(for: gym).isEmpty)
        #expect(repo.availableEquipment(for: gym).isEmpty)
    }

    @Test
    func saveCommitsEditedSuggestionAndStopsSuggesting() throws {
        let context = try Self.makeContext()
        let repo = GymRepository(modelContext: context)
        let store = Self.makeStore()
        let gym = repo.createGym(name: "新規ジム")
        store.markNewGym(gym.id)

        let vm = ManualMachineSelectionViewModel(gym: gym, setupStore: store)
        vm.configure(modelContext: context)
        vm.toggle(try #require(MachineCatalog.entry(for: "treadmill")))
        vm.toggle(try #require(MachineCatalog.entry(for: "smith_machine")))
        vm.save()

        var expected = Self.common
        expected.remove("treadmill")
        expected.insert("smith_machine")
        #expect(Set(repo.machines(for: gym).map(\.machineId)) == expected)
        #expect(vm.isShowingSuggestedSelection == false)
        #expect(store.isAwaitingInitialSetup(gym.id) == false)
        #expect(store.isReviewPromptPending(gym.id) == false)

        // Saving an empty selection later must not bring suggestions back.
        let reopened = ManualMachineSelectionViewModel(gym: gym, setupStore: store)
        reopened.configure(modelContext: context)
        for id in expected {
            reopened.toggle(try #require(MachineCatalog.entry(for: id)))
        }
        reopened.save()
        let third = ManualMachineSelectionViewModel(gym: gym, setupStore: store)
        third.configure(modelContext: context)
        #expect(third.selectedIds.isEmpty)
        #expect(third.isShowingSuggestedSelection == false)
    }

    @Test
    func leavingWithoutSavingKeepsSuggestionForNextVisit() throws {
        let context = try Self.makeContext()
        let repo = GymRepository(modelContext: context)
        let store = Self.makeStore()
        let gym = repo.createGym(name: "新規ジム")
        store.markNewGym(gym.id)

        let first = ManualMachineSelectionViewModel(gym: gym, setupStore: store)
        first.configure(modelContext: context)
        first.toggle(try #require(MachineCatalog.entry(for: "bike")))
        // No save: user backs out.

        #expect(repo.machines(for: gym).isEmpty)
        let second = ManualMachineSelectionViewModel(gym: gym, setupStore: store)
        second.configure(modelContext: context)
        #expect(second.selectedIds == Self.common)
    }

    @Test
    func existingGymIsNeverPreselected() throws {
        let context = try Self.makeContext()
        let repo = GymRepository(modelContext: context)
        let store = Self.makeStore()
        // Registered before this feature: never marked.
        let empty = repo.createGym(name: "既存ジム（未設定）")
        let configured = repo.createGym(name: "既存ジム（設定済み）")
        repo.setMachines(["bench_press"], for: configured)

        let emptyVM = ManualMachineSelectionViewModel(gym: empty, setupStore: store)
        emptyVM.configure(modelContext: context)
        #expect(emptyVM.selectedIds.isEmpty)
        #expect(emptyVM.isShowingSuggestedSelection == false)

        let configuredVM = ManualMachineSelectionViewModel(gym: configured, setupStore: store)
        configuredVM.configure(modelContext: context)
        #expect(configuredVM.selectedIds == ["bench_press"])
        #expect(configuredVM.isShowingSuggestedSelection == false)
        #expect(Set(repo.machines(for: configured).map(\.machineId)) == ["bench_press"])
    }

    @Test
    func markedGymWithSavedMachinesIsNotOverwritten() throws {
        let context = try Self.makeContext()
        let repo = GymRepository(modelContext: context)
        let store = Self.makeStore()
        let gym = repo.createGym(name: "ジム")
        store.markNewGym(gym.id)
        repo.setMachines(["cable_machine"], for: gym)

        let vm = ManualMachineSelectionViewModel(gym: gym, setupStore: store)
        vm.configure(modelContext: context)
        #expect(vm.selectedIds == ["cable_machine"])
        #expect(vm.isShowingSuggestedSelection == false)
    }

    @Test
    func customMachinesSurviveSuggestionAndSave() throws {
        let context = try Self.makeContext()
        let repo = GymRepository(modelContext: context)
        let store = Self.makeStore()
        let gym = repo.createGym(name: "新規ジム")
        store.markNewGym(gym.id)
        let custom = try repo.addCustomMachine(
            to: gym,
            displayName: "オリジナルマシン",
            bodyParts: [.chest],
            equipmentType: .machine
        )
        repo.setCustomMachineAvailability(custom, isAvailable: false)

        let vm = ManualMachineSelectionViewModel(gym: gym, setupStore: store)
        vm.configure(modelContext: context)
        #expect(vm.isShowingSuggestedSelection)
        #expect(vm.customMachines.map(\.id) == [custom.id])
        vm.toggleCustom(custom)
        vm.save()

        let stored = try #require(repo.customMachine(withId: custom.id))
        #expect(stored.displayName == "オリジナルマシン")
        #expect(stored.isAvailable)
        #expect(Set(repo.machines(for: gym).map(\.machineId)) == Self.common)
    }

    @Test
    func availableCustomMachineSuppressesSuggestion() throws {
        let context = try Self.makeContext()
        let repo = GymRepository(modelContext: context)
        let store = Self.makeStore()
        let gym = repo.createGym(name: "新規ジム")
        store.markNewGym(gym.id)
        let custom = try repo.addCustomMachine(
            to: gym,
            displayName: "家の器具",
            bodyParts: [.arms],
            equipmentType: .freeWeight
        )
        repo.setCustomMachineAvailability(custom, isAvailable: true)

        let vm = ManualMachineSelectionViewModel(gym: gym, setupStore: store)
        vm.configure(modelContext: context)
        #expect(vm.selectedIds.isEmpty)
        #expect(vm.availableCustomIds == [custom.id])
        #expect(vm.isShowingSuggestedSelection == false)
    }

    // MARK: - One-time review prompt

    @Test
    func reviewPromptShowsOnceForNewActiveGym() throws {
        let context = try Self.makeContext()
        let repo = GymRepository(modelContext: context)
        let store = Self.makeStore()
        let gym = repo.createGym(name: "新規ジム", makeActive: true)
        store.markNewGym(gym.id)

        let home = MyGymHomeViewModel(setupStore: store)
        home.configure(modelContext: context)
        #expect(home.equipmentReviewPromptGym?.id == gym.id)

        home.answerEquipmentReviewPrompt()
        #expect(home.equipmentReviewPromptGym == nil)

        home.reload()
        #expect(home.equipmentReviewPromptGym == nil)
        let another = MyGymHomeViewModel(setupStore: store)
        another.configure(modelContext: context)
        #expect(another.equipmentReviewPromptGym == nil)
        // Answering「あとで」keeps the suggestion for the first real setup.
        #expect(store.isAwaitingInitialSetup(gym.id))
    }

    @Test
    func reviewPromptNotShownForExistingOrSavedGym() throws {
        let context = try Self.makeContext()
        let repo = GymRepository(modelContext: context)
        let store = Self.makeStore()
        let gym = repo.createGym(name: "既存ジム", makeActive: true)

        let home = MyGymHomeViewModel(setupStore: store)
        home.configure(modelContext: context)
        #expect(home.equipmentReviewPromptGym == nil)

        store.markNewGym(gym.id)
        store.markConfirmed(gym.id)
        home.reload()
        #expect(home.equipmentReviewPromptGym == nil)
    }
}
