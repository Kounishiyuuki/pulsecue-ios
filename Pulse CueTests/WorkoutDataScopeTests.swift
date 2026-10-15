//
//  WorkoutDataScopeTests.swift
//  Pulse CueTests
//
//  The scope policy on its own: given an account state, whose data is this.
//
//  Kept separate from the wiring tests because this is the part that is easy
//  to get subtly wrong and impossible to see going wrong — a state resolving
//  to `.guest` when it should resolve to "not known yet" does not crash, it
//  shows somebody the wrong history for a moment.
//

import Foundation
import Security
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct WorkoutDataScopeTests {

    private static func profile(id: String) -> ServerAccountProfile {
        ServerAccountProfile(
            user: .init(id: id, state: "active", displayName: nil, createdAt: 0),
            linkedProviders: [],
            session: .init(expiresAt: 0)
        )
    }

    // MARK: - matches

    @Test("Guest scope matches unowned rows and nothing else")
    func guestMatchesOnlyUnowned() {
        let a = UUID()
        #expect(WorkoutDataScope.guest.matches(ownerAccountID: nil))
        #expect(!WorkoutDataScope.guest.matches(ownerAccountID: a))
    }

    @Test("Account scope matches its own rows and nothing else")
    func accountMatchesOnlyItsOwn() {
        let a = UUID()
        let b = UUID()
        let scope = WorkoutDataScope.account(a)
        #expect(scope.matches(ownerAccountID: a))
        #expect(!scope.matches(ownerAccountID: b))
        #expect(!scope.matches(ownerAccountID: nil))
    }

    @Test("An undetermined scope matches nothing at all")
    func undeterminedMatchesNothing() {
        let scope = WorkoutDataScope.undetermined
        #expect(!scope.matches(ownerAccountID: nil))
        #expect(!scope.matches(ownerAccountID: UUID()))
        #expect(!scope.canCreateWorkouts)
        #expect(scope.syncAccountID == nil)
    }

    @Test("Guest data is never sync-eligible")
    func guestIsNotSyncEligible() {
        #expect(WorkoutDataScope.guest.syncAccountID == nil)
        #expect(WorkoutDataScope.guest.creationOwnerAccountID == nil)
        #expect(WorkoutDataScope.guest.canCreateWorkouts)
    }

    // MARK: - resolve

    @Test("No session resolves to guest")
    func guestStateResolvesToGuest() {
        #expect(WorkoutDataScope.resolve(state: .guest, lastConfirmedAccountID: nil) == .guest)
        // Even with a remembered account: an explicit sign-out is a fact, and
        // the remembered id is cleared when it happens.
        #expect(WorkoutDataScope.resolve(state: .guest, lastConfirmedAccountID: UUID()) == .guest)
    }

    @Test("A build without the account API is guest, not undetermined")
    func notConfiguredResolvesToGuest() {
        #expect(
            WorkoutDataScope.resolve(state: .notConfigured, lastConfirmedAccountID: nil) == .guest
        )
    }

    @Test("A confirmed account resolves to that account")
    func authenticatedResolvesToTheAccount() {
        let id = UUID()
        let scope = WorkoutDataScope.resolve(
            state: .authenticated(Self.profile(id: id.uuidString)),
            lastConfirmedAccountID: nil
        )
        #expect(scope == .account(id))
    }

    @Test("An account id that is not a UUID fails closed, never to guest")
    func unreadableAccountIdFailsClosed() {
        let scope = WorkoutDataScope.resolve(
            state: .authenticated(Self.profile(id: "not-a-uuid")),
            lastConfirmedAccountID: nil
        )
        // Guest here would hand an authenticated user a different data set and
        // make everything they recorded next unsyncable.
        #expect(scope == .undetermined)
        #expect(!scope.canCreateWorkouts)
    }

    @Test("A stale remembered id does not rescue an unreadable account id")
    func unreadableAccountIdIgnoresTheRememberedAccount() {
        let scope = WorkoutDataScope.resolve(
            state: .authenticated(Self.profile(id: "not-a-uuid")),
            lastConfirmedAccountID: UUID()
        )
        #expect(scope == .undetermined)
    }

    @Test("Offline with a known account stays in that account's scope")
    func unreachableUsesTheLastConfirmedAccount() {
        let id = UUID()
        #expect(
            WorkoutDataScope.resolve(state: .unreachable, lastConfirmedAccountID: id)
                == .account(id)
        )
    }

    @Test("Offline with no known account shows nothing rather than guessing")
    func unreachableWithoutAMemoryIsUndetermined() {
        #expect(
            WorkoutDataScope.resolve(state: .unreachable, lastConfirmedAccountID: nil)
                == .undetermined
        )
    }

    @Test("While confirming a session, the scope is not knowable")
    func transientStatesAreUndetermined() {
        for state in [ServerAccountState.unresolved, .restoring, .signingIn, .localCleanupFailed] {
            #expect(
                WorkoutDataScope.resolve(state: state, lastConfirmedAccountID: UUID())
                    == .undetermined,
                "\(state) must not resolve to a scope"
            )
        }
    }
}

