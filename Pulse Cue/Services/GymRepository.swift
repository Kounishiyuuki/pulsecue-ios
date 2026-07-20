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
        // Custom machines join the gym by the same logical foreign key, so
        // they cascade here too (no SwiftData @Relationship to do it for us).
        let customs = (try? modelContext.fetch(
            FetchDescriptor<CustomMachine>(predicate: #Predicate { $0.gymId == gymId })
        )) ?? []
        for custom in customs {
            modelContext.delete(custom)
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

    // MARK: - Custom machines

    /// User-created equipment for one gym, kept separate from the bundled
    /// standard-catalog selections in `GymMachine`.
    func customMachines(for gym: Gym) -> [CustomMachine] {
        let gymId = gym.id
        // Only `createdAt` is pushed into the FetchDescriptor; the UUID
        // tie-break is applied in memory because SwiftData cannot sort on
        // a plain (non-NSObject) `UUID` keypath (same reason `allGyms()`
        // sorts in memory).
        let descriptor = FetchDescriptor<CustomMachine>(
            predicate: #Predicate { $0.gymId == gymId },
            sortBy: [SortDescriptor(\CustomMachine.createdAt)]
        )
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        return rows.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Creates a custom machine for the gym. Validates that the gym exists,
    /// the display name is non-empty after trimming, and at least one valid
    /// body part is supplied. Duplicate display names are preserved as
    /// separate records; nothing is merged with standard or custom machines.
    @discardableResult
    func addCustomMachine(
        to gym: Gym,
        displayName: String,
        bodyParts: [BodyPart],
        equipmentType: EquipmentType? = nil,
        notes: String? = nil,
        now: Date = Date()
    ) throws -> CustomMachine {
        let gymId = gym.id
        let gymExists = ((try? modelContext.fetch(
            FetchDescriptor<Gym>(predicate: #Predicate { $0.id == gymId })
        )) ?? []).isEmpty == false
        guard gymExists else { throw CustomMachineError.gymNotFound }

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw CustomMachineError.emptyDisplayName }

        let parts = CustomMachine.normalizedBodyPartValues(from: bodyParts)
        guard !parts.isEmpty else { throw CustomMachineError.noBodyParts }

        let machine = CustomMachine(
            gymId: gymId,
            displayName: trimmedName,
            bodyParts: parts,
            equipmentType: equipmentType?.rawValue,
            notes: CustomMachine.normalizedNotes(notes),
            createdAt: now,
            updatedAt: now
        )
        modelContext.insert(machine)
        return machine
    }

    /// Updates a custom machine in place. Only the provided fields change;
    /// `id` and `gymId` are preserved (there is no move-between-gyms API).
    /// All fields are validated before any mutation so a rejected update
    /// leaves the record untouched. `updatedAt` is bumped on success.
    func updateCustomMachine(
        _ machine: CustomMachine,
        displayName: String? = nil,
        bodyParts: [BodyPart]? = nil,
        equipmentType: EquipmentType?? = nil,
        notes: String?? = nil,
        now: Date = Date()
    ) throws {
        let targetId = machine.id
        guard let stored = ((try? modelContext.fetch(
            FetchDescriptor<CustomMachine>(predicate: #Predicate { $0.id == targetId })
        )) ?? []).first else {
            throw CustomMachineError.notFound
        }

        // Validate everything first, then apply, so a throw cannot leave a
        // half-updated row.
        var newName: String?
        if let displayName {
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw CustomMachineError.emptyDisplayName }
            newName = trimmed
        }
        var newParts: [String]?
        if let bodyParts {
            let parts = CustomMachine.normalizedBodyPartValues(from: bodyParts)
            guard !parts.isEmpty else { throw CustomMachineError.noBodyParts }
            newParts = parts
        }

        if let newName { stored.displayName = newName }
        if let newParts { stored.bodyParts = newParts }
        if let equipmentType { stored.equipmentType = equipmentType?.rawValue }
        if let notes { stored.notes = CustomMachine.normalizedNotes(notes) }
        stored.updatedAt = now
    }

    /// Hard-deletes a single custom machine. Standard `GymMachine` rows and
    /// all routine/session/history data are untouched (they carry no
    /// reference to this record).
    func deleteCustomMachine(_ machine: CustomMachine) {
        modelContext.delete(machine)
    }
}

/// Errors surfaced by the custom-machine repository APIs.
enum CustomMachineError: Error, Equatable {
    case gymNotFound
    case emptyDisplayName
    case noBodyParts
    case notFound
}
