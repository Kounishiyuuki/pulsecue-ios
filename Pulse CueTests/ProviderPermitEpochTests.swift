//
//  ProviderPermitEpochTests.swift
//  Pulse CueTests
//
//  A provider sheet is not part of this app.
//
//  It belongs to Apple or Google, it can stay on screen indefinitely, and
//  PulseCue keeps running underneath it — so "sign out" or "delete my account"
//  can start *and finish* while an authorization is still open. What arrives
//  afterwards is a valid credential for an account the user has just left.
//
//  The failure that follows is the worst kind, because it is silent and it
//  runs backwards: the callback finds an empty Keychain (the logout emptied
//  it), exchanges the credential, gets a fresh session, and the user is signed
//  back in seconds after asking not to be. Nothing errored. Every individual
//  step behaved.
//
//  So every test here is the same shape — park the provider callback, run an
//  authoritative operation to completion, then release the callback — and
//  asserts the same thing: **the stale flow reaches nothing**. Zero backend
//  exchanges, zero Keychain writes, zero local links, and a state that still
//  says what the newer operation decided.
//
//  The parking is a real handshake, never a `Task.yield()` or a sleep. A
//  yielded task has been *offered* the scheduler, not proven to have arrived
//  anywhere; a test built on one asserts a hope and passes for the wrong
//  reason on a fast machine.
//

import XCTest
@testable import Pulse_Cue

// MARK: - Doubles

/// An authorizer that parks inside the provider callback until released.
///
/// This is the provider sheet: open, waiting on a human, with the app free to
/// do anything else meanwhile.
@MainActor
private final class ParkingAuthorizer<Value> {
    private(set) var invocations = 0
    var outcome: ProviderAuthorizationOutcome<Value>

    private var entered: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var release: CheckedContinuation<Void, Never>?
    private var released = false

    init(outcome: ProviderAuthorizationOutcome<Value>) {
        self.outcome = outcome
    }

    func run() async -> ProviderAuthorizationOutcome<Value> {
        invocations += 1
        hasEntered = true
        entered?.resume()
        entered = nil

        if !released {
            await withCheckedContinuation { continuation in
                self.release = continuation
            }
        }
        return outcome
    }

    /// Returns once the sheet is provably open.
    func waitUntilPresented() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            self.entered = continuation
        }
    }

    /// The user finally finishes with the sheet.
    func finish() {
        released = true
        release?.resume()
        release = nil
    }
}

@MainActor
private final class ParkingAppleAuthorizer: AppleAuthorizing {
    let parking: ParkingAuthorizer<AppleAuthorization>

    init() {
        parking = ParkingAuthorizer(
            outcome: .authorized(
                AppleAuthorization(
                    identityToken: "apple-identity-token",
                    authorizationCode: "apple-authorization-code",
                    rawNonce: "raw-nonce",
                    providerUserID: "apple-user",
                    displayName: "Apple User",
                    email: "apple@example.com"
                )
            )
        )
    }

    func authorize() async -> ProviderAuthorizationOutcome<AppleAuthorization> {
        await parking.run()
    }
}

@MainActor
private final class ParkingGoogleAuthorizer: GoogleAuthorizing {
    let parking: ParkingAuthorizer<GoogleAuthorization>

    init() {
        parking = ParkingAuthorizer(
            outcome: .authorized(
                GoogleAuthorization(
                    idToken: "google-id-token",
                    providerUserID: "google-user",
                    displayName: "Google User",
                    email: "google@example.com"
                )
            )
        )
    }

    func authorize() async -> ProviderAuthorizationOutcome<GoogleAuthorization> {
        await parking.run()
    }
}

@MainActor
private final class LinkSpy {
    private(set) var recorded: [LinkedAccount] = []
    func record(_ account: LinkedAccount) { recorded.append(account) }
}

/// Counts SDK sign-outs, and lets a test read who currently owns the session.
///
/// Wrapping the real ownership type rather than replacing it: the guard being
/// tested lives inside `GoogleSDKSessionOwnership`, so a double that
/// reimplemented it would prove nothing.
@MainActor
private final class GoogleSDKSignOutSpy {
    private(set) var signOutCount = 0
    private(set) lazy var ownership = GoogleSDKSessionOwnership(
        signOutSDK: { [weak self] in self?.signOutCount += 1 }
    )

