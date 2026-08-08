//
//  CustomMachineEndToEndTests.swift
//  Pulse CueTests
//
//  Covers the whole custom-machine user value as one flow rather than
//  per-layer: create/edit/delete through the repository and the selection
//  view model, search + filtering across standard AND custom equipment,
//  both local planners consuming the unified `AvailableEquipment`, and the
//  generate → preview → explicit save boundary plus what happens to a
//  saved routine when the custom machine is later renamed or deleted.
//
//  In-memory stores throughout: on-disk migration behavior is covered by
//  `CustomMachineMigrationTests`.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct CustomMachineEndToEndTests {

    private static func makeRepo() throws -> (GymRepository, ModelContext) {
        let schema = Schema(versionedSchema: PulseCueSchemaV5.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        return (GymRepository(modelContext: context), context)
    }

    // MARK: - Management

    @Test
    func createdCustomMachineBelongsToItsGymOnly() throws {
        let (repo, _) = try Self.makeRepo()
        let gymA = repo.createGym(name: "A")
        let gymB = repo.createGym(name: "B")
        _ = try repo.addCustomMachine(to: gymA, displayName: "旧型レッグプレス", bodyParts: [.legs])

        #expect(repo.customMachines(for: gymA).map(\.displayName) == ["旧型レッグプレス"])
        #expect(repo.customMachines(for: gymB).isEmpty)
    }

    @Test
    func editPreservesIdentityButChangesFuturePlannerValue() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "A")
        let machine = try repo.addCustomMachine(to: gym, displayName: "旧名", bodyParts: [.chest])
        let originalId = machine.id
        let originalRef = machine.referenceId

        try repo.updateCustomMachine(machine, displayName: "新名", bodyParts: [.back])

        #expect(machine.id == originalId)
        #expect(machine.referenceId == originalRef)
        // Future generation now sees the new name and the new body part.
        let equipment = repo.availableEquipment(for: gym, availableOnly: true)
        let customs = equipment.filter(\.isCustom)
        let custom = try #require(customs.first)
        #expect(custom.displayName == "新名")
        #expect(custom.bodyParts == [.back])
    }

    @Test
    func deleteRemovesMachineButLeavesSavedRoutineQueryable() throws {
        let (repo, context) = try Self.makeRepo()
        let gym = repo.createGym(name: "A")
        let machine = try repo.addCustomMachine(to: gym, displayName: "自作マシン", bodyParts: [.chest])

        // A routine saved from a plan that used the custom machine.
        let plan = WorkoutPlanGenerator.generate(
            bodyPart: .chest,
            gym: gym,
            availableEquipment: repo.availableEquipment(for: gym, availableOnly: true)
        )
        let output = RoutineFactory.makeRoutine(from: plan)
        context.insert(output.routine)
        for step in output.steps { context.insert(step) }

        repo.deleteCustomMachine(machine)

        #expect(repo.customMachines(for: gym).isEmpty)
        let routines = try context.fetch(FetchDescriptor<Routine>())
        let steps = try context.fetch(FetchDescriptor<Step>())
        #expect(routines.count == 1)
        #expect(steps.contains { $0.title == "自作マシン" })
    }

    @Test
    func unavailableCustomMachineIsExcludedFromEquipment() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "A")
        let machine = try repo.addCustomMachine(to: gym, displayName: "使わないマシン", bodyParts: [.chest])
        repo.setCustomMachineAvailability(machine, isAvailable: false)

        let plannerView = repo.availableEquipment(for: gym, availableOnly: true)
        let managementView = repo.availableEquipment(for: gym, availableOnly: false)
        #expect(plannerView.isEmpty)
        // Still visible (and editable) in the management list.
        #expect(managementView.count == 1)
        #expect(managementView.first?.isAvailable == false)
    }

    // MARK: - Selection view model: search / filter / staging

    private static func makeSelectionVM() throws -> (ManualMachineSelectionViewModel, GymRepository, Gym, ModelContext) {
        let (repo, context) = try makeRepo()
        let gym = repo.createGym(name: "テストジム")
        let vm = ManualMachineSelectionViewModel(gym: gym)
        vm.configure(modelContext: context)
        return (vm, repo, gym, context)
    }

    @Test
    func customMachineIsFoundByDisplayNameSearch() throws {
        let (vm, repo, gym, _) = try Self.makeSelectionVM()
        _ = try repo.addCustomMachine(to: gym, displayName: "特殊プレス", bodyParts: [.chest])
        vm.reloadCustomMachines()

        vm.searchText = "特殊"
        #expect(vm.visibleCustomMachines.map(\.displayName) == ["特殊プレス"])
        // The standard catalog has nothing by that name.
        #expect(vm.visibleEntries.isEmpty)
        #expect(!vm.hasNoVisibleEquipment)
    }

    @Test
    func customMachineParticipatesInBodyPartFilter() throws {
        let (vm, repo, gym, _) = try Self.makeSelectionVM()
        _ = try repo.addCustomMachine(to: gym, displayName: "自作レッグ", bodyParts: [.legs])
        vm.reloadCustomMachines()

        vm.selectedBodyParts = [.legs]
        #expect(vm.visibleCustomMachines.count == 1)
        // Standard leg machines are still listed alongside it.
        #expect(vm.visibleEntries.contains { $0.id == "leg_press" })

        vm.selectedBodyParts = [.chest]
        #expect(vm.visibleCustomMachines.isEmpty)
    }

    @Test
    func noResultStateCoversBothSources() throws {
        let (vm, repo, gym, _) = try Self.makeSelectionVM()
        _ = try repo.addCustomMachine(to: gym, displayName: "自作", bodyParts: [.chest])
        vm.reloadCustomMachines()

        vm.searchText = "zzz-no-such-machine"
        #expect(vm.visibleEntries.isEmpty)
        #expect(vm.visibleCustomMachines.isEmpty)
        #expect(vm.hasNoVisibleEquipment)
    }

    @Test
    func newCustomMachineIsStagedAsAvailableAndCountsTowardTotal() throws {
        let (vm, repo, gym, _) = try Self.makeSelectionVM()
        vm.toggle(MachineCatalog.entry(for: "bench_press")!)
        _ = try repo.addCustomMachine(to: gym, displayName: "自作", bodyParts: [.chest])
        vm.reloadCustomMachines()

        #expect(vm.customSelectedCount == 1)
        #expect(vm.selectedCount == 1)
        #expect(vm.totalSelectedCount == 2)
    }

    @Test
    func customAvailabilityIsStagedUntilSave() throws {
        let (vm, repo, gym, _) = try Self.makeSelectionVM()
        let machine = try repo.addCustomMachine(to: gym, displayName: "自作", bodyParts: [.chest])
        vm.reloadCustomMachines()

        vm.toggleCustom(machine)
        #expect(vm.isCustomSelected(machine) == false)
        // Not written yet — staging only, exactly like the standard list.
        #expect(machine.isAvailable == true)

        vm.save()
        #expect(vm.state == .saved)
        #expect(machine.isAvailable == false)
    }

    @Test
    func hiddenSelectedCountIncludesStagedCustomMachines() throws {
        let (vm, repo, gym, _) = try Self.makeSelectionVM()
        _ = try repo.addCustomMachine(to: gym, displayName: "自作チェスト", bodyParts: [.chest])
        vm.reloadCustomMachines()

        // Filter to legs: the selected custom chest machine is hidden but
        // must still be reported as saved, not silently dropped.
        vm.selectedBodyParts = [.legs]
        #expect(vm.visibleCustomMachines.isEmpty)
        #expect(vm.hiddenSelectedCount >= 1)

        vm.save()
        #expect(repo.customMachines(for: gym).first?.isAvailable == true)
    }

    @Test
    func deleteThroughViewModelRemovesOnlyThatMachine() throws {
        let (vm, repo, gym, _) = try Self.makeSelectionVM()
        let a = try repo.addCustomMachine(to: gym, displayName: "A", bodyParts: [.chest])
        _ = try repo.addCustomMachine(to: gym, displayName: "B", bodyParts: [.back])
        vm.reloadCustomMachines()

        vm.deleteCustom(a)
        #expect(vm.customMachines.map(\.displayName) == ["B"])
        #expect(repo.customMachines(for: gym).count == 1)
    }

    @Test
    func deletingAnAlreadyDeletedMachineDoesNotCrash() throws {
        let (vm, repo, gym, context) = try Self.makeSelectionVM()
        let machine = try repo.addCustomMachine(to: gym, displayName: "消える", bodyParts: [.chest])
        vm.reloadCustomMachines()

        // Deleted behind the view model's back.
        context.delete(machine)

        vm.deleteCustom(machine)
        #expect(vm.customMachines.isEmpty)
    }

    // MARK: - Single-workout planner

    @Test
    func customMachineEntersSingleWorkoutPlanForMatchingBodyPart() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "A")
        _ = try repo.addCustomMachine(to: gym, displayName: "自作チェストマシン", bodyParts: [.chest])

        let plan = WorkoutPlanGenerator.generate(
            bodyPart: .chest,
            gym: gym,
            availableEquipment: repo.availableEquipment(for: gym, availableOnly: true)
        )
        let exercise = try #require(plan.exercises.first { $0.exerciseName == "自作チェストマシン" })
        // Conservative, honest fallback — not an invented prescription.
        #expect(exercise.sets == WorkoutPlanGenerator.customFallbackSets)
        #expect(exercise.reps == WorkoutPlanGenerator.customFallbackReps)
        #expect(exercise.restSeconds == WorkoutPlanGenerator.customFallbackRestSeconds)
        #expect(exercise.cue == WorkoutPlanGenerator.customFallbackCue)
        #expect(exercise.machineId.hasPrefix("custom_"))
    }

    @Test
    func customMachineIsExcludedForNonMatchingBodyPart() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "A")
        _ = try repo.addCustomMachine(to: gym, displayName: "自作レッグ", bodyParts: [.legs])

        let plan = WorkoutPlanGenerator.generate(
            bodyPart: .chest,
            gym: gym,
            availableEquipment: repo.availableEquipment(for: gym, availableOnly: true)
        )
        #expect(!plan.exercises.contains { $0.exerciseName == "自作レッグ" })
    }

    @Test
    func unavailableCustomMachineNeverEntersSingleWorkoutPlan() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "A")
        let machine = try repo.addCustomMachine(to: gym, displayName: "封鎖中マシン", bodyParts: [.chest])
        repo.setCustomMachineAvailability(machine, isAvailable: false)

        // Even if an unavailable item is handed to the generator directly,
        // it filters it out rather than trusting the caller.
        let plan = WorkoutPlanGenerator.generate(
            bodyPart: .chest,
            gym: gym,
            availableEquipment: repo.availableEquipment(for: gym, availableOnly: false)
        )
        #expect(!plan.exercises.contains { $0.exerciseName == "封鎖中マシン" })
    }

    @Test
    func standardTemplateBehaviorIsUnchangedAlongsideCustom() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "A")
        repo.setMachines(["bench_press"], for: gym)
        _ = try repo.addCustomMachine(to: gym, displayName: "自作チェスト", bodyParts: [.chest])

        let plan = WorkoutPlanGenerator.generate(
            bodyPart: .chest,
            gym: gym,
            availableEquipment: repo.availableEquipment(for: gym, availableOnly: true)
        )
        // The catalog template still leads with its authored values.
        let bench = try #require(plan.exercises.first { $0.machineId == "bench_press" })
        #expect(bench.exerciseName == "ベンチプレス")
        #expect(bench.sets == 4)
        #expect(bench.reps == 8)
        #expect(bench.restSeconds == 120)
        // Standard suggestions come first; custom supplements them.
        #expect(plan.exercises.first?.machineId == "bench_press")
        #expect(plan.exercises.contains { $0.exerciseName == "自作チェスト" })
    }

    @Test
    func oneCustomMachineCannotFillThePlanTwice() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "A")
        let machine = try repo.addCustomMachine(to: gym, displayName: "自作", bodyParts: [.chest])
        let duplicated = [AvailableEquipment(custom: machine), AvailableEquipment(custom: machine)]

        let plan = WorkoutPlanGenerator.generate(bodyPart: .chest, gym: gym, availableEquipment: duplicated)
        #expect(plan.exercises.filter { $0.exerciseName == "自作" }.count == 1)
    }

    // MARK: - Weekly planner

    @Test
    func customMachineCanAppearInWeeklyCandidate() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "A")
        let machine = try repo.addCustomMachine(to: gym, displayName: "自作チェスト", bodyParts: [.chest])

        let plan = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(daysPerWeek: 1, targetBodyParts: [.chest]),
            equipment: [AvailableEquipment(custom: machine)]
        )
        let names = plan.sessions.flatMap { $0.exercises.map(\.exerciseName) }
        #expect(names.contains("自作チェスト"))
        // No authored defaults, so the conservative fallbacks apply.
        let candidate = try #require(plan.sessions.first?.exercises.first)
        #expect(candidate.resolvedSets == RoutineStepCandidate.fallbackSets)
        #expect(candidate.resolvedRepsTarget == RoutineStepCandidate.fallbackRepsTarget)
        #expect(candidate.resolvedRestSeconds == RoutineStepCandidate.fallbackRestSeconds)
    }

    @Test
    func unavailableCustomMachineIsExcludedFromWeeklyCandidate() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "A")
        let machine = try repo.addCustomMachine(to: gym, displayName: "封鎖中", bodyParts: [.chest])
        repo.setCustomMachineAvailability(machine, isAvailable: false)

        let plan = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(daysPerWeek: 1, targetBodyParts: [.chest]),
            equipment: [AvailableEquipment(custom: machine)]
        )
        let names = plan.sessions.flatMap { $0.exercises.map(\.exerciseName) }
        #expect(!names.contains("封鎖中"))
    }

    @Test
    func beginnerOnlyRequestExcludesCustomMachinesConservatively() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "A")
        let custom = try repo.addCustomMachine(to: gym, displayName: "素性不明マシン", bodyParts: [.chest])
        let beginnerStandard = MachineCatalogEntry(
            id: "bf_chest", displayName: "BFチェスト", bodyParts: [.chest], beginnerFriendly: true
        )

        let plan = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(
                daysPerWeek: 1, targetBodyParts: [.chest], beginnerFriendlyOnly: true
            ),
            equipment: [AvailableEquipment(entry: beginnerStandard), AvailableEquipment(custom: custom)]
        )
        let names = plan.sessions.flatMap { $0.exercises.map(\.exerciseName) }
        // Unknown beginner-friendliness is treated as "not proven safe".
        #expect(!names.contains("素性不明マシン"))
        #expect(names.contains("BFチェスト"))
    }

    @Test
    func customMachineWithUnknownPersistedMetadataDoesNotCrash() throws {
        let (repo, context) = try Self.makeRepo()
        let gym = repo.createGym(name: "A")
        // Raw values that no longer map to a known case.
        let broken = CustomMachine(
            gymId: gym.id,
            displayName: "壊れたメタデータ",
            bodyParts: ["chest", "not_a_real_part"],
            equipmentType: "not_a_real_type"
        )
        context.insert(broken)

        let equipment = AvailableEquipment(custom: broken)
        #expect(equipment.bodyParts == [.chest])
        #expect(equipment.equipmentType == nil)

        let plan = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(daysPerWeek: 1, targetBodyParts: [.chest]),
            equipment: [equipment]
        )
        #expect(plan.sessions.flatMap { $0.exercises.map(\.exerciseName) }.contains("壊れたメタデータ"))
    }

    @Test
    func weeklyUICallPathUsesOnlyActiveGymAvailableEquipment() throws {
        let (repo, _) = try Self.makeRepo()
        let active = repo.createGym(name: "Active")
        repo.setMachines(["leg_press"], for: active)
        let activeCustom = try repo.addCustomMachine(to: active, displayName: "自作レッグ", bodyParts: [.legs])
        let unavailable = try repo.addCustomMachine(to: active, displayName: "封鎖中レッグ", bodyParts: [.legs])
        repo.setCustomMachineAvailability(unavailable, isAvailable: false)

        let other = repo.createGym(name: "Other", makeActive: false)
        repo.setMachines(["hack_squat"], for: other)
        _ = try repo.addCustomMachine(to: other, displayName: "別ジムレッグ", bodyParts: [.legs])

        let equipment = try Self.requireReadyEquipment(from: repo)
        let suppliedIds = Set(equipment.map(\.id))
        #expect(suppliedIds == ["leg_press", activeCustom.referenceId])

        let plan = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(daysPerWeek: 1, targetBodyParts: [.legs]),
            equipment: equipment
        )
        let machineIds = Set(plan.sessions.flatMap { $0.exercises.map(\.machineId) })
        #expect(machineIds.isSubset(of: suppliedIds))
        #expect(machineIds.contains("leg_press") || machineIds.contains(activeCustom.referenceId))
        #expect(!machineIds.contains("hack_squat"))
        #expect(!machineIds.contains("leg_extension"))
        #expect(!machineIds.contains("leg_curl"))
        #expect(!machineIds.contains(unavailable.referenceId))
        #expect(!plan.sessions.flatMap { $0.exercises.map(\.exerciseName) }.contains("別ジムレッグ"))
    }

    @Test
    func weeklyEquipmentProviderAllowsSelectedStandardOnly() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "A")
        repo.setMachines(["leg_press"], for: gym)

        let equipment = try Self.requireReadyEquipment(from: repo)
        #expect(equipment.map(\.id) == ["leg_press"])
    }

    @Test
    func weeklyEquipmentProviderAllowsCustomOnly() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "A")
        let custom = try repo.addCustomMachine(to: gym, displayName: "自作チェスト", bodyParts: [.chest])

        let equipment = try Self.requireReadyEquipment(from: repo)
        #expect(equipment.map(\.id) == [custom.referenceId])

        let plan = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(daysPerWeek: 1, targetBodyParts: [.chest]),
            equipment: equipment
        )
        #expect(plan.sessions.flatMap { $0.exercises.map(\.exerciseName) }.contains("自作チェスト"))
    }

    @Test
    func weeklyEquipmentProviderAllowsMixedStandardAndCustom() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "A")
        repo.setMachines(["chest_press"], for: gym)
        let custom = try repo.addCustomMachine(to: gym, displayName: "自作チェスト", bodyParts: [.chest])

        let equipment = try Self.requireReadyEquipment(from: repo)
        #expect(Set(equipment.map(\.id)) == ["chest_press", custom.referenceId])
    }

    @Test
    func weeklyEquipmentProviderDoesNotFallbackForActiveGymWithZeroAvailableEquipment() throws {
        let (repo, _) = try Self.makeRepo()
        _ = repo.createGym(name: "A")

        #expect(WeeklyPlanEquipmentProvider.resolve(repository: repo) == .activeGymHasNoAvailableEquipment)
    }

    @Test
    func weeklyEquipmentProviderExcludesUnavailableCustomMachines() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "A")
        let custom = try repo.addCustomMachine(to: gym, displayName: "封鎖中", bodyParts: [.chest])
        repo.setCustomMachineAvailability(custom, isAvailable: false)

        #expect(WeeklyPlanEquipmentProvider.resolve(repository: repo) == .activeGymHasNoAvailableEquipment)
    }

    @Test
    func weeklyEquipmentProviderRequiresActiveGymWhenGymsExistButNoneIsActive() throws {
        let (repo, _) = try Self.makeRepo()
        _ = repo.createGym(name: "A", makeActive: false)
        _ = repo.createGym(name: "B", makeActive: false)

        #expect(WeeklyPlanEquipmentProvider.resolve(repository: repo) == .needsActiveGym)
    }

    @Test
    func weeklyEquipmentProviderKeepsGenericCatalogFallbackWhenNoGymIsConfigured() throws {
        let (repo, _) = try Self.makeRepo()

        let equipment = try Self.requireReadyEquipment(from: repo)
        #expect(equipment.count == MachineCatalog.all.count)
        #expect(Set(equipment.map(\.id)) == Set(MachineCatalog.all.map(\.id)))
    }

    @Test
    func beginnerOnlyWeeklyRequestExcludesCustomMachinesWithUnknownBeginnerSuitability() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "A")
        repo.setMachines(["leg_press"], for: gym)
        let custom = try repo.addCustomMachine(to: gym, displayName: "素性不明レッグ", bodyParts: [.legs])

        let equipment = try Self.requireReadyEquipment(from: repo)
        let plan = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(
                daysPerWeek: 1,
                targetBodyParts: [.legs],
                beginnerFriendlyOnly: true
            ),
            equipment: equipment
        )

        let machineIds = Set(plan.sessions.flatMap { $0.exercises.map(\.machineId) })
        #expect(machineIds.contains("leg_press"))
        #expect(!machineIds.contains(custom.referenceId))
    }

    private static func requireReadyEquipment(from repo: GymRepository) throws -> [AvailableEquipment] {
        switch WeeklyPlanEquipmentProvider.resolve(repository: repo) {
        case .ready(let equipment):
            return equipment
        case .activeGymHasNoAvailableEquipment:
            Issue.record("Expected ready equipment, got zero-equipment state")
        case .needsActiveGym:
            Issue.record("Expected ready equipment, got active-gym-required state")
        }
        return []
    }

    // MARK: - Preview / explicit-save boundary

    @Test
    func generatingAPlanPersistsNothing() throws {
        let (repo, context) = try Self.makeRepo()
        let gym = repo.createGym(name: "A")
        _ = try repo.addCustomMachine(to: gym, displayName: "自作", bodyParts: [.chest])

        let plan = WorkoutPlanGenerator.generate(
            bodyPart: .chest,
            gym: gym,
            availableEquipment: repo.availableEquipment(for: gym, availableOnly: true)
        )
        #expect(!plan.isEmpty)
        // Preview only: cancelling here leaves no routine behind.
        #expect(try context.fetch(FetchDescriptor<Routine>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Step>()).isEmpty)
    }

    @Test
    func explicitSaveCreatesRoutineAndStepsWithTitleSnapshot() throws {
        let (repo, context) = try Self.makeRepo()
        let gym = repo.createGym(name: "A")
        _ = try repo.addCustomMachine(to: gym, displayName: "自作チェスト", bodyParts: [.chest])

        let plan = WorkoutPlanGenerator.generate(
            bodyPart: .chest,
            gym: gym,
            availableEquipment: repo.availableEquipment(for: gym, availableOnly: true)
        )
        let output = RoutineFactory.makeRoutine(from: plan)
        context.insert(output.routine)
        for step in output.steps { context.insert(step) }

        let steps = try context.fetch(FetchDescriptor<Step>())
        #expect(try context.fetch(FetchDescriptor<Routine>()).count == 1)
        #expect(steps.contains { $0.title == "自作チェスト" })
        // Steps snapshot the title; they hold no custom-machine reference.
        #expect(steps.allSatisfy { $0.routineId == output.routine.id })
    }

    @Test
    func renamingCustomMachineDoesNotRewriteSavedStepTitle() throws {
        let (repo, context) = try Self.makeRepo()
        let gym = repo.createGym(name: "A")
        let machine = try repo.addCustomMachine(to: gym, displayName: "保存時の名前", bodyParts: [.chest])

        let plan = WorkoutPlanGenerator.generate(
            bodyPart: .chest,
            gym: gym,
            availableEquipment: repo.availableEquipment(for: gym, availableOnly: true)
        )
        let output = RoutineFactory.makeRoutine(from: plan)
        context.insert(output.routine)
        for step in output.steps { context.insert(step) }

        try repo.updateCustomMachine(machine, displayName: "あとで変えた名前")

        let steps = try context.fetch(FetchDescriptor<Step>())
        #expect(steps.contains { $0.title == "保存時の名前" })
        #expect(!steps.contains { $0.title == "あとで変えた名前" })
    }

    @Test
    func savedRoutineStaysRunnableAfterCustomMachineIsDeleted() throws {
        let (repo, context) = try Self.makeRepo()
        let gym = repo.createGym(name: "A")
        let machine = try repo.addCustomMachine(to: gym, displayName: "自作", bodyParts: [.chest])

        let plan = WorkoutPlanGenerator.generate(
            bodyPart: .chest,
            gym: gym,
            availableEquipment: repo.availableEquipment(for: gym, availableOnly: true)
        )
        let output = RoutineFactory.makeRoutine(from: plan)
        context.insert(output.routine)
        for step in output.steps { context.insert(step) }
        let routineId = output.routine.id

        repo.deleteCustomMachine(machine)

        // What Runner needs: the routine and its ordered steps, resolved
        // purely by foreign key + title snapshot.
        let steps = try context.fetch(
            FetchDescriptor<Step>(predicate: #Predicate { $0.routineId == routineId })
        ).sorted { $0.order < $1.order }
        #expect(!steps.isEmpty)
        #expect(steps.allSatisfy { !$0.title.isEmpty })
        #expect(steps.allSatisfy { $0.sets > 0 && $0.repsTarget > 0 })
    }
}
