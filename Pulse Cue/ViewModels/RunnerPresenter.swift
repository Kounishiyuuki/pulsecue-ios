//
//  RunnerPresenter.swift
//  Pulse Cue
//
//  UI-presentation state for the Runner full-screen cover, kept *separate*
//  from the workout's domain state (`RunnerViewModel.isRunning`).
//
//  Contract:
//   - The workout itself is owned solely by RunnerViewModel. This type never
//     starts, ends, or mutates a session — it only decides whether the cover
//     is on screen.
//   - `syncPresentation(shouldPresent:)` mirrors the domain state: a workout
//     becoming active presents the cover; it stays presented while a finished
//     workout's Completion summary is still showing, and is dismissed once
//     neither holds. ContentView calls this on every
//     `RunnerViewModel.shouldPresentRunner` change and once at launch (so a
//     session recovered from disk re-presents its Runner).
//   - `resume(isRunning:)` is the explicit "ワークアウトを再開" path: it
//     re-presents the cover for an *already active* workout WITHOUT touching
//     domain state, so no new Session is ever created. When nothing is
//     running it is a no-op (never presents an empty Runner).
//
//  Because the cover is bound to `isRunnerCovered` and marked
//  `.interactiveDismissDisabled` while active, presentation cannot silently
//  desync from an active workout.
//

import Foundation
import Combine
import SwiftData
import UIKit
import UserNotifications

@MainActor
final class RunnerPresenter: ObservableObject {
    /// Whether the Runner full-screen cover is currently shown.
    @Published var isRunnerCovered: Bool = false

    /// Mirror the authoritative workout state onto presentation.
    func syncPresentation(shouldPresent: Bool) {
        isRunnerCovered = shouldPresent
    }

    /// Explicit user-initiated resume. Only re-presents an existing active
    /// workout; creates/mutates nothing. No-op when nothing is running.
    func resume(isRunning: Bool) {
        guard isRunning else { return }
        isRunnerCovered = true
    }
}

// MARK: - Free Workout
//
// Kept in this file only because a new file would need a project.pbxproj
// change; they belong in their own FreeWorkout*.swift files.

/// Home / Training's Free Workout entry: start, or resume / discard what is
/// already in progress. Every decision is the domain's
/// (`FreeWorkoutSession.start`, `FreeWorkoutRecovery`); this holds UI state.
@MainActor
final class FreeWorkoutLauncher: ObservableObject {

    enum Notice: Equatable {
        /// The data scope is not known yet, so nothing may start.
        case scopeUndetermined
        /// The workout was finished with nothing performed: not saved.
        case nothingSaved
    }

    @Published private(set) var candidates: [FreeWorkoutRecovery.Candidate] = []
    /// The open workout screen, when there is one.
    @Published var presented: FreeWorkoutViewModel?
    @Published var notice: Notice?
    /// Set while an action runs, so its button can be disabled. Not what
    /// makes it safe — the domain refuses doubles on its own.
    @Published private(set) var isBusy = false

    private var context: ModelContext?
    private var scope: WorkoutDataScope = .undetermined
    /// The app's scope authority. Read for the scope at the moment of an
    /// action, since `configure` only arrives after SwiftUI's next update.
    private var authority: WorkoutScopeAuthority?
    private let drafts: FreeWorkoutDraftStore
    private let restTimers: RestTimerStore

    /// `drafts` and `restTimers` are shared by Home's and Training's cards so
    /// a workout left from one and resumed from the other keeps its typed
    /// values and its rest.
    init(drafts: FreeWorkoutDraftStore? = nil, restTimers: RestTimerStore? = nil) {
        self.drafts = drafts ?? .shared
        self.restTimers = restTimers ?? .shared
    }

    /// A new scope revokes the open workout's session (domain), so nothing
    /// held from it — this screen, its rows' actions, the object itself —
    /// writes again, and closes the screen. Revoking is not discarding: the
    /// workout stays in the store, resumable by its owner. Re-stating the
    /// same scope keeps it.
    func configure(context: ModelContext, scope: WorkoutDataScope, authority: WorkoutScopeAuthority? = nil) {
        self.context = context
        if let authority { self.authority = authority }
        if let model = presented, scope != self.scope || !model.session.isAuthorized {
            model.session.revoke()
            presented = nil
        }
        self.scope = scope
        // A rest the new scope may not see — or one from before a scope
        // change, even back to the same account — ends here.
        restTimers.revalidate(scope: currentScope)
        refresh()
    }

    /// The scope an action runs in: the authority's when there is one.
    private var currentScope: WorkoutDataScope { authority?.scope ?? scope }

    func refresh() {
        guard let context else { return }
        candidates = FreeWorkoutRecovery.candidates(in: context, scope: currentScope)
        // Drafts of this scope's workouts that are no longer in progress —
        // finished or discarded elsewhere — are dropped; the open one always
        // stays, and other owners' drafts are not this scope's to judge.
        drafts.prune(in: currentScope, keeping: Set(candidates.map(\.id)).union(presented.map { [$0.id] } ?? []))
    }

    func start(now: Date = Date()) {
        guard let context, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        switch FreeWorkoutSession.start(in: context, scope: currentScope, authority: authority, now: now) {
        case let .started(session):
            try? context.save()
            open(session, context: context)
        case let .activeWorkoutExists(existing):
            // Nothing created: the card now offers 再開 / 破棄 for these.
            candidates = existing
        case .scopeUndetermined:
            notice = .scopeUndetermined
        }
    }

    func resume(_ candidate: FreeWorkoutRecovery.Candidate) {
        guard let context, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        if let session = FreeWorkoutRecovery.resume(candidate, in: context, scope: currentScope, authority: authority) {
            open(session, context: context)
        }
        refresh()
    }

