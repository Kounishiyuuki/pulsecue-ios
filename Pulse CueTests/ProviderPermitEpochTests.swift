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

// MARK: - Google SDK invocation serialization (reverse ABA)

//  The ordering the backend-phase ABA tests above cannot reach.
//
//  There, A had already *finished* with the SDK and was waiting on the
//  network. Here A is still inside `GIDSignIn.signIn` — its callback has not
//  returned — when a logout retires it. If B were allowed to start its own
//  SDK call at that point, B could complete a whole sign-in and *then* A's
//  callback would land, moving the SDK's own account onto A's, behind B's
//  back. No check after the fact can undo that: by the time A's completion
//  handler runs, the SDK's state has already changed.
//
//  So the invariant is checked one step earlier than "was A stale?" — it is
//  that B's SDK call cannot start at all while A's is outstanding.

@MainActor
final class GoogleSDKInvocationLeaseTests: XCTestCase {

    /// A Google authorizer whose callback is held open on demand.
    ///
    /// Models `GIDSignIn.signIn` mid-flight: invoked, sheet up, no callback
    /// yet — the window this whole suite is about.
    @MainActor
    private final class GatedGoogleAuthorizer: GoogleAuthorizing {
        private(set) var invocations = 0
        private var entered: CheckedContinuation<Void, Never>?
        private var hasEntered = false
        private var release: CheckedContinuation<Void, Never>?
        private var released = false

        func authorize() async -> ProviderAuthorizationOutcome<GoogleAuthorization> {
            invocations += 1
            hasEntered = true
            entered?.resume()
            entered = nil
            // Only the *first* call parks. A second one is the thing these
            // tests forbid, so it must return rather than hang: a deadlocked
            // suite is a much worse signal than a failed assertion when
            // someone removes the serialization.
            if invocations == 1, !released {
                await withCheckedContinuation { self.release = $0 }
            }
            return .authorized(
                GoogleAuthorization(
                    idToken: "google-id-token",
                    providerUserID: "google-user",
                    displayName: nil,
                    email: nil
                )
            )
        }

        func waitUntilInvoked() async {
            guard !hasEntered else { return }
            await withCheckedContinuation { self.entered = $0 }
        }

        func completeCallback() {
            released = true
            release?.resume()
            release = nil
        }

    }

    private struct LeaseRig {
        let account: ServerAccountStore
        let coordinator: ProviderSignInCoordinator
        let google: GatedGoogleAuthorizer
        let api: ControllableAccountAPI
        let tokens: InMemoryServerSessionTokenStore
        let signOut: GoogleSDKSignOutSpy
        let lease: ProviderSDKInvocationLease
        let links: LinkSpy
    }

    private func makeLeaseRig() -> LeaseRig {
        let api = ControllableAccountAPI()
        api.googleResult = .success(epochSession(token: "session-from-google"))
        api.profileResult = .success(epochProfile())
        let tokens = InMemoryServerSessionTokenStore()
        let account = ServerAccountStore(api: api, tokenStore: tokens, deviceName: "iPhone")
        let google = GatedGoogleAuthorizer()
        let signOut = GoogleSDKSignOutSpy()
        let lease = ProviderSDKInvocationLease()
        let links = LinkSpy()
        let coordinator = ProviderSignInCoordinator(
            account: account,
            apple: ParkingAppleAuthorizer(),
            google: google,
            googleConfigurationIsUsable: { true },
            recordLink: { links.record($0) },
            googleSDKSession: signOut.ownership,
            sdkInvocations: lease
        )
        return LeaseRig(
            account: account,
            coordinator: coordinator,
            google: google,
            api: api,
            tokens: tokens,
            signOut: signOut,
            lease: lease,
            links: links
        )
    }

    func testASecondGoogleSDKCallCannotStartWhileTheFirstIsOutstanding() async {
        // The exact reverse-ABA ordering, pinned step by step.
        let rig = makeLeaseRig()

        let flowA = Task { await rig.coordinator.signInWithGoogle() }
        await rig.google.waitUntilInvoked()
        XCTAssertEqual(rig.google.invocations, 1)
        XCTAssertTrue(rig.lease.isBusy(.google), "A's SDK call is outstanding")

        // A loses its authority, but its SDK call is still in Google's hands.
        rig.tokens.setTokenForTesting("session-being-signed-out")
        _ = await rig.account.logout()
        XCTAssertFalse(rig.account.isProviderSignInCurrent(
            ProviderSignInPermit.rejectedPlaceholder(provider: .google)
        ))
        XCTAssertTrue(
            rig.lease.isBusy(.google),
            "losing the permit must not free the SDK call"
        )

        // B tries while A is still pending.
        let outcomeB = await rig.coordinator.signInWithGoogle()

        XCTAssertEqual(outcomeB, .refused(.busy))
        XCTAssertEqual(
            rig.google.invocations, 1,
            "B must not start a second GIDSignIn call while A is outstanding"
        )
        XCTAssertEqual(rig.api.googleSignInCount, 0)

        // Only now does A come back.
        rig.google.completeCallback()
        let outcomeA = await flowA.value

        XCTAssertEqual(outcomeA, .refused(.superseded))
        XCTAssertEqual(
            rig.signOut.signOutCount, 1,
            "A's own SDK state is cleaned up, with no newer flow to harm"
        )
        XCTAssertFalse(rig.lease.isBusy(.google), "the lease is freed")
        XCTAssertEqual(rig.api.googleSignInCount, 0)
        XCTAssertNil(rig.tokens.storedToken)
        XCTAssertTrue(rig.links.recorded.isEmpty)
        XCTAssertFalse(rig.account.state.isAuthenticated)
    }

