//
//  AccountScopedSync.swift
//  Pulse Cue
//
//  The local persistence boundary that has to exist before any workout data
//  is sent anywhere. No network call lives here, and none is meant to: this
//  file only answers "whose data is this, how far has this account pulled,
//  and what does it still owe the server".
//
//  The design is shaped by one invariant, which is the reason the PR exists:
//
//  **Nothing uploads "whatever history is on this phone" to "whoever is
//  signed in".** A device is not an account. Someone can hand a phone over,
//  sign in with a second account, or reinstall; a scheme that reads the
//  current session and claims every local row for it silently moves one
//  person's training history into another person's account, and does it at
//  the moment that is hardest to notice. So ownership is stored per row,
//  written once, and the only transition ever performed is
//  `nil → an account` — see `adoptGuestWorkoutData`. There is no code path
//  that rewrites `A` to `B`, which is why §"No silent reassignment" below is
//  a property of the API surface rather than a rule to remember.
//
//  **Owner is the server's account UUID.** `GET /v1/me` returns `user.id`;
//  that is the id the server's `workout_sessions.user_id` and
//  `step_results.user_id` columns hold. An Apple or Google subject is a
//  provider's name for a person, not the account, and two providers linked to
//  one account would produce two different "owners" for the same data. The
//  app never uses them here.
//
//  **Ownership is about sync, not visibility.** Adding an owner column does
//  not hide anybody's history from anybody. Whether the app should stop
//  showing another account's sessions after a switch is a product question
//  with a real answer needed from the product side, and inventing one here
//  would change behaviour people already rely on. Every view keeps fetching
//  what it fetched before.
//
//  Mapping to the server contract (`server/migrations/0005_workout_sync.sql`):
//
//    * client-generated UUIDs are the ids — so the outbox stores the entity's
//      own `id`, not a surrogate,
//    * `(user_id, id)` is the primary key — so every read here is scoped by
//      account and there is no "all candidates" query,
//    * a tombstone is terminal — so `SyncOutboxItem` refuses to turn a
//      recorded delete back into an upsert,
//    * `change_seq` is the pull cursor — so the cursor is per account and
//      monotonic.
//

import Foundation
import SwiftData

// MARK: - Cursor

/// How far one account has pulled from the server.
///
/// Per account, never global. A single shared cursor would let account B skip
/// everything written before it signed in — the server's `change_seq` is
/// per-user, so a number learned as A means nothing as B.
@Model
final class SyncCursor {
    /// The server account UUID this cursor belongs to. Unique: one cursor per
    /// account, so "advance" can never quietly create a second row that a
    /// later read picks between.
    @Attribute(.unique) var accountID: UUID
    /// The highest `change_seq` this account has successfully consumed.
    var lastPulledSequence: Int
    var updatedAt: Date

    init(accountID: UUID, lastPulledSequence: Int = 0, updatedAt: Date = Date()) {
        self.accountID = accountID
        self.lastPulledSequence = lastPulledSequence
        self.updatedAt = updatedAt
    }
}

// MARK: - Outbox

/// Which local entity a pending mutation is about.
enum SyncEntityType: String, Codable, CaseIterable {
    case session
    case stepResult
}

/// What the server should be told about an entity.
///
/// Two cases, matching what `POST /v1/sync/workouts` accepts: a record's
/// current state, or `deleted: true`. There is no "create" distinct from
/// "update" because the upload is an upsert keyed by the client's own id.
enum SyncMutationKind: String, Codable, CaseIterable {
    case upsert
    case delete
}

/// One entity's pending mutation for one account.
///
/// At most one row per (account, entity): the upload sends the record's
/// current state, so a second edit before the first is sent has nothing new
/// to say — it replaces, rather than queues behind, what was already pending.
/// That keeps a retry loop from growing the table without bound, and it is
/// enforced by `identity` being unique rather than by the caller being careful.
@Model
final class SyncOutboxItem {
    /// `accountID|entityType|entityID`. Deterministic, so recording the same
    /// logical mutation twice addresses the same row — including after a
    /// crash, which is the case a counter or a fresh UUID would get wrong.
    @Attribute(.unique) var identity: String
    /// Always present. An outbox entry with no account could only be resolved
    /// by asking who is signed in at send time, which is the reassignment this
    /// file exists to prevent. Guest mutations are simply not queued; they
    /// enter the outbox at adoption, owned from the start.
    var accountID: UUID
    var entityType: SyncEntityType
    /// The entity's own client-generated UUID — the id the server stores.
    var entityID: UUID
    var mutation: SyncMutationKind
    var createdAt: Date
    var updatedAt: Date