    /// Home's rest pill, tapped. `shown` is the rest the pill was drawn for;
    /// it opens its workout only while that very rest is still the running
    /// one in this scope — not after it ended, was replaced, or the scope
    /// moved on — and only through the same lookup as 再開.
    @discardableResult
    func resumeRest(_ shown: RestTimerStore.Rest) -> Bool {
        guard let current = restTimers.currentRest(),
              current.token == shown.token, current.sessionId == shown.sessionId
        else { return false }
        return resume(sessionId: shown.sessionId)
    }

    /// History's 進行中 row. The row only knows a session id it listed some
    /// time ago, so the candidate is looked up afresh in the current scope:
    /// a workout finished, discarded or owned by someone else since then is
    /// simply not found. False when nothing was opened.
    @discardableResult
    func resume(sessionId: UUID) -> Bool {
        guard context != nil, !isBusy else { return false }
        refresh()
        guard let candidate = candidates.first(where: { $0.id == sessionId }),
              candidate.isResumable
        else { return false }
        resume(candidate)
        return presented?.id == sessionId
    }

    func discard(_ candidate: FreeWorkoutRecovery.Candidate) {
        guard let context, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        if FreeWorkoutRecovery.discard(candidate, in: context, scope: currentScope, authority: authority) {
            drafts.clear(candidate.id)
            restTimers.endRest(of: candidate.id)
            try? context.save()
        }
        refresh()
    }

    /// The workout screen closed — finished, discarded or just left.
    /// `model` is the screen that is closing, captured when it was shown. It
    /// is matched by object, not by session id: resuming the same workout
    /// opens a new screen with the same id, and a late close from the screen
    /// it replaced (after a scope change, or a close and resume) must not
    /// close it. Such a close does nothing.
    func workoutScreenClosed(_ model: FreeWorkoutViewModel) {
        guard presented === model else { return }
        // A closed screen writes nothing more, even to the same workout:
        // resuming it opens a new screen on a new session object, and an
        // action still held by this one (a menu left open, a late closure)
        // must not reach the new screen's drafts or sets. Revoking is not
        // discarding; the workout stays resumable.
        model.session.revoke()
        if model.finishOutcome == .discarded { notice = .nothingSaved }
        presented = nil
        refresh()
    }

    private func open(_ session: FreeWorkoutSession, context: ModelContext) {
        // Whatever screen this replaces stops writing (see `workoutScreenClosed`).
        if let replaced = presented, replaced.session !== session { replaced.session.revoke() }
        presented = FreeWorkoutViewModel(session: session, context: context, drafts: drafts, restTimers: restTimers)
    }
}

// MARK: - Rest timer

/// One rest's countdown, measured against a deadline: nothing ticks and
/// nothing is counted down, so a late tick, the app in the background or the
/// device asleep never makes it wrong — every read is `deadline - now`. Pure:
/// `now` is always passed in. Like the Runner's rest, it is wall-clock based,
/// so changing the device clock moves it.
struct RestCountdown: Equatable {
    /// The longest rest it holds, the same ceiling as `Step.clampRest`.
    static let maximumSeconds: TimeInterval = 600

    let startedAt: Date
    /// The rest as it started (the step's rest), for display.
    let initialDuration: TimeInterval
    private(set) var deadline: Date

    /// Nil for a non-positive, non-finite or out-of-range duration: no rest.
    init?(seconds: Int, now: Date) {
        guard seconds > 0 else { return nil }
        let duration = min(TimeInterval(seconds), Self.maximumSeconds)
        startedAt = now
        initialDuration = duration
        deadline = now.addingTimeInterval(duration)
    }

    func remaining(now: Date) -> TimeInterval {
        let value = deadline.timeIntervalSince(now)
        return value.isFinite ? max(0, value) : 0
    }

    /// Whole seconds left, rounded up: "0:01" until it is really over.
    func remainingSeconds(now: Date) -> Int {
        Int(remaining(now: now).rounded(.up))
    }

    func isExpired(now: Date) -> Bool { remaining(now: now) <= 0 }

    /// The arc's share still to run, 0...1: what is left over the rest as it
    /// now stands (start to the current deadline), so +15 / −15 never push it
    /// past full or below empty.
    func fractionRemaining(now: Date) -> Double {
        let total = deadline.timeIntervalSince(startedAt)
        guard total.isFinite, total > 0 else { return 0 }
        return min(1, max(0, remaining(now: now) / total))
    }

    /// Moves the deadline by `seconds`, keeping what is left within
    /// 0...`maximumSeconds`. An expired countdown stays expired: a late +15
    /// never brings a finished rest back.
    func adjusted(by seconds: Int, now: Date) -> RestCountdown {
        guard !isExpired(now: now) else { return self }
        var copy = self
        let left = min(Self.maximumSeconds, max(0, remaining(now: now) + TimeInterval(seconds)))
        copy.deadline = now.addingTimeInterval(left)
        return copy
    }
}

/// The app's one rest timer: the rest after the last set completed in a Free
/// Workout. It belongs to the workout, not to a screen — closing the screen
/// leaves it running, and the reopened screen shows it — but it is never a
/// way around authorization:
/// - it starts only from a screen whose session may write (the caller checks
///   `FreeWorkoutSession.isActive`), and keeps that session's scope grant, so
///   any scope change (A → B → A included) ends it for good;
/// - each rest has its own token; +15 / −15 / 終了 must name the session and
///   the token they were shown for, so an action for an older rest is a no-op;
/// - finish, discard and a scope change end it; ending names the session, so
///   an older workout's cleanup never ends a newer one's rest.
///
/// Process memory only, like the drafts. A relaunch loses it; a notification
/// already scheduled still fires at its time. The Runner keeps its own rest.
@MainActor
final class RestTimerStore: ObservableObject {
    static let shared = RestTimerStore()

    struct Rest: Equatable {
        let sessionId: UUID
        let ownerAccountID: UUID?
        /// New for every rest, even in the same workout.
        let token: UUID
        var countdown: RestCountdown
        /// The exercise whose set started it, for the Home pill and the
        /// expanded timer. Never put in the notification.
        let exerciseTitle: String
        fileprivate let grant: WorkoutScopeAuthority.Grant?

