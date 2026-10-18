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
//  Order, and why — every step is a persistent state a crash can stop at, and
//  each one is safe to resume from:
//
//    0. `ServerAccountStore` saves a `PendingAccountLocalCleanup` row the
//       moment it sees 200/202, and deletes the session only once that save
//       has returned. A SwiftData save is a real commit boundary, which a
//       UserDefaults write is not (it reaches disk asynchronously). Nothing is
//       recorded before the answer, so an unknown outcome never deletes
//       anything; a failed save keeps the session and claims nothing;
//    1. every fetch and delete of the account's rows in a dedicated context,
//       then one save — a failure discards that context and commits nothing,
//       without touching unsaved work in the app's main context. The marker
//       is *not* part of this save;
//    2. only after that save, the main context's own copies of the account's
//       rows are deleted there too, unsaved inserts included — otherwise its
//       next save would write them back. Nobody else's unsaved work is
//       touched;
//    3. the marker is stamped with this process's id and saved — and kept —
//       *before* any UserDefaults change, so a failed stamp leaves them as
//       they were;
//    4. then the UserDefaults slots — they cannot join the SwiftData
//       transaction, so they follow a commit rather than precede a possible
//       failure. They reach disk asynchronously, and no API says when, so the
//       process that removed them can never know they are gone. Only a later
//       process, which read them back from disk, can — so the marker stays;
//    5. a later launch (`resumePending()` with a different process id) checks
//       the account's rows and slots are all gone, and only then deletes the
//       marker. Anything still there — a slot whose removal never reached
//       disk — and it runs the cleanup again instead, stamped with its own id.
//       Steps 1–4 are idempotent, so a crash anywhere repeats them safely.
//
//  The marker is also a quarantine: while it exists, `WorkoutDataScopeResolver`
//  never resolves to the account, online or offline, whether or not the
//  cleanup succeeded. Privacy does not wait on the physical deletion.
//

import Foundation
import SwiftData

/// A server-confirmed account deletion whose local cleanup has not finished.
///
/// The durable receipt of "the server deleted this account": saved before the
/// session is removed, deleted only after everything the account owned is
/// gone. Added in schema V9.
@Model
final class PendingAccountLocalCleanup {
    @Attribute(.unique) var accountID: UUID
    var confirmedAt: Date
    /// The process that last ran the cleanup, nil until one has. That process
    /// cannot acknowledge its own UserDefaults removals; see steps 3–5 above.
    var lastCleanupProcessID: UUID?

    init(accountID: UUID, confirmedAt: Date = Date(), lastCleanupProcessID: UUID? = nil) {
        self.accountID = accountID
        self.confirmedAt = confirmedAt
        self.lastCleanupProcessID = lastCleanupProcessID
    }
}

struct AccountLocalDataCleanup {

    /// The saves the cleanup makes, so tests can fail exactly one of them.
    enum Commit {
        case recordMarker, deleteRows, stampMarker, removeMarker
    }

    /// New in every process, the same for its whole life.
    static let currentProcessID = UUID()

    private let container: ModelContainer
    private let defaults: UserDefaults
    /// The app's main context, whose unsaved copies of the account's rows must
    /// not outlive the cleanup. Nil at launch, before anything is unsaved.
    private let mainContext: ModelContext?
    /// Production saves; tests substitute a commit that inspects or fails.
    private let commit: (ModelContext, Commit) throws -> Void
    /// Tests stand in for separate launches by passing different ids.
    private let processID: UUID

    init(
        container: ModelContainer,
        defaults: UserDefaults = .standard,
        mainContext: ModelContext? = nil,
        processID: UUID = AccountLocalDataCleanup.currentProcessID,
        commit: @escaping (ModelContext, Commit) throws -> Void = { context, _ in try context.save() }
    ) {
        self.container = container
        self.defaults = defaults
        self.mainContext = mainContext
        self.processID = processID
        self.commit = commit
    }

    /// Removes everything `accountID` owns on this device. The marker stays,
    /// stamped with this process, for a later launch to acknowledge. Throws if
    /// any save fails.
    func run(for accountID: UUID) throws {
        try recordMarker(for: accountID)
        let deleted = try deleteRows(of: accountID)
        if let mainContext {
            discardMainContextRows(of: accountID, persisted: deleted, in: mainContext)
        }
        // Stamped before the UserDefaults change, so a failed stamp throws
        // with them untouched: no process ever holds a removal it has not
        // stamped as its own.
        try stampMarker(for: accountID)
        deleteDefaults(of: accountID)
    }

    /// Durably records a server-confirmed deletion of `serverUserID`. Called by
    /// `ServerAccountStore` before it deletes the session; when this throws,
    /// nothing is recorded and the session must stay. An id that is not a UUID
    /// owns no local rows and is not recorded.
    func recordConfirmedDeletion(of serverUserID: String) throws {
        guard let id = UUID(uuidString: serverUserID) else { return }
        try recordMarker(for: id)
    }