    func testANewGoogleSignInSucceedsOnceTheStaleCallbackHasReturned() async {
        let rig = makeLeaseRig()

        let flowA = Task { await rig.coordinator.signInWithGoogle() }
        await rig.google.waitUntilInvoked()
        rig.tokens.setTokenForTesting("session-being-signed-out")
        _ = await rig.account.logout()

        rig.google.completeCallback()
        _ = await flowA.value
        XCTAssertFalse(rig.lease.isBusy(.google))

        // B may now run for real; its call does not park.
        let outcomeB = await rig.coordinator.signInWithGoogle()

        XCTAssertEqual(outcomeB, .signedIn)
        XCTAssertEqual(rig.google.invocations, 2)
        XCTAssertEqual(rig.tokens.storedToken, "session-from-google")
        XCTAssertTrue(rig.account.state.isAuthenticated)
        XCTAssertEqual(rig.links.recorded.count, 1)
    }

    func testAStalePendingCallbackNeverClaimsOwnership() async {
        // Currency is checked before ownership is claimed, so a stale callback
        // cannot register itself as the owner of anything.
        let rig = makeLeaseRig()

        let flowA = Task { await rig.coordinator.signInWithGoogle() }
        await rig.google.waitUntilInvoked()
        rig.tokens.setTokenForTesting("session-being-signed-out")
        _ = await rig.account.logout()

        rig.google.completeCallback()
        _ = await flowA.value

        XCTAssertNil(rig.signOut.owner, "a stale flow owns nothing")
    }

    func testACancelledSDKCallFreesTheLease() async {
        // The lease must be freed by the SDK call *ending*, however it ends,
        // or the app can never sign in with Google again.
        let rig = makeLeaseRig()
        rig.google.completeCallback()
        _ = await rig.coordinator.signInWithGoogle()

        XCTAssertFalse(rig.lease.isBusy(.google))
    }

    func testAnAppleSignInIsNotBlockedByAPendingGoogleCall() async {
        // Apple has no persistent client-side session, and blocking it behind
        // Google's SDK would be an unrelated regression.
        let rig = makeLeaseRig()

        let flowA = Task { await rig.coordinator.signInWithGoogle() }
        await rig.google.waitUntilInvoked()

        XCTAssertTrue(rig.lease.isBusy(.google))
        XCTAssertFalse(rig.lease.isBusy(.apple))

        rig.google.completeCallback()
        _ = await flowA.value
    }

    func testTheReverseABAOrderingIsStableAcrossRepeatedRuns() async {
        for _ in 0..<20 {
            let rig = makeLeaseRig()

            let flowA = Task { await rig.coordinator.signInWithGoogle() }
            await rig.google.waitUntilInvoked()
            rig.tokens.setTokenForTesting("session-being-signed-out")
            _ = await rig.account.logout()

            let outcomeB = await rig.coordinator.signInWithGoogle()
            XCTAssertEqual(outcomeB, .refused(.busy))
            XCTAssertEqual(rig.google.invocations, 1)

            rig.google.completeCallback()
            _ = await flowA.value

            XCTAssertEqual(rig.signOut.signOutCount, 1)
            XCTAssertFalse(rig.lease.isBusy(.google))
        }
    }
}

// MARK: - Cross-launch cleanup

//  The owner record is in memory. The Google SDK's session is on disk.
//
//  So the ordinary case after a relaunch is: signed into Google, `owner ==
//  nil`. Any cleanup written as `if owner != nil` does nothing there — and
//  "there" includes deleting your account the morning after signing in, which
//  is precisely when leaving the device signed into the backing Google
//  account is least acceptable.

@MainActor
final class GoogleSDKCrossLaunchCleanupTests: XCTestCase {

    private struct DeletionRig {
        let store: ServerAccountStore
        let api: StubAccountAPI
        let tokens: InMemoryServerSessionTokenStore
        let signOut: GoogleSDKSignOutSpy
        let links: RecordingLinkedAccountStore
        let section: ServerAccountSettingsSection
    }

