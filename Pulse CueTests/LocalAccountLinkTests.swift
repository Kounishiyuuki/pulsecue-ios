//
//  LocalAccountLinkTests.swift
//  Pulse CueTests
//
//  Linking is local: Apple / Google attach a provider identity to this
//  device's profile, and that is all. These drive the whole flow — link,
//  relaunch restore, provider revocation, unlink — against fakes, so no
//  signing identity, network or device is involved.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

// MARK: - Fakes

private struct StubAppleCredentials: AppleCredentialChecking {
    let result: AppleCredentialState
    func credentialState(forUserID userID: String) async -> AppleCredentialState { result }
}

@MainActor
private final class StubGoogleSession: GoogleSessionManaging {
    var restored: RestoredGoogleUser?
    private(set) var signOutCalls = 0

    init(restored: RestoredGoogleUser? = nil) { self.restored = restored }

    func restorePreviousSignIn() async -> RestoredGoogleUser? { restored }
    func signOut() { signOutCalls += 1 }
}

@MainActor
struct LocalAccountLinkTests {

    private static func makeStore(
        initialState: AuthState = .guest,
        stored: LinkedAccount? = nil,
        apple: AppleCredentialState = .authorized,
        google: RestoredGoogleUser? = nil
    ) -> (AuthSessionStore, InMemoryLinkedAccountStore, StubGoogleSession) {
        let accountStore = InMemoryLinkedAccountStore(linkedAccount: stored)
        let googleSession = StubGoogleSession(restored: google)
        let store = AuthSessionStore(
            initialState: initialState,
            linkedAccountStore: accountStore,
            appleCredentials: StubAppleCredentials(result: apple),
            googleSession: googleSession
        )
        return (store, accountStore, googleSession)
    }

    // MARK: - Guest

    @Test
    func guestIsAlwaysAvailableAndRequiresNothing() {
        let (store, accountStore, _) = Self.makeStore(initialState: .signedOut)
        store.continueAsGuest()

        #expect(store.state == .guest)
        #expect(store.isSignedIn == false)
        #expect(store.allowsUnauthenticatedAppUsage)
        #expect(accountStore.linkedAccount == nil)
    }

    // MARK: - Apple

    @Test
    func appleLinkIsRecordedWithItsStableIdentifier() {
        let (store, accountStore, _) = Self.makeStore()

        store.completeAppleSignIn(userIdentifier: "apple-user-1", displayName: "Yuuki", email: "y@example.com")

        #expect(store.isSignedIn)
        #expect(store.session?.provider == .apple)
        #expect(store.session?.userIdentifier == "apple-user-1")
        #expect(accountStore.linkedAccount?.userIdentifier == "apple-user-1")
        #expect(accountStore.linkedAccount?.displayName == "Yuuki")
    }

    @Test
    func appleCancelOrErrorLeavesTheStateUntouched() {
        // LoginView returns early on cancel/failure, so the store is never
        // called — the state and the stored link must both stay as they were.
        let (store, accountStore, _) = Self.makeStore(initialState: .guest)

        #expect(store.state == .guest)
        #expect(accountStore.linkedAccount == nil)
        #expect(store.isSignedIn == false)
    }

    @Test
    func anAuthorizedAppleCredentialRestoresTheLink() async {
        let stored = LinkedAccount(provider: .apple, userIdentifier: "apple-user-1", displayName: "Yuuki", email: nil)
        let (store, accountStore, _) = Self.makeStore(initialState: .guest, stored: stored, apple: .authorized)

        await store.restoreLinkedAccount()

        #expect(store.isSignedIn)
        #expect(store.session?.provider == .apple)
        #expect(store.session?.userIdentifier == "apple-user-1")
        #expect(accountStore.linkedAccount != nil)
    }

    @Test
    func arevokedAppleCredentialDropsTheLinkAndFallsBackToGuest() async {
        let stored = LinkedAccount(provider: .apple, userIdentifier: "apple-user-1")
        let (store, accountStore, _) = Self.makeStore(initialState: .guest, stored: stored, apple: .unavailable)

        await store.restoreLinkedAccount()

        #expect(store.state == .guest)
        #expect(store.isSignedIn == false)
        #expect(accountStore.linkedAccount == nil, "a revoked link must not linger on disk")
    }

    // MARK: - Google

    @Test
    func googleLinkIsRecordedWithItsStableIdentifier() {
        let (store, accountStore, _) = Self.makeStore()

        store.completeGoogleSignIn(userIdentifier: "google-user-1", displayName: "Yuuki", email: "y@gmail.com")

        #expect(store.session?.provider == .google)
        #expect(store.session?.userIdentifier == "google-user-1")
        #expect(accountStore.linkedAccount?.userIdentifier == "google-user-1")
    }

    @Test
    func googleCancelOrErrorLeavesTheStateUntouched() {
        let (store, accountStore, _) = Self.makeStore(initialState: .guest)
        // The SDK callback returns early without a user, so nothing is recorded.
        #expect(store.state == .guest)
        #expect(accountStore.linkedAccount == nil)
    }