        static func == (lhs: Rest, rhs: Rest) -> Bool {
            lhs.sessionId == rhs.sessionId && lhs.ownerAccountID == rhs.ownerAccountID
                && lhs.token == rhs.token && lhs.countdown == rhs.countdown
                && lhs.exerciseTitle == rhs.exerciseTitle
        }

        fileprivate var isAuthorized: Bool {
            guard let grant else { return true }
            return grant.authority.isValid(grant, forOwner: ownerAccountID)
        }
    }

    /// Changes only when a rest starts, is adjusted or ends — never per
    /// second; the bar computes the time left itself.
    @Published private(set) var rest: Rest?

    private let notifications: any RunnerNotificationManaging
    private let notificationsEnabled: () -> Bool
    private let now: () -> Date
    private let expiryFeedback: () -> Void
    private let scheduleExpiry: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    /// Bumped by every schedule / cancel, so an answer that comes back for an
    /// older one is dropped.
    private var notificationRevision = 0
    /// When the app last became active, nil while it is not. A rest sounds
    /// only if the app was active from before its deadline: the state at the
    /// moment the expiry runs says nothing about where the deadline passed.
    private var activeSince: Date?
    private var lifecycleObservers: [AnyCancellable] = []
    /// The rest that sounded last, so one rest never sounds twice.
    private var soundedToken: UUID?
    /// A rest that ended at its deadline: its notification was left for the
    /// system to deliver, but is still this store's to take back if the
    /// scope changes or its workout ends before it shows.
    private var lingering: (sessionId: UUID, ownerAccountID: UUID?, deadline: Date)?
    private weak var observedAuthority: WorkoutScopeAuthority?

    /// How late the expiry may run and still sound. A rest that ran out while
    /// the app was suspended was announced by the notification; the app
    /// coming back minutes later must not beep for it.
    static let expiryFeedbackTolerance: TimeInterval = 2