    var owner: ProviderSignInPermit? { ownership.owner }
}

// MARK: - Fixtures

private func epochSession(token: String) -> ServerSessionResponse {
    ServerSessionResponse(
        sessionToken: token,
        expiresAt: 1_800_000_000,
        user: .init(id: "user-1", created: false)
    )
}

private func epochProfile(state: String = "active") -> ServerAccountProfile {
    ServerAccountProfile(
        user: .init(id: "user-1", state: state, displayName: "テスト", createdAt: 1),
        linkedProviders: [.init(provider: "apple", linkedAt: 1)],
        session: .init(expiresAt: 1_800_000_000)
    )
}

@MainActor
private struct Rig {
    let account: ServerAccountStore
    let coordinator: ProviderSignInCoordinator
    let apple: ParkingAppleAuthorizer
    let google: ParkingGoogleAuthorizer
    let api: ControllableAccountAPI
    let tokens: InMemoryServerSessionTokenStore
    let links: LinkSpy
    let googleSDK: GoogleSDKSignOutSpy

    /// Backend sign-in exchanges, of either kind.
    ///
    /// The number that matters: a stale flow must never reach the server at
    /// all, because a server that answers has already minted a session.
    var backendExchanges: Int {
        api.appleSignInCount + api.googleSignInCount
    }
}

/// Opens a provider sheet and returns once it is provably on screen.
///
/// The Keychain must be empty for the permit to be granted at all — that is
/// the earlier gate, and it is working. What these tests are about is what
/// happens *after* the sheet is up, so the session they later revoke is
/// planted while it is open, which is also how it happens in practice: the
/// app keeps running underneath a sheet it does not own.
@MainActor
private func makeRig() -> Rig {
    let api = ControllableAccountAPI()
    api.appleResult = .success(epochSession(token: "session-from-stale-apple"))
    api.googleResult = .success(epochSession(token: "session-from-stale-google"))
    api.profileResult = .success(epochProfile())

    let tokens = InMemoryServerSessionTokenStore()
    let account = ServerAccountStore(api: api, tokenStore: tokens, deviceName: "iPhone")
    let apple = ParkingAppleAuthorizer()
    let google = ParkingGoogleAuthorizer()
    let links = LinkSpy()
    let googleSDK = GoogleSDKSignOutSpy()
    let coordinator = ProviderSignInCoordinator(
        account: account,
        apple: apple,
        google: google,
        googleConfigurationIsUsable: { true },
        recordLink: { links.record($0) },
        googleSDKSession: googleSDK.ownership
    )
    return Rig(
        account: account,
        coordinator: coordinator,
        apple: apple,
        google: google,
        api: api,
        tokens: tokens,
        links: links,
        googleSDK: googleSDK
    )
}

// MARK: - Logout during an open sheet

@MainActor
final class ProviderFlowLogoutRaceTests: XCTestCase {

    func testAStaleAppleCallbackCannotResurrectASignedOutSession() async {
        let rig = makeRig()

        let signIn = Task { await rig.coordinator.signInWithApple() }
        // Wait for a permit to exist and the sheet to actually be open — not
        // for "probably by now".
        await rig.apple.parking.waitUntilPresented()

        // A session lands while the sheet is open. This is what makes the
        // logout below meaningful — and it is the state the stale callback
        // would otherwise overwrite.
        rig.tokens.setTokenForTesting("session-being-signed-out")

        let logout = await rig.account.logout()
        XCTAssertEqual(logout, .signedOut)
        XCTAssertNil(rig.tokens.storedToken, "the logout emptied the Keychain")

        // Only now does the user finish with Apple's sheet.
        rig.apple.parking.finish()
        let outcome = await signIn.value

        XCTAssertEqual(outcome, .refused(.superseded))
        XCTAssertEqual(rig.backendExchanges, 0, "no credential may be exchanged")
        XCTAssertNil(rig.tokens.storedToken, "no session may be written")
        XCTAssertTrue(rig.links.recorded.isEmpty)
        XCTAssertEqual(rig.account.state, .guest, "the user stays signed out")
        XCTAssertFalse(rig.account.state.isAuthenticated)
    }