    private func makeDeletionRig(
        outcome: Result<AccountDeletionOutcome, Error> = .success(.deleted)
    ) -> DeletionRig {
        let api = StubAccountAPI()
        api.deleteResult = outcome
        let tokens = InMemoryServerSessionTokenStore(token: "session-token")
        let store = ServerAccountStore(api: api, tokenStore: tokens, deviceName: "iPhone")
        let signOut = GoogleSDKSignOutSpy()
        let links = RecordingLinkedAccountStore(
            initial: LinkedAccount(provider: .google, userIdentifier: "google-user")
        )
        let authSession = AuthSessionStore(
            initialState: .signedIn(
                AuthSession(provider: .google, userIdentifier: "google-user")
            ),
            linkedAccountStore: links,
            googleSession: NoopGoogleSessionManager()
        )
        let section = ServerAccountSettingsSection(
            store: store,
            googleSDKSession: signOut.ownership,
            authSession: authSession
        )
        return DeletionRig(
            store: store,
            api: api,
            tokens: tokens,
            signOut: signOut,
            links: links,
            section: section
        )
    }

    func testDeletingTheAccountSignsOutOfGoogleEvenWithNoOwnerRecorded() async {
        // Exactly the post-relaunch shape: a live Google session, and nothing
        // in memory that knows whose it was.
        let rig = makeDeletionRig()
        XCTAssertNil(rig.signOut.owner, "a fresh launch knows of no owner")

        await rig.section.deleteAccount()

        XCTAssertEqual(
            rig.signOut.signOutCount, 1,
            "an absent owner record is not a reason to leave Google signed in"
        )
        XCTAssertNil(rig.signOut.owner)
        XCTAssertNil(rig.tokens.storedToken)
        XCTAssertNil(rig.links.linkedAccount, "the local link is dropped too")
    }

    func testAPendingDeletionAlsoCleansUpTheProviderSession() async {
        // 202 means accepted and irreversible. The account is going away, so
        // the local cleanup is the same as for 200.
        let rig = makeDeletionRig(outcome: .success(.pending))

        await rig.section.deleteAccount()

        XCTAssertEqual(rig.signOut.signOutCount, 1)
        XCTAssertNil(rig.links.linkedAccount)
    }

    func testAnUnconfirmedDeletionCleansUpNothing() async {
        // A 401 is indistinguishable from a successful first attempt whose
        // response was lost, so neither proves the account is gone. Signing
        // out of Google or dropping the link here would act on a deletion that
        // may never have happened.
        let rig = makeDeletionRig(outcome: .failure(AccountAPIError.unavailable))

        await rig.section.deleteAccount()

        XCTAssertEqual(rig.signOut.signOutCount, 0)
        XCTAssertNotNil(rig.links.linkedAccount)
    }

    func testSigningOutEndsTheGoogleSessionRatherThanJustForgettingIt() async {
        // The combination that cannot be defended is "drop the owner record,
        // leave the SDK signed in": a live session with nothing tracking it.
        let rig = makeDeletionRig()

        await rig.section.signOut()

        XCTAssertEqual(rig.signOut.signOutCount, 1)
        XCTAssertNil(rig.signOut.owner)
        XCTAssertEqual(rig.store.state, .guest)
    }

    func testAFailedKeychainDeleteStillReportsLocalCleanupFailed() async {
        // Google's session and PulseCue's session are different credentials.
        // Ending the first says nothing about the second, and must not upgrade
        // the state to a sign-out the Keychain did not actually perform.
        let rig = makeDeletionRig()
        rig.tokens.deleteFailure = errSecInteractionNotAllowed

        await rig.section.signOut()

        XCTAssertEqual(rig.signOut.signOutCount, 1, "the user's intent is honoured")
        XCTAssertEqual(
            rig.store.state, .localCleanupFailed,
            "but PulseCue is not signed out while its token may remain"
        )
    }

    func testRestoringASessionDoesNotSignOutOfGoogle() async {
        // Restore invalidates in-flight provider flows; it does not tear down
        // an established Google session on every launch.
        let rig = makeDeletionRig()
        rig.api.profileResult = .success(
            ServerAccountProfile(
                user: .init(id: "user-1", state: "active", displayName: nil, createdAt: 1),
                linkedProviders: [.init(provider: "google", linkedAt: 1)],
                session: .init(expiresAt: 1_800_000_000)
            )
        )

        await rig.store.restore()

        XCTAssertTrue(rig.store.state.isAuthenticated)
        XCTAssertEqual(rig.signOut.signOutCount, 0)
        XCTAssertNotNil(rig.links.linkedAccount)
    }
}

/// A `LinkedAccountStoring` that just remembers, for asserting on.
@MainActor
private final class RecordingLinkedAccountStore: LinkedAccountStoring {
    private(set) var linkedAccount: LinkedAccount?

    init(initial: LinkedAccount?) {
        linkedAccount = initial
    }

    func save(_ account: LinkedAccount) { linkedAccount = account }
    func clear() { linkedAccount = nil }
}

/// A Google session manager that touches no SDK.
///
/// The Google sign-out under test is the one the *ownership* type performs;
/// this keeps `AuthSessionStore`'s own unlink path from adding a second,
/// unrelated call to the count.
@MainActor
private final class NoopGoogleSessionManager: GoogleSessionManaging {
    func restorePreviousSignIn() async -> RestoredGoogleUser? { nil }
    func signOut() {}
}