    init(
        notifications: (any RunnerNotificationManaging)? = nil,
        notificationsEnabled: (() -> Bool)? = nil,
        now: @escaping () -> Date = Date.init,
        lifecycle: NotificationCenter = .default,
        initiallyActive: Bool? = nil,
        expiryFeedback: (() -> Void)? = nil,
        scheduleExpiry: ((TimeInterval, @escaping @MainActor () -> Void) -> Void)? = nil
    ) {
        self.notifications = notifications ?? NotificationManager.shared
        self.notificationsEnabled = notificationsEnabled ?? { UserDefaults.standard.bool(forKey: "settings.notificationsEnabled") }
        self.now = now
        let active = initiallyActive ?? (UIApplication.shared.applicationState == .active)
        self.activeSince = active ? now() : nil
        self.expiryFeedback = expiryFeedback ?? Self.playExpiryFeedback
        self.scheduleExpiry = scheduleExpiry ?? { delay, fire in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(max(0, delay)))
                fire()
            }
        }
        lifecycleObservers = [
            lifecycle.publisher(for: UIApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.activeSince = self?.now() } },
            lifecycle.publisher(for: UIApplication.willResignActiveNotification)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.activeSince = nil } },
        ]
    }

    /// Ends the rest on every scope change the authority makes — each one,
    /// even A → B → A within one update that SwiftUI would see as nothing.
    /// The authority only calls back; it knows nothing of this store.
    func observe(_ authority: WorkoutScopeAuthority) {
        guard observedAuthority !== authority else { return }
        observedAuthority = authority
        authority.addObserver { [weak self] scope in self?.revalidate(scope: scope) }
    }

    /// The sound and haptic the Settings switches allow — the same ones, and
    /// the same switches, as the Runner's.
    private static func playExpiryFeedback() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "settings.soundEnabled") as? Bool ?? true { SoundHapticManager.playBeep() }
        if defaults.object(forKey: "settings.hapticsEnabled") as? Bool ?? true { SoundHapticManager.playHaptic() }
    }

    /// The running rest of `sessionId`, if it is still authorized and not
    /// over. Reading never changes anything.
    func activeRest(for sessionId: UUID) -> Rest? {
        guard let rest, rest.sessionId == sessionId else { return nil }
        return currentRest()
    }

    /// The running rest, whichever workout it belongs to, if it is still
    /// authorized and not over: what Home's pill shows.
    func currentRest() -> Rest? {
        guard let rest, rest.isAuthorized, !rest.countdown.isExpired(now: now()) else { return nil }
        return rest
    }

    /// Starts a new rest for `sessionId`, replacing any other (one rest at a
    /// time). Nil when `grant` is not valid for `ownerAccountID` — nothing
    /// changes — or when the set has no rest (`seconds <= 0`): the previous
    /// rest ends then too, since the set it followed is no longer the last.
    @discardableResult
    func start(sessionId: UUID, ownerAccountID: UUID?, grant: WorkoutScopeAuthority.Grant?, seconds: Int, exerciseTitle: String = "") -> UUID? {
        if let grant, !grant.authority.isValid(grant, forOwner: ownerAccountID) { return nil }
        guard let countdown = RestCountdown(seconds: seconds, now: now()) else {
            end()
            return nil
        }
        if let old = rest { cancelNotification(for: old.sessionId) }
        // The new rest's notification takes the identifier over.
        if lingering?.sessionId == sessionId { lingering = nil }
        let token = UUID()
        rest = Rest(sessionId: sessionId, ownerAccountID: ownerAccountID, token: token, countdown: countdown,
                    exerciseTitle: exerciseTitle, grant: grant)
        scheduleNotification()
        armExpiry()
        return token
    }

    /// Ends the rest at its deadline even with no timer view on screen. Each
    /// arming is for one token and one deadline; an older one finds the rest
    /// changed and does nothing.
    private func armExpiry() {
        guard let rest else { return }
        let token = rest.token
        let deadline = rest.countdown.deadline
        scheduleExpiry(deadline.timeIntervalSince(now())) { [weak self] in
            self?.expire(token: token, deadline: deadline)
        }
    }

    private func expire(token: UUID, deadline: Date) {
        guard let rest, rest.token == token, rest.countdown.deadline == deadline else { return }
        guard rest.countdown.isExpired(now: now()) else {
            armExpiry()
            return
        }
        let onTime = now().timeIntervalSince(deadline) <= Self.expiryFeedbackTolerance
        let activeAcrossDeadline = activeSince.map { $0 <= deadline } ?? false
        retire()
        // In the foreground the system shows no notification (the app has no
        // `willPresent` delegate), so the app sounds instead. A deadline that
        // passed in the background or while inactive was the notification's,
        // even if the app is active again by the time this runs.
        guard onTime, activeAcrossDeadline, soundedToken != token else { return }
        soundedToken = token
        expiryFeedback()
    }

    /// The natural end: the rest and its token go, late answers about it are
    /// dropped, but its notification is not taken back — the system may not
    /// have delivered it yet, and taking it back could lose it.
    private func retire() {
        guard let old = rest else { return }
        rest = nil
        notificationRevision &+= 1
        lingering = (old.sessionId, old.ownerAccountID, old.countdown.deadline)
    }

    /// +15 / −15 for the rest shown as (`sessionId`, `token`). Reaching 0 ends
    /// it. False, and nothing changed, for any other or a finished rest.
    @discardableResult
    func adjust(by seconds: Int, sessionId: UUID, token: UUID) -> Bool {
        guard var current = activeRest(for: sessionId), current.token == token else { return false }
        current.countdown = current.countdown.adjusted(by: seconds, now: now())
        if current.countdown.isExpired(now: now()) {
            end()
        } else {
            rest = current
            scheduleNotification()
            armExpiry()
        }
        return true
    }

    /// 休憩終了 for the rest shown as (`sessionId`, `token`).
    @discardableResult
    func finish(sessionId: UUID, token: UUID) -> Bool {
        guard let current = activeRest(for: sessionId), current.token == token else { return false }
        end()
        return true
    }

    /// The workout `sessionId` ended (finished or discarded): its rest goes.
    /// Another workout's rest is left alone.
    func endRest(of sessionId: UUID) {
        if lingering?.sessionId == sessionId {
            lingering = nil
            cancelNotification(for: sessionId)
        }
        guard rest?.sessionId == sessionId else { return }
        end()
    }

    /// Drops a rest that is over, or that `scope` may no longer see: called
    /// on a scope change and when the app comes back to the foreground. The
    /// same scope again keeps a valid rest.
    func revalidate(scope: WorkoutDataScope) {
        // A notification left after a natural end goes with its scope.
        if let left = lingering, !scope.matches(ownerAccountID: left.ownerAccountID) {
            lingering = nil
            cancelNotification(for: left.sessionId)
        }
        guard let rest else { return }
        if !scope.matches(ownerAccountID: rest.ownerAccountID) || !rest.isAuthorized {
            end()
        } else if rest.countdown.isExpired(now: now()) {
            retire()
        }
    }

    /// Every end but the natural one: the notification goes too.
    private func end() {
        guard let old = rest else { return }
        rest = nil
        cancelNotification(for: old.sessionId)
    }

    static func notificationIdentifier(for sessionId: UUID) -> String {
        // Not the Runner's "rest.<id>": the two never cancel each other's.
        "freeWorkoutRest.\(sessionId.uuidString)"
    }

    private func cancelNotification(for sessionId: UUID) {
        notificationRevision &+= 1
        notifications.removeNotification(identifier: Self.notificationIdentifier(for: sessionId))
    }

    /// Replaces the pending notification with one at the current deadline.
    /// Authorization is asked asynchronously; the answer is used only if it
    /// is still about this very rest at this very deadline.
    private func scheduleNotification() {
        guard let current = rest else { return }
        cancelNotification(for: current.sessionId)
        guard notificationsEnabled() else { return }
        let revision = notificationRevision
        let identifier = Self.notificationIdentifier(for: current.sessionId)
        notifications.getAuthorizationStatus { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self, revision == self.notificationRevision,
                      let rest = self.rest, rest.token == current.token,
                      rest.countdown.deadline == current.countdown.deadline,
                      !rest.countdown.isExpired(now: self.now()),
                      status == .authorized || status == .provisional
                else { return }
                self.notifications.scheduleRestNotification(deadline: rest.countdown.deadline, identifier: identifier) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, revision != self.notificationRevision else { return }
                        // The rest ended at its deadline: this notification
                        // is the one the system should deliver.
                        if self.rest == nil, let left = self.lingering, left.sessionId == current.sessionId,
                           left.deadline == current.countdown.deadline { return }
                        // Superseded while it was being added: take it back,
                        // and put the current rest's back if this removed it.
                        self.notifications.removeNotification(identifier: identifier)
                        if let rest = self.rest, rest.sessionId == current.sessionId, !rest.countdown.isExpired(now: self.now()) {
                            self.scheduleNotification()
                        }
                    }
                }
            }
        }
    }
}

/// Values typed into set rows not yet logged, per workout, for the life of
/// the process only.
///
/// Closing the workout screen and resuming it keeps them; a relaunch loses
/// them by design — they are never persisted (a blank row is an input field,
/// not a set), and the row count and logged sets come back from the store.
/// Keyed by session so two leftover workouts never share a draft.
@MainActor
final class FreeWorkoutDraftStore {
    static let shared = FreeWorkoutDraftStore()

