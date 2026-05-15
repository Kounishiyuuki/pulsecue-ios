//
//  GymRepositoryTests.swift
//  Pulse CueTests
//
//  Covers the at-most-one-active-gym invariant, machine dedupe by
//  catalog id, and basic delete-cascade behavior (which we implement
//  manually since the rest of the project uses foreign-key joins
//  rather than SwiftData @Relationships).
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct GymRepositoryTests {

    private static func makeRepo() throws -> (GymRepository, ModelContext) {
        let schema = Schema([Routine.self, Step.self, Gym.self, GymMachine.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        return (GymRepository(modelContext: context), context)
    }

    @Test
    func createGymMakesItActiveByDefault() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "Gym A")
        #expect(gym.isActive)
        #expect(repo.activeGym()?.id == gym.id)
    }

    @Test
    func onlyOneGymCanBeActiveAtATime() throws {
        let (repo, _) = try Self.makeRepo()
        let gymA = repo.createGym(name: "Gym A")
        let gymB = repo.createGym(name: "Gym B")
        #expect(gymA.isActive == false)
        #expect(gymB.isActive == true)

        repo.setActive(gymA)
        #expect(repo.activeGym()?.id == gymA.id)
        #expect(gymB.isActive == false)
    }

    @Test
    func setMachinesAddsNewAndDropsRemoved() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "Gym A")

        repo.setMachines(["bench_press", "leg_press"], for: gym)
        var machines = repo.machines(for: gym)
        #expect(Set(machines.map(\.machineId)) == ["bench_press", "leg_press"])

        repo.setMachines(["bench_press", "lat_pulldown"], for: gym)
        machines = repo.machines(for: gym)
        #expect(Set(machines.map(\.machineId)) == ["bench_press", "lat_pulldown"])
    }

    @Test
    func setMachinesDoesNotDuplicateExistingId() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "Gym A")
        repo.setMachines(["bench_press"], for: gym)
        let firstAddedAt = repo.machines(for: gym).first?.addedAt

        // Re-saving with the same id should keep the existing row,
        // not create a duplicate or reset addedAt.
        repo.setMachines(["bench_press"], for: gym)
        let machines = repo.machines(for: gym)
        #expect(machines.count == 1)
        #expect(machines.first?.addedAt == firstAddedAt)
    }

    @Test
    func setMachinesDenormalizesDisplayNameFromCatalog() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "Gym A")
        repo.setMachines(["lat_pulldown"], for: gym)
        let machines = repo.machines(for: gym)
        #expect(machines.first?.displayName == "ラットプルダウン")
    }

    @Test
    func deleteGymRemovesAttachedMachines() throws {
        let (repo, context) = try Self.makeRepo()
        let gym = repo.createGym(name: "Gym A")
        repo.setMachines(["bench_press", "leg_press"], for: gym)

        repo.deleteGym(gym)

        let remainingMachines = try context.fetch(FetchDescriptor<GymMachine>())
        let remainingGyms = try context.fetch(FetchDescriptor<Gym>())
        #expect(remainingMachines.isEmpty)
        #expect(remainingGyms.isEmpty)
    }
}