    func testAStaleGoogleCallbackCannotResurrectASignedOutSession() async {
        let rig = makeRig()

        let signIn = Task { await rig.coordinator.signInWithGoogle() }
        await rig.google.parking.waitUntilPresented()
        // A session lands while the sheet is open. This is what makes the
        // logout below meaningful — and it is the state the stale callback
        // would otherwise overwrite.
        rig.tokens.setTokenForTesting("session-being-signed-out")

        _ = await rig.account.logout()

        rig.google.parking.finish()
        let outcome = await signIn.value

        XCTAssertEqual(outcome, .refused(.superseded))
        XCTAssertEqual(rig.backendExchanges, 0)
        XCTAssertNil(rig.tokens.storedToken)
        XCTAssertTrue(rig.links.recorded.isEmpty)
        XCTAssertEqual(rig.account.state, .guest)
    }

    func testAStaleGoogleCallbackSignsOutOfTheGoogleSDK() async {
        // Stopping the backend exchange is not the whole job for Google. By
        // the time the callback returns, the SDK has already switched the
        // device's selected account — so without this, PulseCue is signed out
        // while the phone quietly points at the Google account it was about to
        // use. Ownership has to end up in one place.
        let rig = makeRig()

        let signIn = Task { await rig.coordinator.signInWithGoogle() }
        await rig.google.parking.waitUntilPresented()
        rig.tokens.setTokenForTesting("session-being-signed-out")
        _ = await rig.account.logout()
        rig.google.parking.finish()
        _ = await signIn.value

        XCTAssertEqual(rig.googleSDK.signOutCount, 1)
    }

    func testAStaleAppleCallbackDoesNotFakeAProviderSignOut() async {
        // Apple has no equivalent client-side session to put back, so there is
        // nothing to undo and inventing a sign-out would be a state change the
        // authorization never made.
        let rig = makeRig()

        let signIn = Task { await rig.coordinator.signInWithApple() }
        await rig.apple.parking.waitUntilPresented()
        rig.tokens.setTokenForTesting("session-being-signed-out")
        _ = await rig.account.logout()
        rig.apple.parking.finish()
        _ = await signIn.value

        XCTAssertEqual(rig.googleSDK.signOutCount, 0)
    }
}

// MARK: - Deletion during an open sheet

@MainActor
final class ProviderFlowDeletionRaceTests: XCTestCase {

    func testAStaleCallbackCannotCreateASessionForADeletedAccount() async {
        let rig = makeRig()

        let signIn = Task { await rig.coordinator.signInWithGoogle() }
        await rig.google.parking.waitUntilPresented()
        // The account being deleted has to exist for the deletion to mean
        // anything; it lands while the sheet is up.
        rig.tokens.setTokenForTesting("session-being-deleted")

        let deletion = await rig.account.deleteAccount()
        XCTAssertEqual(deletion, .deleted)

        rig.google.parking.finish()
        let outcome = await signIn.value

        XCTAssertEqual(outcome, .refused(.superseded))
        XCTAssertEqual(
            rig.backendExchanges, 0,
            "a new session for a deleted account is the worst outcome here"
        )
        XCTAssertNil(rig.tokens.storedToken)
        XCTAssertTrue(rig.links.recorded.isEmpty)
        XCTAssertEqual(rig.account.state, .guest)
    }

    func testAStaleCallbackDoesNotOverwriteADeletionResult() async {
        let rig = makeRig()

        let signIn = Task { await rig.coordinator.signInWithApple() }
        await rig.apple.parking.waitUntilPresented()
        rig.tokens.setTokenForTesting("session-being-deleted")

        let deletion = await rig.account.deleteAccount()
        rig.apple.parking.finish()
        _ = await signIn.value

        XCTAssertEqual(deletion, .deleted)
        XCTAssertFalse(rig.account.state.isAuthenticated)
    }
}