    struct Draft: Equatable {
        /// This open row's identity while it exists. A row has no
        /// `StepResult` until it is logged, and its `setIndex` shifts when a
        /// row above is removed, so an action made for the row carries this
        /// to make sure it still lands on the same row — never on the row
        /// that moved into its place or a new one added at its position.
        let rowId: UUID
        var weightKg: Double?
        var reps: Int
        /// Touched by the user (any value, duration included): kept when the
        /// screen is reopened.
        var edited: Bool
        /// Whether the user set this value. A value the user did not set is
        /// a default and follows the row (its kind, its position among the
        /// working sets, the sets logged above); one the user set is never
        /// replaced, even when it equals the default.
        var weightEdited: Bool
        var repsEdited: Bool
        /// A timed set's duration as typed; empty until entered.
        var duration = DurationEntry()
        /// The kind the row will be logged as. New rows are working.
        var setType: WorkoutSetType = .working

        init(
            rowId: UUID = UUID(),
            weightKg: Double?,
            reps: Int,
            edited: Bool,
            duration: DurationEntry = DurationEntry(),
            setType: WorkoutSetType = .working
        ) {
            self.rowId = rowId
            self.weightKg = weightKg
            self.reps = reps
            self.edited = edited
            self.weightEdited = edited
            self.repsEdited = edited
            self.duration = duration
            self.setType = setType
        }

        /// Worth keeping when the screen is reopened: anything the user chose.
        var isUserChoice: Bool { edited || setType != .working }
    }

    private struct Entry {
        let ownerAccountID: UUID?
        var drafts: [FreeWorkoutViewModel.RowKey: Draft]
    }

    private var bySession: [UUID: Entry] = [:]

    var sessionIds: Set<UUID> { Set(bySession.keys) }

    func drafts(for sessionId: UUID) -> [FreeWorkoutViewModel.RowKey: Draft] {
        bySession[sessionId]?.drafts ?? [:]
    }

    func set(_ drafts: [FreeWorkoutViewModel.RowKey: Draft], for sessionId: UUID, ownerAccountID: UUID?) {
        bySession[sessionId] = drafts.isEmpty ? nil : Entry(ownerAccountID: ownerAccountID, drafts: drafts)
    }

    func clear(_ sessionId: UUID) {
        bySession[sessionId] = nil
    }

    /// Drops `scope`'s entries not in `sessionIds`. Entries of other owners
    /// are left alone — an account switch must not erase their drafts.
    func prune(in scope: WorkoutDataScope, keeping sessionIds: Set<UUID>) {
        bySession = bySession.filter { id, entry in
            sessionIds.contains(id) || !scope.matches(ownerAccountID: entry.ownerAccountID)
        }
    }
}

/// The Free Workout screen's state. Exercises and sets come from the store
/// through `FreeWorkoutSession`; the only thing held here is the *draft* of
/// rows not yet logged — values typed into a row before ✓ or Skip, which by
/// design are not persisted (a blank row is an input field, not a set).
@MainActor
final class FreeWorkoutViewModel: ObservableObject, Identifiable {

    struct RowKey: Hashable {
        let stepId: UUID
        let setIndex: Int
    }

    /// Which row an action was made for: a logged set by its `StepResult.id`,
    /// an open row by its draft's `rowId`. An action whose row is no longer
    /// at its key does nothing.
    enum RowIdentity: Hashable {
        case draft(UUID)
        case result(UUID)
    }

    struct SetRow: Identifiable, Equatable {
        enum State: Equatable { case draft, done, skipped }
        let key: RowKey
        var id: RowKey { key }
        var number: Int { key.setIndex + 1 }
        let state: State
        var identity: RowIdentity
        /// The kind it was logged as, or will be. Timed rows are working.
        var setType: WorkoutSetType = .working
        /// "W" or its number among the working sets (`SetTypeNumbering`).
        var label: SetTypeNumbering.Label = .working(1)
        let weightKg: Double?
        let reps: Int
        /// A timed set's duration: as typed on an open row, as recorded on a
        /// done one (or the edit that could not be saved yet).
        var duration = DurationEntry()
        /// A done set's reps in reserve as recorded; nil when not recorded,
        /// and always nil for any other row.
        var repsInReserve: Int? = nil

        /// A timed row completes only with a valid duration.
        func durationIssue(tracksReps: Bool) -> DurationEntry.Issue? {
            tracksReps ? nil : duration.issue
        }
    }

    struct ExerciseCard: Identifiable, Equatable {
        let id: UUID
        let title: String
        let acceptsWeight: Bool
        /// False for timed movements: no rep editor, and no reps are recorded.
        let tracksReps: Bool
        let previousText: String?
        let rows: [SetRow]
        let canRemove: Bool
        let canAddSet: Bool
        /// The rest the exercise's next completed set starts, in seconds.
        let restSeconds: Int
    }

    private typealias Draft = FreeWorkoutDraftStore.Draft

    let session: FreeWorkoutSession
    nonisolated let id: UUID
    private let context: ModelContext

    @Published private(set) var cards: [ExerciseCard] = []
    /// The row the editor below the list works on.
    @Published var selected: RowKey?
    @Published private(set) var finishOutcome: FreeWorkoutSession.FinishOutcome?
    @Published private(set) var completion: WorkoutCompletionSummary?

    private let draftStore: FreeWorkoutDraftStore
    /// This workout's drafts, kept in the process-wide store so they outlive
    /// this screen (see `FreeWorkoutDraftStore`).
    private var drafts: [RowKey: Draft] {
        get { draftStore.drafts(for: id) }
        set { draftStore.set(newValue, for: id, ownerAccountID: session.session.ownerAccountID) }
    }
    private var previousTextByStep: [UUID: String?] = [:]
    private var previousByStep: [UUID: PreviousPerformance?] = [:]

    /// The app's rest timer. Read by the timer bar, which observes it on its
    /// own so the rows are never rebuilt for it.
    let restTimers: RestTimerStore

    init(session: FreeWorkoutSession, context: ModelContext, drafts: FreeWorkoutDraftStore, restTimers: RestTimerStore? = nil) {
        self.session = session
        self.id = session.session.id
        self.context = context
        self.draftStore = drafts
        self.restTimers = restTimers ?? .shared
        // Only what the user typed survives a reopen; untouched defaults are
        // recomputed from the store as it is now.
        self.drafts = self.drafts.filter(\.value.isUserChoice)
        rebuild()
        selected = firstOpenRow()
    }

