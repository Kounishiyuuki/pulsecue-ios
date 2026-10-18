//
//  AccountLocalDataCleanup.swift
//  Pulse Cue
//
//  After the server confirms a PulseCue account is deleted, removes that
//  account's records from this device — and nobody else's.
//
//  Not server deletion, and not logout: `ServerAccountStore` decides whether
//  the account is gone; this only runs once it is (`200` or `202`). Signing
//  out leaves an account's data on the device for when it signs back in.
//
//  What belongs to the account is decided by owner identity alone:
//
//    * SwiftData rows whose `ownerAccountID` / `accountID` is the account's
//      server UUID — workouts and their set results, day logs (weight, sleep,
//      intake, exercise), meals, the profile, and the sync outbox, tombstones
//      and cursor.
//    * UserDefaults slots namespaced by that UUID — favorite meals, manual
//      targets, the runner's resume point — and the account's entries in the
//      adoption "already asked" lists and the last-confirmed account id.
//
//  Guest rows (`nil` owner) cannot be named here: the API takes a `UUID`, not
//  a scope. Routines, gyms, machines and device settings carry no owner, so
//  nothing proves they were the account's; they stay.
//
//  Order, and why:
//
//    1. the account is recorded as pending cleanup, so a crash or a failed
//       save is retried at the next launch instead of forgotten;
//    2. every fetch and delete in a dedicated context, then exactly one save —
//       a failure discards that context and commits nothing, without
//       touching unsaved work in the app's main context;
//    3. only after that save, the UserDefaults slots — they cannot join the
//       SwiftData transaction, so they follow a commit rather than precede a
//       possible failure;
//    4. the pending record is removed last.
//

import Foundation
import SwiftData

struct AccountLocalDataCleanup {

    /// Server UUIDs whose local cleanup has not finished.
    static let pendingKey = "account.pendingLocalCleanupIDs"

    private let container: ModelContainer
    private let defaults: UserDefaults
    /// Production saves; tests substitute a commit that inspects or fails.
    private let commit: (ModelContext) throws -> Void

    init(
        container: ModelContainer,
        defaults: UserDefaults = .standard,
        commit: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.container = container
        self.defaults = defaults
        self.commit = commit
    }

    /// Removes everything `accountID` owns on this device, or — if the save
    /// fails — nothing, leaving it pending for `resumePending()`.
    func run(for accountID: UUID) throws {
        markPending(accountID)
        try deleteRows(of: accountID)
        deleteDefaults(of: accountID)
        unmarkPending(accountID)
    }

    /// Retries cleanups a previous launch did not finish. A failure stays
    /// pending for the next launch.
    func resumePending() {
        for id in pendingIDs() {
            do {
                try run(for: id)
            } catch {
                print("AccountLocalDataCleanup: cleanup for \(id) failed and stays pending: \(error)")
            }
        }
    }

    func pendingIDs() -> [UUID] {
        Self.ids(defaults.string(forKey: Self.pendingKey) ?? "").sorted { $0.uuidString < $1.uuidString }
    }

    // MARK: - SwiftData

    private func deleteRows(of accountID: UUID) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let owner: UUID? = accountID

        // The predicate narrows the fetch; the filter after it is the rule.
        // A row is deleted only when its owner is this exact UUID.
        let sessions = try context.fetch(FetchDescriptor<Session>(predicate: #Predicate { $0.ownerAccountID == owner }))
        let results = try context.fetch(FetchDescriptor<StepResult>(predicate: #Predicate { $0.ownerAccountID == owner }))
        let logs = try context.fetch(FetchDescriptor<DayLog>(predicate: #Predicate { $0.ownerAccountID == owner }))
        let meals = try context.fetch(FetchDescriptor<MealEntry>(predicate: #Predicate { $0.ownerAccountID == owner }))
        let profiles = try context.fetch(FetchDescriptor<UserProfile>(predicate: #Predicate { $0.ownerAccountID == owner }))
        let outbox = try context.fetch(FetchDescriptor<SyncOutboxItem>(predicate: #Predicate { $0.accountID == accountID }))
        let tombstones = try context.fetch(FetchDescriptor<SyncTombstone>(predicate: #Predicate { $0.accountID == accountID }))
        let cursors = try context.fetch(FetchDescriptor<SyncCursor>(predicate: #Predicate { $0.accountID == accountID }))

        sessions.filter { $0.ownerAccountID == accountID }.forEach(context.delete)
        results.filter { $0.ownerAccountID == accountID }.forEach(context.delete)
        logs.filter { $0.ownerAccountID == accountID }.forEach(context.delete)
        meals.filter { $0.ownerAccountID == accountID }.forEach(context.delete)
        profiles.filter { $0.ownerAccountID == accountID }.forEach(context.delete)
        outbox.filter { $0.accountID == accountID }.forEach(context.delete)
        tombstones.filter { $0.accountID == accountID }.forEach(context.delete)
        cursors.filter { $0.accountID == accountID }.forEach(context.delete)

        try commit(context)
    }

    // MARK: - UserDefaults

    private func deleteDefaults(of accountID: UUID) {
        let scope = WorkoutDataScope.account(accountID)
        let keys = [
            HealthScopedDefaults.key(FavoriteMealTemplateStore.defaultStorageKey, for: scope),
            HealthScopedDefaults.key(HealthTargetStore.defaultStorageKey, for: scope),
            RunnerPersistence.key(for: scope),
        ]
        for case let key? in keys {
            defaults.removeObject(forKey: key)
        }

        let answers = GuestAdoptionConsent.Answers(
            workoutRaw: defaults.string(forKey: GuestAdoptionConsent.workoutAnsweredKey) ?? "",
            healthRaw: defaults.string(forKey: GuestAdoptionConsent.healthAnsweredKey) ?? ""
        ).removing(accountID)
        defaults.set(answers.workoutRaw, forKey: GuestAdoptionConsent.workoutAnsweredKey)
        defaults.set(answers.healthRaw, forKey: GuestAdoptionConsent.healthAnsweredKey)

        let lastKey = WorkoutDataScopeResolver.lastConfirmedAccountKey
        if defaults.string(forKey: lastKey).flatMap(UUID.init(uuidString:)) == accountID {
            defaults.removeObject(forKey: lastKey)
        }
    }

    // MARK: - Pending record

    private func markPending(_ id: UUID) {
        var ids = Self.ids(defaults.string(forKey: Self.pendingKey) ?? "")
        ids.insert(id)
        defaults.set(Self.raw(ids), forKey: Self.pendingKey)
    }

    private func unmarkPending(_ id: UUID) {
        var ids = Self.ids(defaults.string(forKey: Self.pendingKey) ?? "")
        ids.remove(id)
        defaults.set(Self.raw(ids), forKey: Self.pendingKey)
    }

    private static func ids(_ raw: String) -> Set<UUID> {
        Set(raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private static func raw(_ ids: Set<UUID>) -> String {
        ids.map(\.uuidString).sorted().joined(separator: ",")
    }
}