// MARK: - Launch restore wiring

/// The store and resolver together, built in the order the app builds them:
/// store, then resolver, then `restore()`.
///
/// The bug these pin down only exists in that ordering. The store used to
/// start as `.guest`, the resolver read it on creation as a confirmed
/// sign-out, and forgot the cached account before `restore()` had looked —
/// so an offline launch had no account to fall back to.
@MainActor
struct WorkoutDataScopeLaunchRestoreTests {

    private static let accountA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private static let accountB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

    private struct Rig {
        let api: StubAccountAPI
        let tokens: InMemoryServerSessionTokenStore
        let defaults: UserDefaults
        let store: ServerAccountStore
        let resolver: WorkoutDataScopeResolver

        @MainActor var cachedAccountID: String? {
            defaults.string(forKey: WorkoutDataScopeResolver.lastConfirmedAccountKey)
        }
    }

    private static func profile(_ id: UUID) -> ServerAccountProfile {
        ServerAccountProfile(
            user: .init(id: id.uuidString, state: "active", displayName: nil, createdAt: 0),
            linkedProviders: [],
            session: .init(expiresAt: 1_800_000_000)
        )
    }

    private static func makeRig(
        cached: UUID?,
        token: String?,
        configure: (StubAccountAPI, InMemoryServerSessionTokenStore) -> Void = { _, _ in }
    ) -> Rig {
        let defaults = UserDefaults(suiteName: "WorkoutDataScopeLaunchRestoreTests.\(UUID().uuidString)")!
        if let cached {
            defaults.set(cached.uuidString, forKey: WorkoutDataScopeResolver.lastConfirmedAccountKey)
        }
        let api = StubAccountAPI()
        let tokens = InMemoryServerSessionTokenStore(token: token)
        configure(api, tokens)
        let store = ServerAccountStore(api: api, tokenStore: tokens)
        let resolver = WorkoutDataScopeResolver(account: store, defaults: defaults)
        return Rig(api: api, tokens: tokens, defaults: defaults, store: store, resolver: resolver)
    }