    init(
        identity: String,
        accountID: UUID,
        entityType: SyncEntityType,
        entityID: UUID,
        mutation: SyncMutationKind,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.identity = identity
        self.accountID = accountID
        self.entityType = entityType
        self.entityID = entityID
        self.mutation = mutation
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func identity(
        accountID: UUID,
        entityType: SyncEntityType,
        entityID: UUID
    ) -> String {
        "\(accountID.uuidString)|\(entityType.rawValue)|\(entityID.uuidString)"
    }
}

// MARK: - Tombstone

/// An entity this account has deleted, as far as the server is concerned.
///
/// The outbox alone cannot carry this. An outbox entry is *pending* work: once
/// the server acknowledges the delete the entry is cleared, and with it the
/// only local trace that the id is finished — after which an upsert for the
/// same id looks like ordinary new work, gets queued, and is answered with
/// `409 record_deleted` on a network the user is not watching. Worse, on
/// another device the resurrection would win its own `change_seq`.
///
/// So the terminal state outlives the queue. One row per (account, entity),
/// written when a delete is acknowledged and never removed while the account
/// exists. A record that genuinely needs to come back gets a new id, which is
/// unambiguous in a way that reviving one never is.
@Model
final class SyncTombstone {
    /// `accountID|entityType|entityID` — the same shape `SyncOutboxItem` uses,
    /// so "is this finished" is a lookup rather than a scan.
    @Attribute(.unique) var identity: String
    var accountID: UUID
    var entityType: SyncEntityType
    var entityID: UUID
    /// When the server confirmed the deletion.
    var deletedAt: Date

    init(
        identity: String,
        accountID: UUID,
        entityType: SyncEntityType,
        entityID: UUID,
        deletedAt: Date = Date()
    ) {
        self.identity = identity
        self.accountID = accountID
        self.entityType = entityType
        self.entityID = entityID
        self.deletedAt = deletedAt
    }
}

// MARK: - Errors

enum AccountScopedSyncError: Error, Equatable {
    /// An upsert was recorded for an entity this account has already deleted.
    ///
    /// The server treats a tombstone as terminal and answers `409
    /// record_deleted`; letting the local queue hold "delete, then undelete"
    /// would only defer that to the network and lose the delete on the way.
    /// A record that must come back gets a new id.
    case tombstoneIsTerminal(SyncEntityType, UUID)

    /// The row does not belong to the account the caller named.
    ///
    /// The caller's `accountID` is a claim, not evidence. Trusting it is how
    /// one account's training ends up in another account's upload, so the row
    /// is asked directly and a mismatch stops the write.
    case ownerMismatch(SyncEntityType, UUID)

    /// A step result whose parent session belongs to a different account, or
    /// to nobody.
    ///
    /// The server makes this unrepresentable with a composite foreign key
    /// (`(user_id, session_id)`); refusing it here means a batch is not
    /// assembled that the server would reject in full.
    case parentOwnerMismatch(UUID)

    /// A step result pointing at a session that is not in this store.
    case unknownParentSession(UUID)
}

// MARK: - Store

/// The one place ownership, cursors and the outbox are read and written.
///
/// A plain struct over an explicitly passed `ModelContext`, matching the rest
/// of the app's repositories. Nothing here runs per view render: adoption is a
/// one-shot operation and the candidate/outbox reads belong to a sync pass,
/// not to a body.
struct AccountScopedSyncStore {

    init() {}

    // MARK: Ownership

    /// Sessions this account may upload. Never "everything local".
    func syncCandidateSessions(
        for accountID: UUID,
        in context: ModelContext
    ) throws -> [Session] {
        try context.fetch(
            FetchDescriptor<Session>(
                predicate: #Predicate { $0.ownerAccountID == accountID }
            )
        )
    }