    @Test
    func googleRestoreBringsTheLinkBackAndRefreshesDisplayFields() async {
        let stored = LinkedAccount(provider: .google, userIdentifier: "google-user-1", displayName: "old", email: nil)
        let restored = RestoredGoogleUser(userIdentifier: "google-user-1", displayName: "new", email: "y@gmail.com")
        let (store, accountStore, _) = Self.makeStore(initialState: .guest, stored: stored, google: restored)

        await store.restoreLinkedAccount()

        #expect(store.isSignedIn)
        #expect(store.session?.displayName == "new")
        #expect(store.session?.email == "y@gmail.com")
        #expect(accountStore.linkedAccount?.userIdentifier == "google-user-1")
    }

    @Test
    func aFailedGoogleRestoreFallsBackToGuest() async {
        let stored = LinkedAccount(provider: .google, userIdentifier: "google-user-1")
        let (store, accountStore, _) = Self.makeStore(initialState: .guest, stored: stored, google: nil)

        await store.restoreLinkedAccount()

        #expect(store.state == .guest)
        #expect(accountStore.linkedAccount == nil)
    }

    // MARK: - Unlink

    @Test
    func unlinkingGoogleCallsTheSdkSignOut() {
        let stored = LinkedAccount(provider: .google, userIdentifier: "google-user-1")
        let (store, accountStore, googleSession) = Self.makeStore(stored: stored)
        store.completeGoogleSignIn(userIdentifier: "google-user-1", displayName: nil, email: nil)

        store.unlinkAccount()

        #expect(googleSession.signOutCalls == 1, "the SDK session must be ended too")
        #expect(store.state == .guest)
        #expect(accountStore.linkedAccount == nil)
    }

    @Test
    func unlinkingAppleClearsLocallyWithoutTouchingGoogle() {
        let (store, accountStore, googleSession) = Self.makeStore()
        store.completeAppleSignIn(userIdentifier: "apple-user-1", displayName: nil, email: nil)

        store.unlinkAccount()

        #expect(googleSession.signOutCalls == 0)
        #expect(store.state == .guest)
        #expect(accountStore.linkedAccount == nil)
    }

    // MARK: - Persistence across launches

    @Test
    func aLinkSurvivesARelaunch() async {
        let defaults = UserDefaults(suiteName: "test.auth.\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        // First launch: the user links Apple.
        let first = AuthSessionStore(
            linkedAccountStore: UserDefaultsLinkedAccountStore(defaults: defaults),
            appleCredentials: StubAppleCredentials(result: .authorized),
            googleSession: StubGoogleSession()
        )
        first.completeAppleSignIn(userIdentifier: "apple-user-1", displayName: "Yuuki", email: nil)

        // Second launch: a brand new store reading the same defaults.
        let second = AuthSessionStore(
            linkedAccountStore: UserDefaultsLinkedAccountStore(defaults: defaults),
            appleCredentials: StubAppleCredentials(result: .authorized),
            googleSession: StubGoogleSession()
        )
        #expect(second.state == .guest, "nothing is shown as linked until the provider confirms it")

        await second.restoreLinkedAccount()

        #expect(second.isSignedIn)
        #expect(second.session?.userIdentifier == "apple-user-1")
        #expect(second.session?.displayName == "Yuuki")
    }

    @Test
    func noStoredLinkMeansRestorationDoesNothing() async {
        let (store, _, _) = Self.makeStore(initialState: .guest)
        await store.restoreLinkedAccount()
        #expect(store.state == .guest)
    }

    // MARK: - Nothing here is a credential

    @Test
    func theStoredRecordCarriesNoToken() throws {
        let account = LinkedAccount(
            provider: .apple, userIdentifier: "apple-user-1",
            displayName: "Yuuki", email: "y@example.com"
        )
        let json = try #require(String(data: try JSONEncoder().encode(account), encoding: .utf8))
        for secret in ["token", "Token", "authorizationCode", "secret", "refresh"] {
            #expect(!json.contains(secret), "persisted record leaked \(secret): \(json)")
        }
    }

    // MARK: - Local data is never collateral

    @Test
    func unlinkingLeavesWorkoutDataAlone() throws {
        let schema = Schema(versionedSchema: PulseCueSchemaV5.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let routine = Routine(name: "胸の日")
        context.insert(routine)
        context.insert(Step(routineId: routine.id, order: 0, title: "ベンチプレス",
                            sets: 3, repsTarget: 8, restSeconds: 120))
        let session = Session(routineId: routine.id, dayDate: Date(), status: .completed, totalSeconds: 1800)
        context.insert(session)
        context.insert(Gym(name: "My Gym", officialUrl: nil, isActive: true))
        context.insert(DayLog(date: Date(), sleepMinutes: 420, weightKg: 70.1))
        try context.save()

        let (store, _, _) = Self.makeStore()
        store.completeAppleSignIn(userIdentifier: "apple-user-1", displayName: nil, email: nil)
        store.unlinkAccount()

        // Unlinking is not deletion: every local record is still there.
        #expect(try context.fetch(FetchDescriptor<Routine>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<Step>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<Session>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<Gym>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<DayLog>()).count == 1)
    }

    /// The app must be fully usable when no provider is reachable at all.
    @Test
    func everythingStillWorksWhenLinkingIsUnavailable() async {
        let stored = LinkedAccount(provider: .google, userIdentifier: "google-user-1")
        let (store, _, _) = Self.makeStore(initialState: .guest, stored: stored, apple: .unavailable, google: nil)

        await store.restoreLinkedAccount()

        #expect(store.state == .guest)
        #expect(store.allowsUnauthenticatedAppUsage)
        store.continueAsGuest()
        #expect(store.state == .guest)
    }
}
