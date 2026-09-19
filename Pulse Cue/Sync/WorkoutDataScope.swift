//
//  WorkoutDataScope.swift
//  Pulse Cue
//
//  Whose workout data this device is currently showing, resuming and syncing.
//
//  `AccountScopedSync` answered "who owns this row". This answers the other
//  half — "who is asking" — and the two meet in one predicate,
//  `matches(ownerAccountID:)`, so no screen gets to invent its own idea of
//  what belongs to the person in front of it. A History that filtered and a
//  Home that did not would not read as a bug; it would read as History being
//  broken, and the leak would be the part nobody noticed.
//
//  Three cases, and the third is the one that matters:
//
//    * `.guest` — no server session. Guest rows, and only guest rows.
//    * `.account(id)` — a server-confirmed account. That account's rows only.
//    * `.undetermined` — we cannot name the scope right now. **Nothing.**
//
//  `.undetermined` is not an error state to be smoothed over. At launch, while
//  a stored session is being confirmed, the honest answer to "whose data is
//  this" is "not known yet", and the two ways to smooth that over are both
//  wrong: showing guest data flashes somebody else's history at an account
//  holder, and guessing an account shows an account's history to whoever is
//  holding the phone. Showing nothing for the moment it takes to confirm is
//  the only answer that is never wrong.
//
//  **Offline is not undetermined.** A signed-in user in a basement gym must
//  still see their own history — that is most of what this app is for, and
//  `ServerAccountStore` is built around never treating a network failure as a
//  sign-out. So the last account the server actually confirmed is remembered
//  on this device, and `.unreachable` resolves to it. The remembered value is
//  a server-confirmed account UUID, the same one already written into every
//  row that account owns; it is not a provider subject and never becomes one.
//
//  A sign-out clears it, so the next launch after signing out is `.guest`
//  rather than a stale account.
//

import Foundation
import Combine
import SwiftData

/// Whose workout data is in scope right now.
enum WorkoutDataScope: Equatable {
    case guest
    case account(UUID)
    /// The scope is not knowable yet. Shows nothing, resumes nothing.
    case undetermined

    /// Whether a row with this owner belongs to the current scope.
    ///
    /// The single definition of "mine" for workout data. Views, the Runner and
    /// the sync boundary all ask this question here.
    func matches(ownerAccountID: UUID?) -> Bool {
        switch self {
        case .guest:
            return ownerAccountID == nil
        case let .account(id):
            return ownerAccountID == id
        case .undetermined:
            return false
        }
    }

    /// The account rows created right now belong to, or nil for guest.
    ///
    /// `.undetermined` deliberately has no answer — see `canCreateWorkouts`.
    var creationOwnerAccountID: UUID? {
        if case let .account(id) = self { return id }
        return nil
    }

    /// Whether a new workout may be started at all.
    ///
    /// False only while the scope is unknown. Starting one there would have to
    /// guess an owner, and the guess that looks harmless — "call it guest for
    /// now" — is the one that quietly makes an account holder's workout
    /// unsyncable and invisible the moment their session confirms.
    var canCreateWorkouts: Bool {
        self != .undetermined
    }

    /// The account this scope may sync as, if any.
    ///
    /// Guest data is never sync-eligible. It becomes eligible by being
    /// adopted, which is a decision only the person holding the phone makes —
    /// so there is deliberately no `owner ?? currentAccount` anywhere.
    var syncAccountID: UUID? {
        creationOwnerAccountID
    }

    // MARK: Filtering

    func visible(_ sessions: [Session]) -> [Session] {
        sessions.filter { matches(ownerAccountID: $0.ownerAccountID) }
    }

    func visible(_ results: [StepResult]) -> [StepResult] {
        results.filter { matches(ownerAccountID: $0.ownerAccountID) }
    }

    // MARK: Resolution