    /// The resolver hears about state changes on the main run loop, so a
    /// change is not visible to it in the same turn. Waits for that delivery
    /// rather than for a fixed time.
    private static func settle(
        _ rig: Rig,
        until expected: WorkoutDataScope
    ) async {
        for _ in 0..<200 where rig.resolver.scope != expected {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func expectOnly(_ scope: WorkoutDataScope, shows owner: UUID?) {
        for candidate in [nil, accountA, accountB] as [UUID?] {
            #expect(
                scope.matches(ownerAccountID: candidate) == (candidate == owner),
                "\(scope) visibility of \(String(describing: candidate))"
            )
        }
    }

    @Test("Before restore, launch is unresolved: no guest verdict, cache kept, nothing shown")
    func launchStartsUnresolved() {
        let rig = Self.makeRig(cached: Self.accountA, token: "t")
        #expect(rig.store.state == .unresolved)
        #expect(rig.store.state.statusLabel == "アカウントを確認中…")
        #expect(rig.cachedAccountID == Self.accountA.uuidString)
        #expect(rig.resolver.scope == .undetermined)
        #expect(!rig.resolver.scope.matches(ownerAccountID: nil))
        #expect(!rig.resolver.scope.matches(ownerAccountID: Self.accountA))
    }

    @Test("Offline launch with a stored session stays in the cached account's scope")
    func offlineLaunchKeepsAccountScope() async {
        let rig = Self.makeRig(cached: Self.accountA, token: "t") { api, _ in
            api.profileResult = .failure(AccountAPIError.unavailable)
        }
        #expect(rig.cachedAccountID == Self.accountA.uuidString)

        await rig.store.restore()
        await Self.settle(rig, until: .account(Self.accountA))

        #expect(rig.store.state == .unreachable)
        #expect(rig.cachedAccountID == Self.accountA.uuidString)
        #expect(rig.resolver.scope == .account(Self.accountA))
        Self.expectOnly(rig.resolver.scope, shows: Self.accountA)
    }

    @Test("Restore with no stored token is a confirmed guest and forgets the cache")
    func tokenAbsentIsGuest() async {
        let rig = Self.makeRig(cached: Self.accountA, token: nil)
        #expect(rig.cachedAccountID == Self.accountA.uuidString)

        await rig.store.restore()
        await Self.settle(rig, until: .guest)

        #expect(rig.store.state == .guest)
        #expect(rig.cachedAccountID == nil)
        #expect(rig.resolver.scope == .guest)
        Self.expectOnly(rig.resolver.scope, shows: nil)
    }

    @Test("A 401 at restore clears the token and the cache, and lands in guest")
    func invalidSessionIsGuest() async {
        let rig = Self.makeRig(cached: Self.accountA, token: "t") { api, _ in
            api.profileResult = .failure(AccountAPIError.invalidCredentials)
        }

        await rig.store.restore()
        await Self.settle(rig, until: .guest)

        #expect(rig.tokens.storedToken == nil)
        #expect(rig.store.state == .guest)
        #expect(rig.cachedAccountID == nil)
        #expect(rig.resolver.scope == .guest)
    }

    @Test("An unreadable Keychain is unreachable, not guest, and keeps the cached account")
    func keychainUnavailableKeepsAccount() async {
        let rig = Self.makeRig(cached: Self.accountA, token: "t") { _, tokens in
            tokens.readFailure = errSecInteractionNotAllowed
        }

        await rig.store.restore()
        await Self.settle(rig, until: .account(Self.accountA))

        #expect(rig.store.state == .unreachable)
        #expect(rig.cachedAccountID == Self.accountA.uuidString)
        #expect(rig.resolver.scope == .account(Self.accountA))
    }

    @Test("The server-confirmed account replaces whatever was cached")
    func authenticatedRestoreUpdatesCache() async {
        let rig = Self.makeRig(cached: Self.accountA, token: "t") { api, _ in
            api.profileResult = .success(Self.profile(Self.accountB))
        }

        await rig.store.restore()
        await Self.settle(rig, until: .account(Self.accountB))

        #expect(rig.store.state.isAuthenticated)
        #expect(rig.cachedAccountID == Self.accountB.uuidString)
        #expect(rig.resolver.scope == .account(Self.accountB))
        Self.expectOnly(rig.resolver.scope, shows: Self.accountB)
    }

    @Test("Logout forgets the account; a later sign-in caches only the new one")
    func logoutThenSwitchAccount() async {
        let rig = Self.makeRig(cached: nil, token: "t") { api, _ in
            api.profileResult = .success(Self.profile(Self.accountA))
        }
        await rig.store.restore()
        await Self.settle(rig, until: .account(Self.accountA))
        #expect(rig.cachedAccountID == Self.accountA.uuidString)

        await rig.store.logout()
        await Self.settle(rig, until: .guest)
        #expect(rig.store.state == .guest)
        #expect(rig.cachedAccountID == nil)
        #expect(rig.resolver.scope == .guest)

        rig.api.appleResult = .success(
            ServerSessionResponse(
                sessionToken: "t-b",
                expiresAt: 1_800_000_000,
                user: .init(id: Self.accountB.uuidString, created: false)
            )
        )
        rig.api.profileResult = .success(Self.profile(Self.accountB))
        guard case let .allowed(permit) = rig.store.prepareProviderSignIn(provider: .apple) else {
            Issue.record("sign-in was not permitted after logout")
            return
        }
        let signedIn = await rig.store.signInWithApple(
            permit: permit,
            identityToken: "id",
            authorizationCode: "code",
            rawNonce: "nonce"
        )
        rig.store.finishProviderSignIn(permit)
        await Self.settle(rig, until: .account(Self.accountB))

        #expect(signedIn)
        #expect(rig.cachedAccountID == Self.accountB.uuidString)
        #expect(rig.resolver.scope == .account(Self.accountB))
    }

    @Test("A build without the account API stays guest and leaves the cache alone")
    func notConfiguredIsGuest() async {
        let rig = Self.makeRig(cached: Self.accountA, token: nil) { api, _ in
            api.configured = false
        }
        #expect(rig.store.state == .notConfigured)

        await rig.store.restore()

        #expect(rig.store.state == .notConfigured)
        #expect(rig.resolver.scope == .guest)
        #expect(rig.cachedAccountID == Self.accountA.uuidString)
    }

    // MARK: Runner at launch

    @Test("Runner configured before restore resumes nothing, then only the cached account's workout")
    func runnerStartupResumesOnlyCachedAccount() async throws {
        let schema = Schema([Routine.self, Step.self, Session.self, StepResult.self, DayLog.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let routine = Routine(name: "Launch Scope Routine")
        context.insert(routine)
        context.insert(Step(routineId: routine.id, order: 0, title: "Step", sets: 2, repsTarget: 10, restSeconds: 30))
        let guestSession = Session(routineId: routine.id, dayDate: Date(), status: .inProgress)
        let sessionA = Session(routineId: routine.id, dayDate: Date(), status: .inProgress, ownerAccountID: Self.accountA)
        let sessionB = Session(routineId: routine.id, dayDate: Date(), status: .inProgress, ownerAccountID: Self.accountB)
        for session in [guestSession, sessionA, sessionB] { context.insert(session) }
        try context.save()

        // Only the account slots are written. The guest slot is shared with
        // `RunnerRestorationTests`, which may be running alongside this.
        func resumePoint(_ session: Session) -> RunnerPersistentState {
            RunnerPersistentState(
                sessionId: session.id, routineId: routine.id, phase: .exercise,
                stepIndex: 0, setIndex: 0, restDeadline: nil, lastUpdatedAt: Date()
            )
        }
        RunnerPersistence.save(resumePoint(sessionA), scope: .account(Self.accountA))
        RunnerPersistence.save(resumePoint(sessionB), scope: .account(Self.accountB))
        defer {
            RunnerPersistence.clear(scope: .account(Self.accountA))
            RunnerPersistence.clear(scope: .account(Self.accountB))
        }

        let rig = Self.makeRig(cached: Self.accountA, token: "t") { api, _ in
            api.profileResult = .failure(AccountAPIError.unavailable)
        }
        let settings = SettingsStore(defaults: rig.defaults)
        settings.notificationsEnabled = false
        let runner = RunnerViewModel(settings: settings)

        // ContentView's order: configure with the launch scope, then restore.
        runner.configure(modelContext: context, scope: rig.resolver.scope)
        #expect(rig.resolver.scope == .undetermined)
        #expect(runner.sessionId == nil)
        #expect(!runner.shouldPresentRunner)

        await rig.store.restore()
        await Self.settle(rig, until: .account(Self.accountA))
        #expect(rig.store.state == .unreachable)
        runner.applyScope(rig.resolver.scope)

        #expect(runner.sessionId == sessionA.id)
        #expect(runner.sessionId != guestSession.id)
        #expect(runner.sessionId != sessionB.id)
        #expect(runner.shouldPresentRunner)
    }
}
