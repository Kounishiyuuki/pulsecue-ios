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
//    0. `ServerAccountStore` records the account as pending
//       (`recordConfirmedDeletion`) the moment it sees 200/202, *before* it
//       deletes the session. Recording after would leave a window where the
//       account is gone, the session is gone, and nothing on disk says whose
//       data to remove. Nothing is recorded before the answer: an unknown
//       outcome must never delete anything;
//    1. `run` records it again (idempotent), so a crash or a failed save is
//       retried at the next launch instead of forgotten;
//    2. every fetch and delete in a dedicated context, then exactly one save —
//       a failure discards that context and commits nothing, without
//       touching unsaved work in the app's main context;
//    3. only after that save, the main context's own copies of the account's
//       rows are deleted there too, unsaved inserts included — otherwise its
//       next save would write them back. Nobody else's unsaved work is
//       touched;
//    4. then the UserDefaults slots — they cannot join the SwiftData
//       transaction, so they follow a commit rather than precede a possible
//       failure;
//    5. the pending record is removed last.
//

import Foundation
import SwiftData

struct AccountLocalDataCleanup {

    /// Server UUIDs whose local cleanup has not finished.
    static let pendingKey = "account.pendingLocalCleanupIDs"

    private let container: ModelContainer
    private let defaults: UserDefaults
    /// The app's main context, whose unsaved copies of the account's rows must
    /// not outlive the cleanup. Nil at launch, before anything is unsaved.
    private let mainContext: ModelContext?
    /// Production saves; tests substitute a commit that inspects or fails.
    private let commit: (ModelContext) throws -> Void

    init(
        container: ModelContainer,
        defaults: UserDefaults = .standard,
        mainContext: ModelContext? = nil,
        commit: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.container = container
        self.defaults = defaults
        self.mainContext = mainContext
        self.commit = commit
    }

    /// Removes everything `accountID` owns on this device, or — if the save
    /// fails — nothing, leaving it pending for `resumePending()`.
    func run(for accountID: UUID) throws {
        Self.markPending(accountID, in: defaults)
        let deleted = try deleteRows(of: accountID)
        if let mainContext {
            discardMainContextRows(of: accountID, persisted: deleted, in: mainContext)
        }
        deleteDefaults(of: accountID)
        unmarkPending(accountID)
    }

    /// Records a server-confirmed deletion of `serverUserID` as pending
    /// cleanup. Called by `ServerAccountStore` before it deletes the session,
    /// so every crash after the server's answer leaves a retryable record. An
    /// id that is not a UUID owns no local rows and is not recorded.
    static func recordConfirmedDeletion(of serverUserID: String, in defaults: UserDefaults = .standard) {
        guard let id = UUID(uuidString: serverUserID) else { return }
        markPending(id, in: defaults)
    }

    /// Retries cleanups a previous launch did not finish. A failure stays
    /// pending for the next launch.
    func resumePending() {
        for id in pendingIDs() {
            do {
                try run(for: id)
            } catch {
                // No account id in the log: it identifies a deleted user.
                print("AccountLocalDataCleanup: a pending cleanup failed and stays pending: \(error)")
            }
        }
    }

    func pendingIDs() -> [UUID] {
        Self.ids(defaults.string(forKey: Self.pendingKey) ?? "").sorted { $0.uuidString < $1.uuidString }
    }

    // MARK: - SwiftData

    /// Returns the ids of the rows the save removed.
    private func deleteRows(of accountID: UUID) throws -> Set<PersistentIdentifier> {
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

        let rows: [any PersistentModel] = sessions + results + logs + meals + profiles + outbox + tombstones + cursors
        let owned = rows.filter { Self.owner(of: $0) == accountID }
        for row in owned { context.delete(row) }

        try commit(context)
        return Set(owned.map(\.persistentModelID))
    }

    /// Deletes, in the main context, its unsaved inserts owned by the account
    /// and its changed copies of rows the cleanup just removed. Both would
    /// otherwise be written back by the main context's next save.
    ///
    /// A changed row is matched by the id the cleanup deleted, not by its
    /// owner in memory: a row whose unsaved change *makes* it the account's
    /// is still someone else's on disk, and deleting it here would delete
    /// their row. Nothing else in the main context is touched or saved.
    private func discardMainContextRows(
        of accountID: UUID,
        persisted deleted: Set<PersistentIdentifier>,
        in main: ModelContext
    ) {
        let inserted = main.insertedModelsArray.filter { Self.owner(of: $0) == accountID }
        let changed = main.changedModelsArray.filter { deleted.contains($0.persistentModelID) }
        for row in inserted + changed { main.delete(row) }
    }

    /// The account a row belongs to, for the types the cleanup removes.
    private static func owner(of model: any PersistentModel) -> UUID? {
        switch model {
        case let row as Session: row.ownerAccountID
        case let row as StepResult: row.ownerAccountID
        case let row as DayLog: row.ownerAccountID
        case let row as MealEntry: row.ownerAccountID
        case let row as UserProfile: row.ownerAccountID
        case let row as SyncOutboxItem: row.accountID
        case let row as SyncTombstone: row.accountID
        case let row as SyncCursor: row.accountID
        default: nil
        }
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

    private static func markPending(_ id: UUID, in defaults: UserDefaults) {
        var ids = ids(defaults.string(forKey: pendingKey) ?? "")
        ids.insert(id)
        defaults.set(raw(ids), forKey: pendingKey)
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
