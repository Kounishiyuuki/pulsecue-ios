//
//  CustomMachineRepositoryTests.swift
//  Pulse CueTests
//
//  CRUD + validation coverage for the custom-machine repository APIs.
//  These use an in-memory store (fast, isolated); the on-disk migration
//  guarantees live in `CustomMachineMigrationTests`.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct CustomMachineRepositoryTests {

    private static func makeRepo() throws -> (GymRepository, ModelContext) {
        // Use the production (latest) versioned schema (in-memory) rather than
        // an ad-hoc `Schema([...])`: building a raw subset schema that includes
        // `CustomMachine` tripped a CoreData "model still editable" crash,
        // while the versioned schema (the same one the app ships) is stable.
        let schema = Schema(versionedSchema: PulseCueSchemaV5.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        return (GymRepository(modelContext: context), context)
    }

    // MARK: - Create + fetch

    @Test
    func createAndFetchReturnsTheRecord() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "Gym A")
        let created = try repo.addCustomMachine(
            to: gym, displayName: "自作マシン", bodyParts: [.chest]
        )
        let fetched = repo.customMachines(for: gym)
        #expect(fetched.count == 1)
        #expect(fetched.first?.id == created.id)
        #expect(fetched.first?.displayName == "自作マシン")
        #expect(fetched.first?.bodyParts == ["chest"])
    }

    @Test
    func createTrimsDisplayName() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "Gym A")
        let created = try repo.addCustomMachine(
            to: gym, displayName: "  スミスマシン  ", bodyParts: [.legs]
        )
        #expect(created.displayName == "スミスマシン")
    }

    @Test
    func createRejectsWhitespaceOnlyDisplayName() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "Gym A")
        #expect(throws: CustomMachineError.emptyDisplayName) {
            _ = try repo.addCustomMachine(to: gym, displayName: "   ", bodyParts: [.chest])
        }
    }

    @Test
    func createRejectsEmptyBodyParts() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "Gym A")
        #expect(throws: CustomMachineError.noBodyParts) {
            _ = try repo.addCustomMachine(to: gym, displayName: "マシン", bodyParts: [])
        }
    }

    @Test
    func createRejectsUnknownGym() throws {
        let (repo, _) = try Self.makeRepo()
        // A gym that was never inserted into the context.
        let orphanGym = Gym(name: "存在しない")
        #expect(throws: CustomMachineError.gymNotFound) {
            _ = try repo.addCustomMachine(to: orphanGym, displayName: "マシン", bodyParts: [.chest])
        }
    }

    @Test
    func bodyPartsAreDedupedAndDeterministicallyOrdered() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "Gym A")
        // Input order is scrambled and contains a duplicate.
        let created = try repo.addCustomMachine(
            to: gym, displayName: "マシン", bodyParts: [.back, .chest, .chest, .legs]
        )
        // Normalized to BodyPart declaration order (chest, back, legs).
        #expect(created.bodyParts == ["chest", "back", "legs"])
    }

    @Test
    func notesAreTrimmedAndEmptyBecomesNil() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "Gym A")
        let withNote = try repo.addCustomMachine(
            to: gym, displayName: "A", bodyParts: [.chest], notes: "  メモ  "
        )
        #expect(withNote.notes == "メモ")
        let blankNote = try repo.addCustomMachine(
            to: gym, displayName: "B", bodyParts: [.chest], notes: "   "
        )
        #expect(blankNote.notes == nil)
    }

    @Test
    func equipmentTypeRoundTrips() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "Gym A")
        let created = try repo.addCustomMachine(
            to: gym, displayName: "A", bodyParts: [.chest], equipmentType: .cable
        )
        #expect(created.equipmentType == "cable")
        #expect(created.resolvedEquipmentType == .cable)
    }

    // MARK: - Update

    @Test
    func updatePreservesIdentityAndBumpsUpdatedAt() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "Gym A")
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let t1 = Date(timeIntervalSince1970: 2_000_000)
        let created = try repo.addCustomMachine(
            to: gym, displayName: "旧名", bodyParts: [.chest], now: t0
        )
        let originalId = created.id

        try repo.updateCustomMachine(created, displayName: "新名", bodyParts: [.back], now: t1)
        #expect(created.id == originalId)
        #expect(created.displayName == "新名")
        #expect(created.bodyParts == ["back"])
        #expect(created.createdAt == t0)
        #expect(created.updatedAt == t1)
    }

    @Test
    func updateRejectsInvalidFieldsWithoutMutating() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "Gym A")
        let created = try repo.addCustomMachine(
            to: gym, displayName: "元名", bodyParts: [.chest]
        )
        #expect(throws: CustomMachineError.emptyDisplayName) {
            try repo.updateCustomMachine(created, displayName: "  ")
        }
        // The rejected update left the record untouched.
        #expect(created.displayName == "元名")
        #expect(created.bodyParts == ["chest"])
    }

    @Test
    func updateThrowsNotFoundForDeletedRecord() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "Gym A")
        let created = try repo.addCustomMachine(
            to: gym, displayName: "消す", bodyParts: [.chest]
        )
        repo.deleteCustomMachine(created)
        #expect(throws: CustomMachineError.notFound) {
            try repo.updateCustomMachine(created, displayName: "無理")
        }
    }

    @Test
    func updateCanClearOptionalFields() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "Gym A")
        let created = try repo.addCustomMachine(
            to: gym, displayName: "A", bodyParts: [.chest],
            equipmentType: .machine, notes: "メモ"
        )
        try repo.updateCustomMachine(created, equipmentType: .some(nil), notes: .some(nil))
        #expect(created.equipmentType == nil)
        #expect(created.notes == nil)
    }

    // MARK: - Delete

    @Test
    func deleteRemovesOnlyTheSpecifiedCustomRecord() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "Gym A")
        let a = try repo.addCustomMachine(to: gym, displayName: "A", bodyParts: [.chest])
        _ = try repo.addCustomMachine(to: gym, displayName: "B", bodyParts: [.back])

        repo.deleteCustomMachine(a)
        let remaining = repo.customMachines(for: gym)
        #expect(remaining.count == 1)
        #expect(remaining.first?.displayName == "B")
    }

    @Test
    func deletingCustomDoesNotRemoveStandardMachinesOrHistory() throws {
        let (repo, context) = try Self.makeRepo()
        let gym = repo.createGym(name: "Gym A")
        repo.setMachines(["bench_press"], for: gym)

        // A routine/session/result graph unrelated to any machine identity.
        let routine = Routine(name: "R")
        context.insert(routine)
        let session = Session(routineId: routine.id, dayDate: Date())
        context.insert(session)
        context.insert(StepResult(sessionId: session.id, stepId: UUID(), setIndex: 0, done: true))

        let custom = try repo.addCustomMachine(to: gym, displayName: "C", bodyParts: [.chest])
        repo.deleteCustomMachine(custom)

        let routines = try context.fetch(FetchDescriptor<Routine>())
        let sessions = try context.fetch(FetchDescriptor<Session>())
        let results = try context.fetch(FetchDescriptor<StepResult>())
        #expect(repo.machines(for: gym).map(\.machineId) == ["bench_press"])
        #expect(routines.count == 1)
        #expect(sessions.count == 1)
        #expect(results.count == 1)
    }

    // MARK: - Duplicates / isolation

    @Test
    func duplicateDisplayNamesRemainSeparateRecords() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "Gym A")
        let a = try repo.addCustomMachine(to: gym, displayName: "同じ名前", bodyParts: [.chest])
        let b = try repo.addCustomMachine(to: gym, displayName: "同じ名前", bodyParts: [.chest])
        #expect(a.id != b.id)
        #expect(repo.customMachines(for: gym).count == 2)
    }

    @Test
    func sameNameAsStandardMachineIsAllowed() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "Gym A")
        // "ラットプルダウン" is a bundled standard machine's display name.
        let created = try repo.addCustomMachine(
            to: gym, displayName: "ラットプルダウン", bodyParts: [.back]
        )
        #expect(created.displayName == "ラットプルダウン")
        #expect(repo.customMachines(for: gym).count == 1)
    }

    @Test
    func deletingAndRecreatingProducesANewIdentity() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "Gym A")
        let first = try repo.addCustomMachine(to: gym, displayName: "同じ名前", bodyParts: [.chest])
        let firstId = first.id
        let firstRef = first.referenceId

        repo.deleteCustomMachine(first)
        let recreated = try repo.addCustomMachine(to: gym, displayName: "同じ名前", bodyParts: [.chest])

        // Recreating is a new record, not a resurrection of the old one.
        #expect(recreated.id != firstId)
        #expect(recreated.referenceId != firstRef)
        #expect(repo.customMachines(for: gym).count == 1)
    }

    @Test
    func identicalNamesAreAllowedInDifferentGyms() throws {
        let (repo, _) = try Self.makeRepo()
        let gymA = repo.createGym(name: "A")
        let gymB = repo.createGym(name: "B")
        let a = try repo.addCustomMachine(to: gymA, displayName: "共通名マシン", bodyParts: [.chest])
        let b = try repo.addCustomMachine(to: gymB, displayName: "共通名マシン", bodyParts: [.chest])

        #expect(a.id != b.id)
        #expect(repo.customMachines(for: gymA).map(\.displayName) == ["共通名マシン"])
        #expect(repo.customMachines(for: gymB).map(\.displayName) == ["共通名マシン"])
    }

    @Test
    func customMachinesAreScopedPerGym() throws {
        let (repo, _) = try Self.makeRepo()
        let gymA = repo.createGym(name: "A")
        let gymB = repo.createGym(name: "B")
        _ = try repo.addCustomMachine(to: gymA, displayName: "Aのマシン", bodyParts: [.chest])
        _ = try repo.addCustomMachine(to: gymB, displayName: "Bのマシン", bodyParts: [.back])

        #expect(repo.customMachines(for: gymA).map(\.displayName) == ["Aのマシン"])
        #expect(repo.customMachines(for: gymB).map(\.displayName) == ["Bのマシン"])
    }

    @Test
    func fetchIsOrderedByCreatedAt() throws {
        let (repo, _) = try Self.makeRepo()
        let gym = repo.createGym(name: "A")
        _ = try repo.addCustomMachine(
            to: gym, displayName: "古い", bodyParts: [.chest],
            now: Date(timeIntervalSince1970: 100)
        )
        _ = try repo.addCustomMachine(
            to: gym, displayName: "新しい", bodyParts: [.back],
            now: Date(timeIntervalSince1970: 200)
        )
        #expect(repo.customMachines(for: gym).map(\.displayName) == ["古い", "新しい"])
    }

    // MARK: - Gym delete cascade

    @Test
    func deleteGymRemovesStandardAndCustomMachines() throws {
        let (repo, context) = try Self.makeRepo()
        let gym = repo.createGym(name: "Gym A")
        repo.setMachines(["bench_press"], for: gym)
        _ = try repo.addCustomMachine(to: gym, displayName: "自作", bodyParts: [.chest])

        repo.deleteGym(gym)

        let machines = try context.fetch(FetchDescriptor<GymMachine>())
        let customs = try context.fetch(FetchDescriptor<CustomMachine>())
        let gyms = try context.fetch(FetchDescriptor<Gym>())
        #expect(machines.isEmpty)
        #expect(customs.isEmpty)
        #expect(gyms.isEmpty)
    }

    @Test
    func deleteGymDoesNotAffectAnotherGymsCustomMachines() throws {
        let (repo, _) = try Self.makeRepo()
        let gymA = repo.createGym(name: "A")
        let gymB = repo.createGym(name: "B")
        _ = try repo.addCustomMachine(to: gymA, displayName: "Aのマシン", bodyParts: [.chest])
        let bMachine = try repo.addCustomMachine(to: gymB, displayName: "Bのマシン", bodyParts: [.back])

        repo.deleteGym(gymA)

        let remaining = repo.customMachines(for: gymB)
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == bMachine.id)
    }
}