    /// Step results this account may upload.
    ///
    /// Owning the result is not enough. The server keys a step result on its
    /// user *and* its session (`FOREIGN KEY (user_id, session_id)`), so a
    /// result whose session belongs to someone else — or is missing — is not a
    /// row this account can send; including it would assemble a batch the
    /// server rejects in full, taking the valid rows down with it.
    ///
    /// Fail closed: a result that cannot be matched to an owned session is
    /// left out rather than sent and sorted out later. The same pairing is
    /// checked again at the send boundary, because a candidate list is a
    /// snapshot and a write is not.
    func syncCandidateStepResults(
        for accountID: UUID,
        in context: ModelContext
    ) throws -> [StepResult] {
        let ownedSessionIDs = Set(
            try syncCandidateSessions(for: accountID, in: context).map(\.id)
        )
        return try context.fetch(
            FetchDescriptor<StepResult>(
                predicate: #Predicate { $0.ownerAccountID == accountID }
            )
        ).filter { ownedSessionIDs.contains($0.sessionId) }
    }

    /// Rows no account has claimed yet.
    func guestSessions(in context: ModelContext) throws -> [Session] {
        try context.fetch(
            FetchDescriptor<Session>(
                predicate: #Predicate { $0.ownerAccountID == nil }
            )
        )
    }

    // MARK: Guest adoption

    /// What one adoption actually moved. Zeroes mean there was nothing to
    /// adopt, which is the normal result of running it a second time.
    struct GuestAdoptionSummary: Equatable {
        var adoptedSessions: Int
        var adoptedStepResults: Int

        static let nothing = GuestAdoptionSummary(adoptedSessions: 0, adoptedStepResults: 0)
    }

    /// Hand this device's *unowned* workout data to `accountID`.
    ///
    /// The predicate is `ownerAccountID == nil` and nothing else. A row owned
    /// by another account is not filtered out after being fetched — it is
    /// never fetched, so there is no version of this function that "also"
    /// takes it. Running it again is a no-op, and it is the only transition in
    /// the file: guest → account, once.
    ///
    /// Step results follow their session rather than being adopted on their
    /// own, because the server refuses a step result pointing at a session
    /// that is not this user's (`(user_id, session_id)` foreign key). An
    /// orphan guest result — one whose session belongs to somebody else, or is
    /// gone — stays unowned rather than being uploaded into a session this
    /// account does not have.
    ///
    /// **All or nothing.** Adoption runs in two phases, and the split is the
    /// whole point of the shape below.
    ///
    /// Everything that can refuse the operation is decided first, while
    /// nothing has been written. Only then are owners assigned. Interleaving
    /// the two — check a row, write it, check the next — is what made a
    /// half-finished adoption possible: the throw came after earlier rows had
    /// already been reassigned, and those objects stay dirty in the
    /// `ModelContext` whether or not this function saved. The next unrelated
    /// `save()` anywhere in the app would then commit a partial adoption that
    /// nobody asked for and no error mentioned.
    ///
    /// The write phase can still fail at `save()` — a disk is a disk — so it
    /// also undoes precisely what it did: the owners it set, and the queue
    /// entries it inserted. Undoing by hand rather than `context.rollback()`
    /// because rollback discards *every* unsaved change in the context,
    /// including work this operation never touched.
    @discardableResult
    func adoptGuestWorkoutData(
        for accountID: UUID,
        in context: ModelContext,
        now: Date = Date()
    ) throws -> GuestAdoptionSummary {
        // ---- Phase 1: decide. No writes. ----

        let sessions = try guestSessions(in: context)

        // Sessions this account will own once the write phase runs: the ones
        // adopted now, plus any adopted in an earlier run, so a guest result
        // left behind previously is still picked up.
        var ownedSessionIDs = Set(
            try syncCandidateSessions(for: accountID, in: context).map(\.id)
        )
        ownedSessionIDs.formUnion(sessions.map(\.id))

        let results = try context.fetch(
            FetchDescriptor<StepResult>(
                predicate: #Predicate<StepResult> { $0.ownerAccountID == nil }
            )
        ).filter { ownedSessionIDs.contains($0.sessionId) }

        // Anything this account has already deleted for good stops the whole
        // adoption here, before a single owner has been touched.
        for session in sessions
        where try isTombstoned(.session, session.id, for: accountID, in: context) {
            throw AccountScopedSyncError.tombstoneIsTerminal(.session, session.id)
        }
        for result in results
        where try isTombstoned(.stepResult, result.id, for: accountID, in: context) {
            throw AccountScopedSyncError.tombstoneIsTerminal(.stepResult, result.id)
        }

        // ---- Phase 2: write, and undo exactly this on failure. ----

        var queued: [SyncOutboxItem] = []
        do {
            for session in sessions {
                session.ownerAccountID = accountID
                try recordSessionMutation(.upsert, session, for: accountID, in: context, now: now)
                queued.append(contentsOf: try queuedItem(.session, session.id, accountID, context))
            }
            for result in results {
                result.ownerAccountID = accountID
                try recordStepResultMutation(.upsert, result, for: accountID, in: context, now: now)
                queued.append(contentsOf: try queuedItem(.stepResult, result.id, accountID, context))
            }
            try context.save()
        } catch {
            for session in sessions { session.ownerAccountID = nil }
            for result in results { result.ownerAccountID = nil }
            for item in queued { context.delete(item) }
            throw error
        }

        return GuestAdoptionSummary(
            adoptedSessions: sessions.count,
            adoptedStepResults: results.count
        )
    }