// MARK: - Restore during an open sheet

@MainActor
final class ProviderFlowRestoreRaceTests: XCTestCase {

    func testAStaleCallbackCannotOverrideARestoreResult() async {
        // A launch restore is authoritative too: it is establishing the
        // session this device actually holds, and a provider flow that started
        // before it must not overwrite the answer.
        let rig = makeRig()

        let signIn = Task { await rig.coordinator.signInWithApple() }
        await rig.apple.parking.waitUntilPresented()
        // The session this device actually holds, discovered by the restore.
        rig.tokens.setTokenForTesting("stored-session")

        await rig.account.restore()
        XCTAssertTrue(rig.account.state.isAuthenticated, "restore is authoritative")

        rig.apple.parking.finish()
        let outcome = await signIn.value

        XCTAssertEqual(outcome, .refused(.superseded))
        XCTAssertEqual(rig.backendExchanges, 0)
        XCTAssertEqual(
            rig.tokens.storedToken, "stored-session",
            "the restored session must not be replaced"
        )
        XCTAssertTrue(rig.links.recorded.isEmpty)
    }

    func testARestoreThatIsTrulyInFlightIsNotStrandedByARefusedSignIn() async {
        // The deterministic version of the earlier test, which awaited the
        // restore before competing with it and so never actually overlapped.
        // Here `/me` is parked, the restore is provably suspended inside it,
        // and the competing sign-in is refused while it hangs.
        let rig = makeRig()
        rig.tokens.setTokenForTesting("stored-session")
        rig.api.gated = ["profile"]

        let restore = Task { await rig.account.restore() }
        await rig.api.waitUntilEntered("profile")
        XCTAssertEqual(rig.account.state, .restoring, "the restore is in flight")

        // Refused before any SDK: a session is already on the device.
        let refused = await rig.coordinator.signInWithApple()
        XCTAssertEqual(refused, .refused(.existingSession))
        XCTAssertEqual(rig.apple.parking.invocations, 0)
        XCTAssertEqual(
            rig.account.state, .restoring,
            "a refusal must not knock the restore off its own operation"
        )

        rig.api.release("profile")
        await restore.value

        XCTAssertTrue(
            rig.account.state.isAuthenticated,
            "the restore must still land: \(rig.account.state)"
        )
    }

    func testTheRestoreRaceIsStableAcrossRepeatedRuns() async {
        for _ in 0..<20 {
            let rig = makeRig()
            rig.tokens.setTokenForTesting("stored-session")
            rig.api.gated = ["profile"]

            let restore = Task { await rig.account.restore() }
            await rig.api.waitUntilEntered("profile")
            let refused = await rig.coordinator.signInWithApple()
            rig.api.release("profile")
            await restore.value

            XCTAssertEqual(refused, .refused(.existingSession))
            XCTAssertTrue(rig.account.state.isAuthenticated)
        }
    }

    func testTheLogoutRaceIsStableAcrossRepeatedRuns() async {
        for _ in 0..<20 {
            let rig = makeRig()

            let signIn = Task { await rig.coordinator.signInWithApple() }
            await rig.apple.parking.waitUntilPresented()
            rig.tokens.setTokenForTesting("session-being-signed-out")
            _ = await rig.account.logout()
            rig.apple.parking.finish()
            let outcome = await signIn.value

            XCTAssertEqual(outcome, .refused(.superseded))
            XCTAssertEqual(rig.backendExchanges, 0)
            XCTAssertNil(rig.tokens.storedToken)
        }
    }
}

// MARK: - Permit identity

@MainActor
final class ProviderPermitIdentityTests: XCTestCase {

    private func permit(
        _ store: ServerAccountStore,
        _ provider: AuthProviderKind
    ) -> ProviderSignInPermit? {
        guard case let .allowed(permit) = store.prepareProviderSignIn(provider: provider) else {
            return nil
        }
        return permit
    }