    /// Acknowledges cleanups an earlier process finished and finds complete
    /// on disk, and runs every other one again. A failure stays pending for
    /// the next launch.
    func resumePending() {
        let markers: [(accountID: UUID, lastCleanupProcessID: UUID?)]
        do {
            markers = try ModelContext(container).fetch(FetchDescriptor<PendingAccountLocalCleanup>())
                .map { ($0.accountID, $0.lastCleanupProcessID) }
        } catch {
            print("AccountLocalDataCleanup: could not read pending cleanups: \(error)")
            return
        }
        for marker in markers {
            let id = marker.accountID
            do {
                if let last = marker.lastCleanupProcessID, last != processID, try isClean(id) {
                    try removeMarker(for: id)
                } else {
                    try run(for: id)
                }
            } catch {
                // No account id in the log: it identifies a deleted user.
                print("AccountLocalDataCleanup: a pending cleanup failed and stays pending: \(error)")
            }
        }
    }

    /// Whether `accountID` has a marker: nil when the store cannot be read,
    /// which callers must treat as pending.
    func isPending(_ accountID: UUID) -> Bool? {
        do {
            return try ModelContext(container).fetchCount(FetchDescriptor<PendingAccountLocalCleanup>(
                predicate: #Predicate { $0.accountID == accountID }
            )) > 0
        } catch {
            return nil
        }
    }

    /// Accounts with a saved marker, read from the store itself.
    func pendingIDs() throws -> [UUID] {
        try ModelContext(container).fetch(FetchDescriptor<PendingAccountLocalCleanup>())
            .map(\.accountID)
            .sorted { $0.uuidString < $1.uuidString }
    }

    // MARK: - Marker

    /// Upsert: a marker already there (a retry) is left as it is.
    private func recordMarker(for accountID: UUID) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let existing = try context.fetch(FetchDescriptor<PendingAccountLocalCleanup>(
            predicate: #Predicate { $0.accountID == accountID }
        ))
        guard existing.isEmpty else { return }
        context.insert(PendingAccountLocalCleanup(accountID: accountID))
        try commit(context, .recordMarker)
    }

    private func stampMarker(for accountID: UUID) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let markers = try context.fetch(FetchDescriptor<PendingAccountLocalCleanup>(
            predicate: #Predicate { $0.accountID == accountID }
        ))
        for marker in markers where marker.accountID == accountID {
            marker.lastCleanupProcessID = processID
        }
        try commit(context, .stampMarker)
    }

    private func removeMarker(for accountID: UUID) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let markers = try context.fetch(FetchDescriptor<PendingAccountLocalCleanup>(
            predicate: #Predicate { $0.accountID == accountID }
        ))
        for marker in markers where marker.accountID == accountID {
            context.delete(marker)
        }
        try commit(context, .removeMarker)
    }

    // MARK: - SwiftData

    /// Whether nothing the account owned is left, read from the store and
    /// from UserDefaults as this process loaded them.
    private func isClean(_ accountID: UUID) throws -> Bool {
        let context = ModelContext(container)
        guard try ownedRows(of: accountID, in: context).isEmpty else { return false }

        let scope = WorkoutDataScope.account(accountID)
        let keys = [
            HealthScopedDefaults.key(FavoriteMealTemplateStore.defaultStorageKey, for: scope),
            HealthScopedDefaults.key(HealthTargetStore.defaultStorageKey, for: scope),
            RunnerPersistence.key(for: scope),
        ]
        for case let key? in keys where defaults.object(forKey: key) != nil {
            return false
        }
        let answers = GuestAdoptionConsent.Answers(
            workoutRaw: defaults.string(forKey: GuestAdoptionConsent.workoutAnsweredKey) ?? "",
            healthRaw: defaults.string(forKey: GuestAdoptionConsent.healthAnsweredKey) ?? ""
        )
        if answers.answeredWorkout(accountID) || answers.answeredHealth(accountID) { return false }
        let last = defaults.string(forKey: WorkoutDataScopeResolver.lastConfirmedAccountKey)
        return last.flatMap(UUID.init(uuidString:)) != accountID
    }

    /// Returns the ids of the rows the save removed.
    private func deleteRows(of accountID: UUID) throws -> Set<PersistentIdentifier> {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let owned = try ownedRows(of: accountID, in: context)
        for row in owned { context.delete(row) }

        try commit(context, .deleteRows)
        return Set(owned.map(\.persistentModelID))
    }

    private func ownedRows(of accountID: UUID, in context: ModelContext) throws -> [any PersistentModel] {
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
        return rows.filter { Self.owner(of: $0) == accountID }
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
}
