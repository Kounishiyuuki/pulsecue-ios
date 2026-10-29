//
//  GymEquipmentSetupStore.swift
//  Pulse Cue
//
//  Remembers which gyms were registered on this device but have not had
//  their equipment confirmed yet. Two per-gym flags:
//
//    - awaiting initial setup: the machine picker may stage the common
//      machine suggestion (`MachineCatalog.commonGymMachineIds`). Cleared
//      the first time the user saves that gym's selection.
//    - review prompt pending: My Gym shows the one-time
//      「利用できるマシンを確認しましょう」prompt. Cleared when the user
//      answers it (確認する / あとで) or saves the selection.
//
//  Only `GymRegistrationViewModel` marks a gym, so gyms that existed
//  before this store shipped are never flagged and never get suggestions.
//  UserDefaults rather than a `Gym` attribute keeps this additive — no
//  schema version bump — and the flags are disposable UI state, not
//  equipment data. `GymMachine` stays the only source of truth for what
//  the plan generator may use.
//

import Foundation

struct GymEquipmentSetupStore {

    static let awaitingSetupKey = "myGym.equipmentSetup.awaitingGymIds.v1"
    static let promptPendingKey = "myGym.equipmentSetup.promptPendingGymIds.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Called once, right after a gym is created through registration.
    func markNewGym(_ gymId: UUID) {
        insert(gymId, forKey: Self.awaitingSetupKey)
        insert(gymId, forKey: Self.promptPendingKey)
    }

    func isAwaitingInitialSetup(_ gymId: UUID) -> Bool {
        ids(forKey: Self.awaitingSetupKey).contains(gymId.uuidString)
    }

    func isReviewPromptPending(_ gymId: UUID) -> Bool {
        ids(forKey: Self.promptPendingKey).contains(gymId.uuidString)
    }

    func dismissReviewPrompt(_ gymId: UUID) {
        remove(gymId, forKey: Self.promptPendingKey)
    }

    /// The user saved this gym's equipment: suggestions and the prompt
    /// never come back for it.
    func markConfirmed(_ gymId: UUID) {
        remove(gymId, forKey: Self.awaitingSetupKey)
        remove(gymId, forKey: Self.promptPendingKey)
    }

    // MARK: - Storage

    private func ids(forKey key: String) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    private func insert(_ gymId: UUID, forKey key: String) {
        var set = ids(forKey: key)
        set.insert(gymId.uuidString)
        defaults.set(Array(set).sorted(), forKey: key)
    }

    private func remove(_ gymId: UUID, forKey key: String) {
        var set = ids(forKey: key)
        guard set.remove(gymId.uuidString) != nil else { return }
        defaults.set(Array(set).sorted(), forKey: key)
    }
}