    func testAnInvalidatedPermitIsNoLongerCurrent() async {
        let rig = makeRig()
        let permitA = permit(rig.account, .apple)
        XCTAssertNotNil(permitA)
        XCTAssertTrue(rig.account.isProviderSignInCurrent(permitA!))

        _ = await rig.account.logout()

        XCTAssertFalse(
            rig.account.isProviderSignInCurrent(permitA!),
            "logout retires outstanding permits"
        )
    }

    func testAnOldPermitCannotRetireANewerOne() async {
        // The ABA case. Permit A is invalidated by a logout, permit B is taken
        // for a fresh sign-in, and only then does A's flow unwind and run its
        // `defer`. A blind `activePermit = nil` there would cancel B — so the
        // user's new sign-in would die on the old one's way out.
        let rig = makeRig()
        let permitA = permit(rig.account, .apple)
        XCTAssertNotNil(permitA)

        _ = await rig.account.logout()

        let permitB = permit(rig.account, .google)
        XCTAssertNotNil(permitB, "a new flow may start after the logout")

        rig.account.finishProviderSignIn(permitA!)

        XCTAssertTrue(
            rig.account.isProviderSignInCurrent(permitB!),
            "the newer permit must survive the older one's release"
        )
    }

    func testANewPermitDoesNotRevalidateAnOldOne() async {
        let rig = makeRig()
        let permitA = permit(rig.account, .apple)
        _ = await rig.account.logout()
        let permitB = permit(rig.account, .google)

        XCTAssertNotNil(permitB)
        XCTAssertFalse(
            rig.account.isProviderSignInCurrent(permitA!),
            "an outstanding permit is not this permit"
        )
    }

    func testAStaleAppleCallbackCannotUseTheStoresSignInDirectly() async {
        // Store-level, below the coordinator: even handed the credential
        // directly, a retired permit reaches no backend.
        let rig = makeRig()
        let permitA = permit(rig.account, .apple)
        _ = await rig.account.logout()

        let signedIn = await rig.account.signInWithApple(
            permit: permitA!,
            identityToken: "t",
            authorizationCode: "c",
            rawNonce: "n"
        )

        XCTAssertFalse(signedIn)
        XCTAssertEqual(rig.backendExchanges, 0)
    }

    func testAnApplePermitCannotCompleteAGoogleSignIn() async {
        // Provider mismatch. The permit authorized one provider's sheet, and
        // a credential from the other one is not what it agreed to.
        let rig = makeRig()
        let applePermit = permit(rig.account, .apple)
        XCTAssertNotNil(applePermit)

        let signedIn = await rig.account.signInWithGoogle(
            permit: applePermit!,
            idToken: "google-id-token"
        )

        XCTAssertFalse(signedIn)
        XCTAssertEqual(rig.backendExchanges, 0)
    }

    func testAGooglePermitCannotCompleteAnAppleSignIn() async {
        let rig = makeRig()
        let googlePermit = permit(rig.account, .google)
        XCTAssertNotNil(googlePermit)

        let signedIn = await rig.account.signInWithApple(
            permit: googlePermit!,
            identityToken: "t",
            authorizationCode: "c",
            rawNonce: "n"
        )

        XCTAssertFalse(signedIn)
        XCTAssertEqual(rig.backendExchanges, 0)
    }

    func testAnUnknownPermitIsRejected() async {
        let rig = makeRig()
        let unknown = ProviderSignInPermit.rejectedPlaceholder(provider: .apple)

        XCTAssertFalse(rig.account.isProviderSignInCurrent(unknown))
        let signedIn = await rig.account.signInWithApple(
            permit: unknown,
            identityToken: "t",
            authorizationCode: "c",
            rawNonce: "n"
        )
        XCTAssertFalse(signedIn)
        XCTAssertEqual(rig.backendExchanges, 0)
    }