    /// The queue entry just written for this entity, so the write phase can
    /// take it back. An array rather than an optional purely so the caller
    /// reads as one line.
    private func queuedItem(
        _ entityType: SyncEntityType,
        _ entityID: UUID,
        _ accountID: UUID,
        _ context: ModelContext
    ) throws -> [SyncOutboxItem] {
        let identity = SyncOutboxItem.identity(
            accountID: accountID,
            entityType: entityType,
            entityID: entityID
        )
        return try context.fetch(
            FetchDescriptor<SyncOutboxItem>(
                predicate: #Predicate { $0.identity == identity }
            )
        )
    }

    // MARK: Cursor

    /// This account's cursor, or nil if it has never pulled.
    ///
    /// Nil is meaningful: a new account starts from the beginning of its own
    /// history, not from wherever the previous account had got to.
    func cursor(for accountID: UUID, in context: ModelContext) throws -> SyncCursor? {
        try context.fetch(
            FetchDescriptor<SyncCursor>(
                predicate: #Predicate { $0.accountID == accountID }
            )
        ).first
    }

    /// Move this account's cursor forward to `sequence`.
    ///
    /// Monotonic. A lower value is dropped rather than written: sequences only
    /// ever come from the server, so a smaller one is a stale or reordered
    /// response, and storing it would re-pull rows already applied — or, worse,
    /// be followed by an advance that skips the gap.
    @discardableResult
    func advanceCursor(
        for accountID: UUID,
        to sequence: Int,
        in context: ModelContext,
        now: Date = Date()
    ) throws -> SyncCursor {
        if let existing = try cursor(for: accountID, in: context) {
            if sequence > existing.lastPulledSequence {
                existing.lastPulledSequence = sequence
                existing.updatedAt = now
            }
            try context.save()
            return existing
        }
        let created = SyncCursor(
            accountID: accountID,
            lastPulledSequence: sequence,
            updatedAt: now
        )
        context.insert(created)
        try context.save()
        return created
    }

    // MARK: Outbox