    var startedAt: Date { session.session.startedAt }

    func elapsedText(now: Date) -> String {
        DateUtils.formatDuration(seconds: session.elapsedSeconds(now: now))
    }

    // MARK: Exercises

    func addExercise(_ exercise: Exercise) {
        guard let step = session.addExercise(exercise) else { return }
        saveAndRebuild(select: RowKey(stepId: step.id, setIndex: 0))
    }

    /// A custom machine: no catalogue id, so no previous performance.
    func addExercise(exerciseId: String?, title: String) {
        guard let step = session.addExercise(exerciseId: exerciseId, title: title) else { return }
        saveAndRebuild(select: RowKey(stepId: step.id, setIndex: 0))
    }

    func removeExercise(_ stepId: UUID) {
        guard let step = step(stepId), session.removeExercise(step) else { return }
        drafts = drafts.filter { $0.key.stepId != stepId }
        saveAndRebuild(select: selected?.stepId == stepId ? nil : selected)
    }

    /// The exercise's rest from now on. The rest running now keeps its own
    /// time: that is the set's rest, adjusted only by ±15.
    func setRestSeconds(_ seconds: Int, for stepId: UUID) {
        guard let step = step(stepId), session.setRestSeconds(seconds, for: step) else { return }
        saveAndRebuild(select: selected)
    }

    func moveExercises(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard source.count == 1, let from = source.first else { return }
        // `onMove` gives the index *before* removal; the domain wants it after.
        let to = destination > from ? destination - 1 : destination
        guard from != to, session.moveExercise(from: from, to: to) else { return }
        saveAndRebuild(select: selected)
    }

    // MARK: Sets

    func addSet(to stepId: UUID) {
        guard let step = step(stepId), session.addSet(to: step) else { return }
        saveAndRebuild(select: RowKey(stepId: stepId, setIndex: step.sets - 1))
    }

    func removeSet(_ key: RowKey) {
        guard let step = step(key.stepId), session.removeSet(at: key.setIndex, from: step) else { return }
        // Later rows shifted down one; so do their drafts.
        var shifted: [RowKey: Draft] = [:]
        for (rowKey, draft) in drafts {
            guard rowKey.stepId == key.stepId else { shifted[rowKey] = draft; continue }
            if rowKey.setIndex < key.setIndex { shifted[rowKey] = draft }
            if rowKey.setIndex > key.setIndex { shifted[RowKey(stepId: rowKey.stepId, setIndex: rowKey.setIndex - 1)] = draft }
        }
        drafts = shifted
        saveAndRebuild(select: nil)
    }

    // MARK: Editing the selected row

    /// Tapping the selected row again closes its editor.
    func select(_ key: RowKey) {
        selected = selected == key ? nil : key
    }

    func adjustWeight(by delta: Double, for key: RowKey) {
        let current = row(key)?.weightKg ?? 0
        setWeight(current + delta, for: key)
    }

    /// Invalid values (negative, over the maximum) are ignored; nil clears.
    func setWeight(_ kg: Double?, for key: RowKey) {
        guard let row = row(key) else { return }
        if let kg, SetWeight.validated(kg) == nil { return }
        let value = kg.flatMap(SetWeight.validated)
        edit(key, row: row) { $0.weightKg = value; $0.weightEdited = true }
    }

    func adjustReps(by delta: Int, for key: RowKey) {
        guard let row = row(key) else { return }
        setReps(row.reps + delta, for: key)
    }

    func setReps(_ reps: Int, for key: RowKey) {
        guard let row = row(key) else { return }
        edit(key, row: row) { $0.reps = max(0, reps); $0.repsEdited = true }
    }

    /// Kept as typed — an invalid value shows its reason on the row and the
    /// set cannot be completed until it is fixed.
    func setDuration(_ entry: DurationEntry, for key: RowKey) {
        guard let row = row(key), let step = step(key.stepId), !tracksReps(step) else { return }
        edit(key, row: row) { $0.duration = entry }
    }

    /// A logged row is re-recorded at once — the writer overwrites in place,
    /// keeping its snapshots. A draft row only changes its draft.
    private func edit(_ key: RowKey, row: SetRow, _ change: (inout Draft) -> Void) {
        // A revoked or finished workout takes no edits — not even a draft,
        // which lives outside the store and so no domain check would catch.
        guard session.isActive else { return }
        var draft = drafts[key] ?? Draft(weightKg: row.weightKg, reps: row.reps, edited: false, duration: row.duration, setType: row.setType)
        change(&draft)
        draft.edited = true
        switch row.state {
        case .draft:
            drafts[key] = draft
            rebuild()
        case .done:
            guard let step = step(key.stepId) else { return }
            if !tracksReps(step) {
                // Re-recorded only once the edit is a valid duration; until
                // then the record keeps its value and the row shows why.
                if session.completeTimedSet(at: key.setIndex, of: step, durationSeconds: draft.duration.totalSeconds) != nil {
                    drafts[key] = nil
                    saveAndRebuild(select: key)
                } else {
                    drafts[key] = draft
                    rebuild()
                }
                return
            }
            session.completeSet(at: key.setIndex, of: step, reps: reps(draft.reps, step: step), weightKg: weight(draft.weightKg, step: step))
            saveAndRebuild(select: key)
        case .skipped:
            drafts[key] = draft
            rebuild()
        }
    }