    func testAPermitAloneDoesNotConferGoogleSDKOwnership() async {
        // A newer flow that has only *reserved* the slot has not touched the
        // SDK, so it owns nothing yet — and the stale flow must still put back
        // the Google session it really did create. Deferring to the newer
        // permit here would strand the stale flow's account selection with
        // nobody left to undo it.
        //
        // The protection that does matter — a newer flow that has actually
        // authorized — is `testAStaleFlowCannotSignOutACompletedNewerFlow`.
        let rig = makeRig()

        let staleSignIn = Task { await rig.coordinator.signInWithGoogle() }
        await rig.google.parking.waitUntilPresented()
        rig.tokens.setTokenForTesting("session-being-signed-out")
        _ = await rig.account.logout()

        // A newer flow reserves the slot, but never reaches the SDK.
        let newer = rig.account.prepareProviderSignIn(provider: .google)
        guard case .allowed = newer else {
            return XCTFail("a new Google flow should be able to start")
        }

        rig.google.parking.finish()
        _ = await staleSignIn.value

        XCTAssertEqual(
            rig.googleSDK.signOutCount, 1,
            "the stale flow still owns the session it created"
        )
        XCTAssertNil(rig.googleSDK.owner)
    }
}

// MARK: - Google SDK session ownership

//  The distinction these tests exist for:
//
//    the permit  — "is a Google sign-in running?"     ends with the flow
//    ownership   — "whose account is the SDK on?"     outlives the flow
//
//  Reading the first as the second is what let a stale flow's cleanup sign the
//  user out of an account a newer, successful sign-in had just established.
//  Every test below arranges for `activePermit == nil` before the stale
//  cleanup runs, so nothing can pass by accident on permit state.

@MainActor
final class GoogleSDKSessionOwnershipTests: XCTestCase {

    /// Starts a Google flow whose sheet completes immediately and which then
    /// parks inside the named backend call.
    ///
    /// The sheet is finished first on purpose: these tests are about the
    /// window *after* Google's SDK has succeeded — ownership has been claimed,
    /// the device's account has already changed — while PulseCue is still
    /// waiting on the server.
    private func startParkedGoogleFlow(
        _ rig: Rig,
        gate: String
    ) async -> Task<ProviderSignInOutcome, Never> {
        rig.google.parking.finish()
        rig.api.gated = [gate]
        let flow = Task { await rig.coordinator.signInWithGoogle() }
        await rig.api.waitUntilEntered(gate)
        return flow
    }

    func testAFlowOwnsTheSDKSessionAsSoonAsAuthorizationSucceeds() async {
        // Claimed before the backend answers, because the device's account has
        // already changed by then. Waiting for the server would leave a window
        // where the SDK session has no owner and no cleanup can attribute it.
        let rig = makeRig()
        let flow = await startParkedGoogleFlow(rig, gate: "google")

        XCTAssertNotNil(rig.googleSDK.owner, "ownership starts at SDK success")

        rig.api.release("google")
        _ = await flow.value
    }

    func testOwnershipSurvivesTheSuccessfulFlowsPermitRelease() async {
        let rig = makeRig()
        rig.google.parking.finish()

        let outcome = await rig.coordinator.signInWithGoogle()

        XCTAssertEqual(outcome, .signedIn)
        XCTAssertFalse(
            rig.account.isProviderSignInCurrent(rig.googleSDK.owner!),
            "the permit is released once the flow ends"
        )
        XCTAssertNotNil(
            rig.googleSDK.owner,
            "but the SDK session is still owned by the flow that made it"
        )
        XCTAssertEqual(rig.googleSDK.signOutCount, 0)
    }

    func testALogoutDuringTheBackendExchangeCleansUpTheSDKSession() async {
        // PulseCue detects the stale flow and refuses the session — but
        // without this, the device stays signed into the Google account that
        // flow selected, with no PulseCue session to match.
        let rig = makeRig()
        let flow = await startParkedGoogleFlow(rig, gate: "google")

        rig.tokens.setTokenForTesting("session-being-signed-out")
        _ = await rig.account.logout()

        rig.api.release("google")
        let outcome = await flow.value

        XCTAssertEqual(outcome, .refused(.superseded))
        XCTAssertEqual(rig.googleSDK.signOutCount, 1, "the SDK session is put back")
        XCTAssertNil(rig.googleSDK.owner)
        XCTAssertNil(rig.tokens.storedToken)
        XCTAssertTrue(rig.links.recorded.isEmpty)
        XCTAssertFalse(rig.account.state.isAuthenticated)
    }