    /// This account's pending mutations, oldest first.
    func outboxItems(for accountID: UUID, in context: ModelContext) throws -> [SyncOutboxItem] {
        try context.fetch(
            FetchDescriptor<SyncOutboxItem>(
                predicate: #Predicate { $0.accountID == accountID },
                sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.identity)]
            )
        )
    }

    /// Queue a session mutation, after checking the session agrees.
    ///
    /// `accountID` is what the caller believes; `session.ownerAccountID` is
    /// what the store knows. Only the second one decides, because the first is
    /// exactly what goes wrong when a screen is rendered under one account and
    /// a write lands under another.
    func recordSessionMutation(
        _ mutation: SyncMutationKind,
        _ session: Session,
        for accountID: UUID,
        in context: ModelContext,
        now: Date = Date()
    ) throws {
        guard session.ownerAccountID == accountID else {
            throw AccountScopedSyncError.ownerMismatch(.session, session.id)
        }
        try record(mutation, .session, session.id, for: accountID, in: context, now: now)
    }

    /// Queue a step result mutation, after checking both it and its session
    /// agree.
    ///
    /// The parent is re-read rather than trusted from the caller: a result
    /// carrying the right owner under a session carrying a different one is
    /// precisely the pair the server's composite foreign key refuses, and it
    /// is not visible from the result alone.
    func recordStepResultMutation(
        _ mutation: SyncMutationKind,
        _ result: StepResult,
        for accountID: UUID,
        in context: ModelContext,
        now: Date = Date()
    ) throws {
        guard result.ownerAccountID == accountID else {
            throw AccountScopedSyncError.ownerMismatch(.stepResult, result.id)
        }
        let sessionID = result.sessionId
        let parent = try context.fetch(
            FetchDescriptor<Session>(predicate: #Predicate { $0.id == sessionID })
        ).first
        guard let parent else {
            throw AccountScopedSyncError.unknownParentSession(result.id)
        }
        guard parent.ownerAccountID == accountID else {
            throw AccountScopedSyncError.parentOwnerMismatch(result.id)
        }
        try record(mutation, .stepResult, result.id, for: accountID, in: context, now: now)
    }

    /// Whether this account has already deleted this entity, for good.
    func isTombstoned(
        _ entityType: SyncEntityType,
        _ entityID: UUID,
        for accountID: UUID,
        in context: ModelContext
    ) throws -> Bool {
        let identity = SyncOutboxItem.identity(
            accountID: accountID,
            entityType: entityType,
            entityID: entityID
        )
        return try context.fetchCount(
            FetchDescriptor<SyncTombstone>(
                predicate: #Predicate { $0.identity == identity }
            )
        ) > 0
    }

    /// Record that the server has accepted a deletion, and retire the queue
    /// entry that carried it.
    ///
    /// Idempotent: acknowledging the same delete twice leaves one tombstone
    /// with its original timestamp, because a duplicate ACK says nothing new
    /// and re-stamping it would move a terminal fact.
    ///
    /// Takes ids rather than a row: by the time the server confirms a delete,
    /// the local row is usually gone.
    func confirmDeletion(
        _ entityType: SyncEntityType,
        _ entityID: UUID,
        for accountID: UUID,
        in context: ModelContext,
        now: Date = Date()
    ) throws {
        let identity = SyncOutboxItem.identity(
            accountID: accountID,
            entityType: entityType,
            entityID: entityID
        )
        let existing = try context.fetch(
            FetchDescriptor<SyncTombstone>(
                predicate: #Predicate { $0.identity == identity }
            )
        ).first
        if existing == nil {
            context.insert(
                SyncTombstone(
                    identity: identity,
                    accountID: accountID,
                    entityType: entityType,
                    entityID: entityID,
                    deletedAt: now
                )
            )
        }
        if let queued = try context.fetch(
            FetchDescriptor<SyncOutboxItem>(
                predicate: #Predicate { $0.identity == identity }
            )
        ).first {
            context.delete(queued)
        }
    }

    /// Queue a mutation, or fold it into the one already queued.
    ///
    /// A delete replaces a pending upsert — the record is going away, so its
    /// contents no longer matter. An upsert is refused once the entity is
    /// finished, whether that is still pending in the queue or already
    /// acknowledged as a tombstone.
    ///
    /// Private: every caller comes through an entry point that has checked a
    /// real row's owner, so there is no way to queue work for an account by
    /// simply naming it.
    ///
    /// Saving is the caller's, so a mutation can be recorded in the same
    /// transaction as the change it describes.
    private func record(
        _ mutation: SyncMutationKind,
        _ entityType: SyncEntityType,
        _ entityID: UUID,
        for accountID: UUID,
        in context: ModelContext,
        now: Date = Date()
    ) throws {
        if mutation == .upsert,
           try isTombstoned(entityType, entityID, for: accountID, in: context) {
            throw AccountScopedSyncError.tombstoneIsTerminal(entityType, entityID)
        }
        let identity = SyncOutboxItem.identity(
            accountID: accountID,
            entityType: entityType,
            entityID: entityID
        )
        let existing = try context.fetch(
            FetchDescriptor<SyncOutboxItem>(
                predicate: #Predicate { $0.identity == identity }
            )
        ).first

        guard let existing else {
            context.insert(
                SyncOutboxItem(
                    identity: identity,
                    accountID: accountID,
                    entityType: entityType,
                    entityID: entityID,
                    mutation: mutation,
                    createdAt: now,
                    updatedAt: now
                )
            )
            return
        }

        if existing.mutation == .delete && mutation == .upsert {
            throw AccountScopedSyncError.tombstoneIsTerminal(entityType, entityID)
        }
        existing.mutation = mutation
        existing.updatedAt = now
    }

    /// Drop an entry once the server has accepted it.
    func clear(_ item: SyncOutboxItem, in context: ModelContext) {
        context.delete(item)
    }
}