    /// The scope implied by an account state, given the last account the
    /// server confirmed on this device.
    ///
    /// Pure, so the whole policy can be read — and tested — in one place
    /// rather than inferred from what each screen happens to do.
    static func resolve(
        state: ServerAccountState,
        lastConfirmedAccountID: UUID?
    ) -> WorkoutDataScope {
        switch state {
        case .guest, .notConfigured:
            // No session, or no account feature in this build. Both are
            // ordinary, fully working states, and both mean guest data.
            return .guest

        case let .authenticated(profile):
            // Fail closed on an id we cannot read. Falling back to guest here
            // would silently hand an authenticated user a different data set
            // and make everything they then recorded unsyncable.
            guard let id = UUID(uuidString: profile.user.id) else { return .undetermined }
            return .account(id)

        case .unreachable:
            // A held session the server could not confirm this launch. The
            // account is known from the last confirmation; without one there
            // is nothing honest to show.
            guard let last = lastConfirmedAccountID else { return .undetermined }
            return .account(last)

        case .restoring, .signingIn:
            return .undetermined

        case .localCleanupFailed:
            // A sign-out that did not finish. Showing the account's data would
            // ignore what the user asked for; showing guest data would claim
            // the sign-out succeeded. Neither is true yet.
            return .undetermined
        }
    }
}

/// Everything a cached progress derivation reads, including whose data it is.
///
/// Progress screens cache their summary and recompute when their inputs
/// change, which means the cache is only as correct as the definition of
/// "inputs". Counting rows is not that definition: two accounts with ten
/// sessions each produce the same count, so switching between them left one
/// account looking at the other's totals — the cache never learned anything
/// had changed. Row identity catches that on its own, and the scope is carried
/// as well so the guarantee does not rest on two accounts never sharing a set
/// of ids.
struct ScopedProgressSignature: Equatable {
    let scope: WorkoutDataScope
    let history: HomeProgressSummary.ChangeSignature

    /// Takes the *unscoped* arrays and filters them here, so the signature and
    /// the value it guards cannot be computed over different inputs.
    init(
        scope: WorkoutDataScope,
        allSessions: [Session],
        allResults: [StepResult],
        routines: [Routine]
    ) {
        self.scope = scope
        self.history = HomeProgressSummary.changeSignature(
            sessions: scope.visible(allSessions),
            results: scope.visible(allResults),
            routines: routines
        )
    }
}

/// Publishes the current `WorkoutDataScope`, and remembers the last account
/// the server confirmed so offline launches stay in the right scope.
///
/// Observes `ServerAccountStore` rather than changing it: sign-in, sign-out
/// and deletion behave exactly as they did, and nothing here can end a
/// session.
@MainActor
final class WorkoutDataScopeResolver: ObservableObject {
    @Published private(set) var scope: WorkoutDataScope = .undetermined

    private let defaults: UserDefaults
    private var cancellable: AnyCancellable?

    /// Where the last server-confirmed account id is kept. A UUID string, and
    /// nothing else about the person.
    static let lastConfirmedAccountKey = "sync.lastConfirmedAccountID"

    init(account: ServerAccountStore, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        apply(account.state)
        cancellable = account.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.apply(state) }
    }

    /// For tests and previews: a fixed scope with no store behind it.
    init(fixed scope: WorkoutDataScope, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.scope = scope
    }

    private func apply(_ state: ServerAccountState) {
        switch state {
        case let .authenticated(profile):
            if let id = UUID(uuidString: profile.user.id) {
                defaults.set(id.uuidString, forKey: Self.lastConfirmedAccountKey)
            }
        case .guest:
            // A confirmed sign-out. Forgetting is the point: the next launch
            // must be guest, not a stale account.
            defaults.removeObject(forKey: Self.lastConfirmedAccountKey)
        case .restoring, .signingIn, .unreachable, .notConfigured, .localCleanupFailed:
            break
        }
        scope = WorkoutDataScope.resolve(
            state: state,
            lastConfirmedAccountID: lastConfirmedAccountID
        )
    }

    private var lastConfirmedAccountID: UUID? {
        defaults.string(forKey: Self.lastConfirmedAccountKey).flatMap(UUID.init(uuidString:))
    }
}