    func testADeletionDuringTheBackendExchangeCleansUpTheSDKSession() async {
        let rig = makeRig()
        let flow = await startParkedGoogleFlow(rig, gate: "google")

        rig.tokens.setTokenForTesting("session-being-deleted")
        let deletion = await rig.account.deleteAccount()

        rig.api.release("google")
        let outcome = await flow.value

        XCTAssertEqual(deletion, .deleted)
        XCTAssertEqual(outcome, .refused(.superseded))
        XCTAssertEqual(rig.googleSDK.signOutCount, 1)
        XCTAssertNil(rig.googleSDK.owner)
    }

    func testARestoreDuringTheBackendExchangeCleansUpTheSDKSession() async {
        let rig = makeRig()
        let flow = await startParkedGoogleFlow(rig, gate: "google")

        rig.tokens.setTokenForTesting("stored-session")
        await rig.account.restore()

        rig.api.release("google")
        let outcome = await flow.value

        XCTAssertEqual(outcome, .refused(.superseded))
        XCTAssertEqual(rig.googleSDK.signOutCount, 1)
        XCTAssertEqual(
            rig.tokens.storedToken, "stored-session",
            "the restored session is untouched"
        )
    }

    func testALogoutDuringTheProfileFetchCleansUpTheSDKSession() async {
        // The later window: the server has already issued a token, so the
        // existing compensation hands that back — and the Google SDK state
        // this flow created has to go back too.
        let rig = makeRig()
        let flow = await startParkedGoogleFlow(rig, gate: "profile")

        rig.tokens.setTokenForTesting("session-being-signed-out")
        _ = await rig.account.logout()

        rig.api.release("profile")
        let outcome = await flow.value

        XCTAssertEqual(outcome, .refused(.superseded))
        XCTAssertEqual(rig.googleSDK.signOutCount, 1)
        XCTAssertNil(rig.googleSDK.owner)
        XCTAssertNil(rig.tokens.storedToken, "no session is persisted")
        XCTAssertTrue(rig.links.recorded.isEmpty)
        XCTAssertFalse(rig.account.state.isAuthenticated)
        XCTAssertTrue(
            rig.api.logoutTokens.contains("session-from-stale-google"),
            "the orphaned server session is handed back"
        )
    }

    func testAStaleFlowCannotSignOutACompletedNewerFlow() async {
        // The ABA case, and the reason ownership is tracked at all.
        //
        // A is parked in the backend and retired. B then runs to completion
        // and *releases its permit*, so `activePermit` is nil — the state in
        // which the old `hasActiveProviderSignIn` check answered "nobody owns
        // the Google session" and signed the user out of B's account.
        let rig = makeRig()
        let flowA = await startParkedGoogleFlow(rig, gate: "google")

        rig.tokens.setTokenForTesting("session-being-signed-out")
        _ = await rig.account.logout()

        // B runs on an ungated backend and finishes completely.
        rig.api.gated = []
        rig.google.parking.finish()
        let outcomeB = await rig.coordinator.signInWithGoogle()
        XCTAssertEqual(outcomeB, .signedIn)

        let ownerAfterB = rig.googleSDK.owner
        XCTAssertNotNil(ownerAfterB)
        XCTAssertFalse(
            rig.account.isProviderSignInCurrent(ownerAfterB!),
            "B's permit must already be released for this test to mean anything"
        )
        let signOutsBeforeA = rig.googleSDK.signOutCount

        // Only now does A unwind.
        rig.api.release("google")
        let outcomeA = await flowA.value

        XCTAssertEqual(outcomeA, .refused(.superseded))
        XCTAssertEqual(
            rig.googleSDK.signOutCount, signOutsBeforeA,
            "A must not sign out the session B established"
        )
        XCTAssertEqual(rig.googleSDK.owner, ownerAfterB, "B still owns it")
        XCTAssertEqual(rig.tokens.storedToken, "session-from-stale-google")
        XCTAssertTrue(rig.account.state.isAuthenticated)
        XCTAssertEqual(rig.links.recorded.count, 1, "only B recorded a link")
    }

