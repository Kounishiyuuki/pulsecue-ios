//
//  GymRepository.swift
//  Pulse Cue
//
//  Thin facade around `ModelContext` for the gym + machine flow.
//  ViewModels go through this so they don't hand-roll FetchDescriptors
//  or worry about the "single active gym" invariant. All operations
//  are synchronous; the repository is `@MainActor` to match how
//  ModelContext is used elsewhere in the app.
//

import Foundation
import SwiftData

@MainActor
struct GymRepository {
    let modelContext: ModelContext

    // MARK: - Gyms

    func allGyms() -> [Gym] {
        // Sort by `updatedAt` only; SwiftData's SortDescriptor does
        // not support sorting plain (non-NSObject) `Bool` keypaths,
        // so the active gym is surfaced via `activeGym()` instead.
        let descriptor = FetchDescriptor<Gym>(
            sortBy: [SortDescriptor(\Gym.updatedAt, order: .reverse)]
        )
        let all = (try? modelContext.fetch(descriptor)) ?? []
        // Stable: active first, then by recency.
        return all.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive && !rhs.isActive }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func activeGym() -> Gym? {
        var descriptor = FetchDescriptor<Gym>(
            predicate: #Predicate { $0.isActive == true },
            sortBy: [SortDescriptor(\Gym.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    @discardableResult
    func createGym(name: String, officialUrl: String? = nil, makeActive: Bool = true) -> Gym {
        let gym = Gym(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            officialUrl: officialUrl,
            isActive: false
        )
        modelContext.insert(gym)
        if makeActive {
            setActive(gym)
        }
        return gym
    }

    func updateGym(_ gym: Gym, name: String? = nil, officialUrl: String?? = nil) {
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            gym.name = trimmed.isEmpty ? gym.name : trimmed
        }
        if let officialUrl {
            gym.officialUrl = Gym.normalize(officialUrl)
        }
        gym.updatedAt = Date()
    }

    /// Marks the given gym active and demotes all others to inactive.
    /// Enforces the at-most-one-active invariant in one place so
    /// ViewModels don't have to know about it.
    func setActive(_ gym: Gym) {
        let others = (try? modelContext.fetch(
            FetchDescriptor<Gym>(predicate: #Predicate { $0.isActive == true })
        )) ?? []
        for other in others where other.id != gym.id {
            other.isActive = false
            other.updatedAt = Date()
        }
        gym.isActive = true
        gym.updatedAt = Date()
    }

    func deleteGym(_ gym: Gym) {
        let gymId = gym.id
        let machines = (try? modelContext.fetch(
            FetchDescriptor<GymMachine>(predicate: #Predicate { $0.gymId == gymId })
        )) ?? []
        for machine in machines {
            modelContext.delete(machine)
        }
        modelContext.delete(gym)
    }

    // MARK: - Machines

    func machines(for gym: Gym) -> [GymMachine] {
        let gymId = gym.id
        let descriptor = FetchDescriptor<GymMachine>(
            predicate: #Predicate { $0.gymId == gymId },
            sortBy: [SortDescriptor(\GymMachine.addedAt)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Replaces the gym's machine list with the given set of catalog
    /// ids. Existing rows for ids that remain selected are kept (so
    /// `addedAt` is preserved); rows for ids that were unselected are
    /// deleted; new ids get fresh rows. Display names are snapshotted
    /// from the catalog at save time.
    func setMachines(_ machineIds: Set<String>, for gym: Gym) {
        let existing = machines(for: gym)
        let existingIds = Set(existing.map(\.machineId))

        for machine in existing where !machineIds.contains(machine.machineId) {
            modelContext.delete(machine)
        }

        for machineId in machineIds.subtracting(existingIds) {
            let displayName = MachineCatalog.entry(for: machineId)?.displayName ?? machineId
            let row = GymMachine(
                gymId: gym.id,
                machineId: machineId,
                displayName: displayName
            )
            modelContext.insert(row)
        }

        gym.updatedAt = Date()
    }
}
