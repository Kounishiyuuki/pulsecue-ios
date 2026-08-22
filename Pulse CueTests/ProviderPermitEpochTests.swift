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

@MainActor
private final class GoogleSDKSignOutSpy {
    private(set) var signOutCount = 0
    func signOut() { signOutCount += 1 }
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
        signOutGoogleSDK: { googleSDK.signOut() }
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

    func testAStaleGoogleCleanupDoesNotDisturbANewerGoogleFlow() async {
        // The cleanup added for stale Google flows must not become its own
        // bug: if a newer Google sign-in has legitimately selected an account,
        // the old flow's late cleanup would sign the user out of the one they
        // actually chose.
        let rig = makeRig()

        let staleSignIn = Task { await rig.coordinator.signInWithGoogle() }
        await rig.google.parking.waitUntilPresented()
        rig.tokens.setTokenForTesting("session-being-signed-out")
        _ = await rig.account.logout()

        // A newer Google flow takes the floor before the old callback returns.
        let newer = rig.account.prepareProviderSignIn(provider: .google)
        guard case .allowed = newer else {
            return XCTFail("a new Google flow should be able to start")
        }

        rig.google.parking.finish()
        _ = await staleSignIn.value

        XCTAssertEqual(
            rig.googleSDK.signOutCount, 0,
            "the newer Google flow owns the SDK state now"
        )
    }
}