    func complete(_ key: RowKey) {
        guard let step = step(key.stepId), let row = row(key) else { return }
        // A set completed for the first time starts a rest; re-recording a
        // done set does not. Read before writing, since the write makes it done.
        let firstCompletion = row.state != .done
        // A timed set is completed only with its duration: the duration-free
        // path is not reachable from this screen.
        let recorded = tracksReps(step)
            ? session.completeSet(at: key.setIndex, of: step, reps: reps(row.reps, step: step), weightKg: weight(row.weightKg, step: step),
                                  setType: loggedSetType(row, step: step))
            : session.completeTimedSet(at: key.setIndex, of: step, durationSeconds: row.duration.totalSeconds)
        guard recorded != nil else { return }
        if firstCompletion {
            restTimers.start(sessionId: id, ownerAccountID: session.session.ownerAccountID,
                             grant: session.scopeGrant, seconds: step.restSeconds, exerciseTitle: step.title)
        }
        drafts[key] = nil
        // Untouched values below now default from this set: `rebuild`
        // recomputes every value the user did not set.
        saveAndRebuild(select: nextOpenRow(after: key))
    }

    /// Whether row `key` takes reps in reserve: a done set of a rep-counted
    /// exercise. Draft, skipped and timed rows never show the picker.
    func acceptsRepsInReserve(_ key: RowKey) -> Bool {
        guard let row = row(key), let step = step(key.stepId) else { return false }
        return row.state == .done && tracksReps(step)
    }

    /// Sets or clears (`nil`) the reps in reserve of done row `key`. Written
    /// at once through the domain, which keeps every other value; a refused
    /// write leaves the row showing what is stored.
    func setRepsInReserve(_ value: Int?, for key: RowKey) {
        guard acceptsRepsInReserve(key), let step = step(key.stepId),
              session.recordRepsInReserve(value, at: key.setIndex, of: step) != nil else { return }
        try? context.save()
        rebuild()
    }

    // MARK: Set type

    /// Whether row `key` offers a kind: an open or done set of a
    /// rep-counted exercise. A timed row has no kind, and a skipped set
    /// keeps the kind it was logged with.
    func acceptsSetType(_ key: RowKey) -> Bool {
        guard let row = row(key), let step = step(key.stepId) else { return false }
        return tracksReps(step) && row.state != .skipped
    }

    /// Makes the row the action was made for a warm-up or a working set.
    /// `identity` and `key` are what the row was when the action was made;
    /// unless that same row is still at `key`, nothing happens. An open row
    /// only changes its draft — no `StepResult` is created and the row is not
    /// logged; a done set is rewritten through the domain, which keeps its
    /// weight, reps and RIR.
    func setSetType(_ setType: WorkoutSetType, for identity: RowIdentity, at key: RowKey) {
        guard session.isActive, acceptsSetType(key), let row = row(key), row.identity == identity,
              let step = step(key.stepId) else { return }
        switch identity {
        case let .result(resultId):
            guard row.setType != setType,
                  session.recordSetType(setType, resultId: resultId, at: key.setIndex, of: step) != nil else { return }
            try? context.save()
            rebuild()
        case .draft:
            guard var draft = drafts[key], draft.setType != setType else { return }
            draft.setType = setType
            drafts[key] = draft
            rebuild()
        }
    }

    /// The kind to log an open row with: its draft's, stated explicitly so
    /// "working" is written as chosen. A logged row (re-recorded) passes nil,
    /// which keeps the kind it has; a timed row has none.
    private func loggedSetType(_ row: SetRow, step: Step) -> WorkoutSetType? {
        guard row.state == .draft, tracksReps(step) else { return nil }
        return drafts[row.key]?.setType ?? .working
    }

    func skip(_ key: RowKey) {
        guard let step = step(key.stepId),
              session.skipSet(at: key.setIndex, of: step, setType: row(key).flatMap { loggedSetType($0, step: step) }) != nil
        else { return }
        drafts[key] = nil
        saveAndRebuild(select: nextOpenRow(after: key))
    }

    // MARK: Rest

    /// This workout's running rest, if any.
    var activeRest: RestTimerStore.Rest? { restTimers.activeRest(for: id) }

    /// +15 / −15 for the rest the bar showed (`token`). A closed or revoked
    /// screen changes nothing.
    func adjustRest(by seconds: Int, token: UUID) {
        guard session.isActive else { return }
        restTimers.adjust(by: seconds, sessionId: id, token: token)
    }

    /// 休憩終了 for the rest the bar showed.
    func finishRest(token: UUID) {
        guard session.isActive else { return }
        restTimers.finish(sessionId: id, token: token)
    }

    /// Back in the foreground: a rest that ran out meanwhile ends now.
    func appDidBecomeActive() {
        guard session.isActive else { return }
        restTimers.revalidate(scope: session.session.ownerAccountID.map(WorkoutDataScope.account) ?? .guest)
    }

    // MARK: Finish / discard

    /// Ends the workout. Saved → a completion summary to show; nothing
    /// performed → discarded by the domain.
    func finish(now: Date = Date()) {
        // A revoked workout is left exactly as it is, drafts included.
        guard session.isAuthorized else { return }
        let outcome = session.finish(now: now)
        finishOutcome = outcome
        if outcome != .notActive {
            draftStore.clear(id)
            restTimers.endRest(of: id)
        }
        guard outcome == .saved else { try? context.save(); return }
        completion = WorkoutCompletionSummary.make(
            sessionId: session.session.id,
            duration: TimeInterval(session.session.totalSeconds),
            results: session.steps.flatMap { session.results(for: $0) },
            steps: session.steps,
            bodyWeightKg: WorkoutCalorieEstimator.bodyWeightKg(for: session.session, modelContext: context)
        )
        try? context.save()
    }

    func discard() {
        guard session.isAuthorized else { return }
        if session.discard() {
            finishOutcome = .discarded
            draftStore.clear(id)
            restTimers.endRest(of: id)
        }
        try? context.save()
    }

    // MARK: Rows

    /// Done timed sets edited to a duration that could not be saved. Valid
    /// edits of a done set are written at once, like weight and reps, so
    /// these are the only edits finishing would drop — the record keeps its
    /// old value. Finish asks before dropping them.
    var unsavedDurationEdits: [RowKey] {
        cards.flatMap(\.rows).filter { $0.state == .done && drafts[$0.key] != nil }.map(\.key)
    }