    func testTheABARaceIsStableAcrossRepeatedRuns() async {
        for _ in 0..<20 {
            let rig = makeRig()
            // A's sheet completes at once; A then parks in the backend.
            rig.google.parking.finish()
            rig.api.gated = ["google"]
            let flowA = Task { await rig.coordinator.signInWithGoogle() }
            await rig.api.waitUntilEntered("google")

            rig.tokens.setTokenForTesting("session-being-signed-out")
            _ = await rig.account.logout()

            rig.api.gated = []
            rig.google.parking.finish()
            _ = await rig.coordinator.signInWithGoogle()
            let ownerAfterB = rig.googleSDK.owner
            let signOutsBeforeA = rig.googleSDK.signOutCount

            rig.api.release("google")
            _ = await flowA.value

            XCTAssertEqual(rig.googleSDK.signOutCount, signOutsBeforeA)
            XCTAssertEqual(rig.googleSDK.owner, ownerAfterB)
            XCTAssertTrue(rig.account.state.isAuthenticated)
        }
    }

    func testAServerRefusalCleansUpTheSDKSessionExactlyOnce() async {
        // Not a race: the server simply said no. The device's Google account
        // still changed, so it is put back.
        let rig = makeRig()
        rig.google.parking.finish()
        rig.api.googleResult = .failure(AccountAPIError.invalidCredentials)

        let outcome = await rig.coordinator.signInWithGoogle()

        XCTAssertEqual(outcome, .refused(.serverRefused))
        XCTAssertEqual(rig.googleSDK.signOutCount, 1)
        XCTAssertNil(rig.googleSDK.owner)
        XCTAssertTrue(rig.links.recorded.isEmpty)
        XCTAssertFalse(rig.account.state.isAuthenticated)
    }

    func testAFailingFlowDoesNotCleanUpAfterOwnershipMovedOn() async {
        // A fails late, but B already owns the SDK session by then.
        let rig = makeRig()
        let flowA = await startParkedGoogleFlow(rig, gate: "google")

        rig.tokens.setTokenForTesting("session-being-signed-out")
        _ = await rig.account.logout()

        rig.api.gated = []
        rig.google.parking.finish()
        _ = await rig.coordinator.signInWithGoogle()
        let ownerAfterB = rig.googleSDK.owner
        let signOutsBeforeA = rig.googleSDK.signOutCount

        // A's backend call now fails outright rather than being superseded.
        rig.api.googleResult = .failure(AccountAPIError.invalidCredentials)
        rig.api.release("google")
        _ = await flowA.value

        XCTAssertEqual(rig.googleSDK.signOutCount, signOutsBeforeA)
        XCTAssertEqual(rig.googleSDK.owner, ownerAfterB)
    }

    func testAnOldFlowsPermitReleaseDoesNotDisturbTheNewerOwner() async {
        let rig = makeRig()
        let flowA = await startParkedGoogleFlow(rig, gate: "google")

        rig.tokens.setTokenForTesting("session-being-signed-out")
        _ = await rig.account.logout()

        rig.api.gated = []
        rig.google.parking.finish()
        _ = await rig.coordinator.signInWithGoogle()
        let ownerAfterB = rig.googleSDK.owner

        rig.api.release("google")
        _ = await flowA.value

        // A's `defer` has now run both its cleanup and its permit release.
        XCTAssertEqual(rig.googleSDK.owner, ownerAfterB)
        XCTAssertTrue(rig.account.state.isAuthenticated)
        XCTAssertEqual(rig.tokens.storedToken, "session-from-stale-google")
    }

    func testAnAppleFlowNeverClaimsGoogleSDKOwnership() async {
        // Apple has no persistent client-side session to own, and inventing
        // one would mean inventing sign-outs to match.
        let rig = makeRig()
        rig.apple.parking.finish()
        rig.api.appleResult = .failure(AccountAPIError.invalidCredentials)

        _ = await rig.coordinator.signInWithApple()

        XCTAssertNil(rig.googleSDK.owner)
        XCTAssertEqual(rig.googleSDK.signOutCount, 0)
    }
}