    func row(_ key: RowKey) -> SetRow? {
        cards.first { $0.id == key.stepId }?.rows.first { $0.key == key }
    }

    private func rebuild() {
        cards = session.steps.map { step in
            let results = Dictionary(session.results(for: step).map { ($0.setIndex, $0) }, uniquingKeysWith: { first, _ in first })
            let tracks = tracksReps(step)
            // Each row's kind: a logged set's own, an open row's draft's. A
            // timed row has none, so it numbers and fills as it always did.
            let types: [WorkoutSetType] = (0..<step.sets).map { index in
                guard tracks else { return .working }
                return results[index]?.setType ?? drafts[RowKey(stepId: step.id, setIndex: index)]?.setType ?? .working
            }
            let labels = SetTypeNumbering.labels(types.enumerated().map { (setIndex: $0.offset, setType: $0.element) })
            var workingSetsAbove = 0
            let rows = (0..<step.sets).map { index -> SetRow in
                let key = RowKey(stepId: step.id, setIndex: index)
                let setType = types[index]
                let label = labels[index] ?? .working(index + 1)
                let workingOrdinal = workingSetsAbove
                if setType == .working { workingSetsAbove += 1 }
                if let result = results[index] {
                    // An edited skip keeps its typed values until ✓.
                    if !result.done, let draft = drafts[key] {
                        return SetRow(key: key, state: .skipped, identity: .result(result.id), setType: setType, label: label,
                                      weightKg: draft.weightKg, reps: draft.reps, duration: draft.duration)
                    }
                    // A done timed row shows an edit that could not be saved
                    // yet over the recorded value.
                    let duration = result.done
                        ? drafts[key].map(\.duration) ?? DurationEntry(totalSeconds: result.actualDurationSeconds)
                        : DurationEntry()
                    return SetRow(key: key, state: result.done ? .done : .skipped, identity: .result(result.id),
                                  setType: setType, label: label,
                                  weightKg: result.weightKg, reps: result.actualReps ?? step.repsTarget, duration: duration,
                                  repsInReserve: result.done ? result.repsInReserve : nil)
                }
                // Values the user did not set are defaults, recomputed for
                // the row as it is now — its kind, its working position, the
                // sets logged above — so a warm-up never shows a working
                // set's values and a working row follows the set it matches.
                var draft = drafts[key] ?? Draft(weightKg: nil, reps: step.repsTarget, edited: false)
                if !draft.weightEdited || !draft.repsEdited {
                    let entry = session.initialEntry(forSetAt: index, of: step, setType: setType, workingOrdinal: workingOrdinal) {
                        self.previousPerformance(for: step)
                    }
                    if !draft.weightEdited { draft.weightKg = entry.weightKg }
                    if !draft.repsEdited { draft.reps = entry.reps }
                }
                if drafts[key] != draft { drafts[key] = draft }
                return SetRow(key: key, state: .draft, identity: .draft(draft.rowId), setType: setType, label: label,
                              weightKg: draft.weightKg, reps: draft.reps, duration: draft.duration)
            }
            return ExerciseCard(
                id: step.id,
                title: step.title,
                acceptsWeight: acceptsWeight(step),
                tracksReps: tracksReps(step),
                previousText: previousText(for: step),
                rows: rows,
                canRemove: session.canRemoveExercise(step),
                canAddSet: Step.clampSets(step.sets + 1) > step.sets,
                restSeconds: step.restSeconds
            )
        }
    }

    private func saveAndRebuild(select key: RowKey?) {
        try? context.save()
        rebuild()
        selected = key.flatMap { row($0) != nil ? $0 : nil } ?? firstOpenRow()
    }

    private func firstOpenRow() -> RowKey? {
        cards.lazy.flatMap(\.rows).first { $0.state == .draft }?.key
    }

    private func nextOpenRow(after key: RowKey) -> RowKey? {
        cards.first { $0.id == key.stepId }?.rows.first { $0.key.setIndex > key.setIndex && $0.state == .draft }?.key
            ?? firstOpenRow()
    }

    private func step(_ id: UUID) -> Step? { session.steps.first { $0.id == id } }

    /// Fetched once per exercise for this screen: history does not change
    /// while the workout runs, and defaults are recomputed on every rebuild.
    private func previousPerformance(for step: Step) -> PreviousPerformance? {
        if let cached = previousByStep[step.id] { return cached }
        let previous = session.previousPerformance(for: step)
        previousByStep[step.id] = previous
        return previous
    }

    private func previousText(for step: Step) -> String? {
        if let cached = previousTextByStep[step.id] { return cached }
        let text = tracksReps(step)
            ? session.previousPerformance(for: step).map { previous in
                [ProgressionPresentation.previousText(previous), ProgressionPresentation.previousRIRText(previous)]
                    .compactMap { $0 }.joined(separator: " · ")
            }
            : session.lastTimedPerformance(for: step).map(ProgressionPresentation.previousText)
        previousTextByStep[step.id] = text
        return text
    }

    /// Same rule as the Runner: timed or cardio movements take no load;
    /// custom / unknown exercises do.
    private func acceptsWeight(_ step: Step) -> Bool {
        guard let id = step.exerciseId, let exercise = ExerciseLibrary.exercise(for: ExerciseID(rawValue: id)) else { return true }
        return !exercise.isDurationBased && exercise.movementPattern != .cardio
    }

    private func weight(_ kg: Double?, step: Step) -> Double? {
        acceptsWeight(step) ? kg : nil
    }

    /// Same rule as the Runner: a timed movement records no rep count.
    private func tracksReps(_ step: Step) -> Bool {
        WorkoutSetSemantics.countsReps(exerciseId: step.exerciseId)
    }

    private func reps(_ value: Int, step: Step) -> Int? {
        tracksReps(step) ? value : nil
    }
}
