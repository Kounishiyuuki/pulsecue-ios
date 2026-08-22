//
//  ProviderSignInGateTests.swift
//  Pulse CueTests
//
//  Proving the provider SDK is not started, rather than that the sign-in
//  eventually failed.
//
//  Those are different claims and only one of them is enough. Google's SDK
//  switches the device's locally selected account the moment the user picks
//  one — before PulseCue has any say. A flow that opens the sheet and then
//  refuses the result still leaves the phone pointing at Account B while the
//  PulseCue session belongs to Account A. So every test here asserts an
//  *invocation count of zero* on the authorizing double: if the count is one,
//  the sheet opened, and the damage is already done no matter what the store
//  returned afterwards.
//

import XCTest
@testable import Pulse_Cue

// MARK: - Doubles

/// Counts authorizations and never touches a real SDK.
@MainActor
private final class SpyAppleAuthorizer: AppleAuthorizing {
    private(set) var invocations = 0
    var outcome: ProviderAuthorizationOutcome<AppleAuthorization> = .authorized(
        AppleAuthorization(
            identityToken: "apple-identity-token",
            authorizationCode: "apple-authorization-code",
            rawNonce: "raw-nonce",
            providerUserID: "apple-user",
            displayName: "Apple User",
            email: "apple@example.com"
        )
    )
    /// Runs while the authorization is "open", for interleaving tests.
    var whileAuthorizing: (() async -> Void)?

    func authorize() async -> ProviderAuthorizationOutcome<AppleAuthorization> {
        invocations += 1
        await whileAuthorizing?()
        return outcome
    }
}

@MainActor
private final class SpyGoogleAuthorizer: GoogleAuthorizing {
    private(set) var invocations = 0
    var outcome: ProviderAuthorizationOutcome<GoogleAuthorization> = .authorized(
        GoogleAuthorization(
            idToken: "google-id-token",
            providerUserID: "google-user",
            displayName: "Google User",
            email: "google@example.com"
        )
    )
    var whileAuthorizing: (() async -> Void)?

    func authorize() async -> ProviderAuthorizationOutcome<GoogleAuthorization> {
        invocations += 1
        await whileAuthorizing?()
        return outcome
    }
}

// MARK: - Fixtures

private func gateSession(
    token: String = "session-token-abc"
) -> ServerSessionResponse {
    ServerSessionResponse(
        sessionToken: token,
        expiresAt: 1_800_000_000,
        user: .init(id: "user-1", created: false)
    )
}

private func gateProfile(
    providers: [String] = ["apple"]
) -> ServerAccountProfile {
    ServerAccountProfile(
        user: .init(id: "user-1", state: "active", displayName: "テスト", createdAt: 1),
        linkedProviders: providers.map { .init(provider: $0, linkedAt: 1) },
        session: .init(expiresAt: 1_800_000_000)
    )
}

@MainActor
private struct Gate {
    let coordinator: ProviderSignInCoordinator
    let account: ServerAccountStore
    let apple: SpyAppleAuthorizer
    let google: SpyGoogleAuthorizer
    let api: StubAccountAPI
    let tokens: InMemoryServerSessionTokenStore
    let links: LinkRecorder

    /// Every provider SDK entry point, counted together.
    ///
    /// The invariant is about the SDKs as a set, not about either one: two
    /// buttons racing must produce one sheet in total, not one sheet each.
    var totalAuthorizations: Int { apple.invocations + google.invocations }
}

@MainActor
private final class LinkRecorder {
    private(set) var recorded: [LinkedAccount] = []
    func record(_ account: LinkedAccount) { recorded.append(account) }
}

@MainActor
private func makeGate(
    tokens: InMemoryServerSessionTokenStore = InMemoryServerSessionTokenStore(),
    api: StubAccountAPI = StubAccountAPI(),
    googleConfigurationIsUsable: @escaping () -> Bool = { true }
) -> Gate {
    // The happy path by default. A test wanting a server refusal scripts it on
    // `gate.api` afterwards, so this cannot silently overwrite the intent.
    api.appleResult = .success(gateSession())
    api.googleResult = .success(gateSession())
    api.profileResult = .success(gateProfile())
    let account = ServerAccountStore(
        api: api,
        tokenStore: tokens,
        deviceName: "iPhone"
    )
    let apple = SpyAppleAuthorizer()
    let google = SpyGoogleAuthorizer()
    let links = LinkRecorder()
    let coordinator = ProviderSignInCoordinator(
        account: account,
        apple: apple,
        google: google,
        googleConfigurationIsUsable: googleConfigurationIsUsable,
        recordLink: { links.record($0) }
    )
    return Gate(
        coordinator: coordinator,
        account: account,
        apple: apple,
        google: google,
        api: api,
        tokens: tokens,
        links: links
    )
}

// MARK: - A: an existing session must not open the sheet

@MainActor
final class ProviderSignInExistingSessionGateTests: XCTestCase {

    func testAppleSignInDoesNotStartTheSDKWhenASessionIsAlreadyHeld() async {
        let tokens = InMemoryServerSessionTokenStore(token: "existing-session")
        let gate = makeGate(tokens: tokens)

        let outcome = await gate.coordinator.signInWithApple()

        XCTAssertEqual(outcome, .refused(.existingSession))
        XCTAssertEqual(
            gate.apple.invocations, 0,
            "the Apple sheet must never open while a session is held"
        )
        XCTAssertEqual(gate.tokens.storedToken, "existing-session")
    }

    func testGoogleSignInDoesNotStartTheSDKWhenASessionIsAlreadyHeld() async {
        // The case that motivated the whole gate: opening this sheet switches
        // the device's Google account even if PulseCue then refuses.
        let tokens = InMemoryServerSessionTokenStore(token: "existing-session")
        let gate = makeGate(tokens: tokens)

        let outcome = await gate.coordinator.signInWithGoogle()

        XCTAssertEqual(outcome, .refused(.existingSession))
        XCTAssertEqual(
            gate.google.invocations, 0,
            "GIDSignIn must not run: it would switch the local Google account"
        )
        XCTAssertEqual(gate.tokens.storedToken, "existing-session")
    }

    func testARefusedSignInRecordsNoLocalLink() async {
        let tokens = InMemoryServerSessionTokenStore(token: "existing-session")
        let gate = makeGate(tokens: tokens)

        _ = await gate.coordinator.signInWithGoogle()

        XCTAssertTrue(gate.links.recorded.isEmpty)
    }
}

// MARK: - B: an unreadable Keychain rules nothing out

@MainActor
final class ProviderSignInCredentialUnavailableGateTests: XCTestCase {

    func testAppleSignInDoesNotStartTheSDKWhenTheKeychainCannotBeRead() async {
        let tokens = InMemoryServerSessionTokenStore()
        tokens.readFailure = errSecInteractionNotAllowed
        let gate = makeGate(tokens: tokens)

        let outcome = await gate.coordinator.signInWithApple()

        XCTAssertEqual(outcome, .refused(.credentialUnavailable))
        XCTAssertEqual(gate.apple.invocations, 0)
    }

    func testGoogleSignInDoesNotStartTheSDKWhenTheKeychainCannotBeRead() async {
        // An unreadable Keychain is not an absent token. A session may well be
        // on disk, so this is treated exactly like an existing one.
        let tokens = InMemoryServerSessionTokenStore()
        tokens.readFailure = errSecInteractionNotAllowed
        let gate = makeGate(tokens: tokens)

        let outcome = await gate.coordinator.signInWithGoogle()

        XCTAssertEqual(outcome, .refused(.credentialUnavailable))
        XCTAssertEqual(gate.google.invocations, 0)
    }
}

// MARK: - C: an unconfigured build

@MainActor
final class ProviderSignInNotConfiguredGateTests: XCTestCase {

    func testNoSDKStartsWhenTheAccountAPIIsNotConfigured() async {
        let gate = makeGate()
        gate.api.configured = false

        let apple = await gate.coordinator.signInWithApple()
        let google = await gate.coordinator.signInWithGoogle()

        XCTAssertEqual(apple, .refused(.notConfigured))
        XCTAssertEqual(google, .refused(.notConfigured))
        XCTAssertEqual(gate.totalAuthorizations, 0)
    }

    func testGoogleDoesNotStartWhenItsClientConfigurationIsUnusable() async {
        // Checked before the permit, so a build that cannot finish the flow
        // does not take a reservation it will only hand straight back.
        let gate = makeGate(googleConfigurationIsUsable: { false })

        let outcome = await gate.coordinator.signInWithGoogle()

        XCTAssertEqual(outcome, .refused(.notConfigured))
        XCTAssertEqual(gate.google.invocations, 0)
    }
}

// MARK: - D: two taps, one sheet

@MainActor
final class ProviderSignInConcurrencyGateTests: XCTestCase {

    func testASecondProviderCannotStartWhileTheFirstSheetIsOpen() async {
        let gate = makeGate()
        var googleOutcome: ProviderSignInOutcome?

        // Runs at the exact moment the Apple sheet is open — the window a
        // second tap would land in on a real device.
        gate.apple.whileAuthorizing = {
            googleOutcome = await gate.coordinator.signInWithGoogle()
        }

        let appleOutcome = await gate.coordinator.signInWithApple()

        XCTAssertEqual(appleOutcome, .signedIn)
        XCTAssertEqual(googleOutcome, .refused(.busy))
        XCTAssertEqual(gate.apple.invocations, 1)
        XCTAssertEqual(
            gate.google.invocations, 0,
            "the second tap must not open a second provider sheet"
        )
        XCTAssertEqual(gate.totalAuthorizations, 1)
    }

    func testTappingTheSameProviderTwiceOpensOneSheet() async {
        let gate = makeGate()
        var secondOutcome: ProviderSignInOutcome?

        gate.google.whileAuthorizing = {
            secondOutcome = await gate.coordinator.signInWithGoogle()
        }

        let firstOutcome = await gate.coordinator.signInWithGoogle()

        XCTAssertEqual(firstOutcome, .signedIn)
        XCTAssertEqual(secondOutcome, .refused(.busy))
        XCTAssertEqual(gate.google.invocations, 1)
    }

    func testTheGateReopensAfterAFlowFinishes() async {
        // A permit leaked on any exit path would leave the app permanently
        // unable to sign in — worse than the race it prevents.
        let gate = makeGate()
        gate.apple.outcome = .cancelled

        let cancelled = await gate.coordinator.signInWithApple()
        XCTAssertEqual(cancelled, .cancelled)

        let second = await gate.coordinator.signInWithApple()
        XCTAssertNotEqual(second, .refused(.busy), "the permit was not released")
        XCTAssertEqual(gate.apple.invocations, 2)
    }

    func testAProviderFailureAlsoReleasesTheGate() async {
        let gate = makeGate()
        gate.google.outcome = .failed

        let failed = await gate.coordinator.signInWithGoogle()
        XCTAssertEqual(failed, .providerFailed)

        gate.google.outcome = .authorized(
            GoogleAuthorization(
                idToken: "google-id-token",
                providerUserID: "google-user",
                displayName: nil,
                email: nil
            )
        )
        let retried = await gate.coordinator.signInWithGoogle()
        XCTAssertEqual(retried, .signedIn)
    }
}

// MARK: - E: the store's own preflight still stands behind the gate

@MainActor
final class ProviderSignInBackendPreflightTests: XCTestCase {

    func testASessionAppearingDuringTheSheetStopsTheBackendExchange() async {
        // Defence in depth. The permit closes the window the SDK runs in, but
        // a token can still land on disk from elsewhere while the sheet is up,
        // and exchanging anyway would orphan it.
        let tokens = InMemoryServerSessionTokenStore()
        let gate = makeGate(tokens: tokens)

        gate.google.whileAuthorizing = {
            tokens.setTokenForTesting("session-that-appeared")
        }

        let outcome = await gate.coordinator.signInWithGoogle()

        XCTAssertEqual(outcome, .refused(.serverRefused))
        XCTAssertEqual(gate.google.invocations, 1, "the sheet legitimately opened")
        XCTAssertEqual(
            gate.api.googleRequests.count, 0,
            "but the backend exchange must not run"
        )
        XCTAssertEqual(gate.tokens.storedToken, "session-that-appeared")
        XCTAssertEqual(gate.account.lastFailure, .existingSessionHeld)
    }

    func testAKeychainThatBecomesUnreadableDuringTheSheetStopsTheExchange() async {
        let tokens = InMemoryServerSessionTokenStore()
        let gate = makeGate(tokens: tokens)

        gate.apple.whileAuthorizing = {
            tokens.readFailure = errSecInteractionNotAllowed
        }

        let outcome = await gate.coordinator.signInWithApple()

        XCTAssertEqual(outcome, .refused(.serverRefused))
        XCTAssertEqual(gate.api.appleRequests.count, 0)
        XCTAssertEqual(gate.account.lastFailure, .credentialUnavailable)
    }
}

// MARK: - F: a refused sign-in must not damage restore

@MainActor
final class ProviderSignInRestoreInteractionTests: XCTestCase {

    func testARefusedSignInDoesNotLeaveTheStoreRestoring() async {
        // The bug this covers: a refusal that consumed an operation generation
        // would orphan the in-flight restore, and the UI would sit on
        // "アカウントを確認中…" forever.
        let tokens = InMemoryServerSessionTokenStore(token: "existing-session")
        let gate = makeGate(tokens: tokens)

        let restore = Task { await gate.account.restore() }
        // Refused before the SDK, and before any generation is taken.
        let refused = await gate.coordinator.signInWithGoogle()
        await restore.value

        XCTAssertEqual(refused, .refused(.existingSession))
        XCTAssertEqual(gate.google.invocations, 0)
        XCTAssertTrue(
            gate.account.state.isAuthenticated,
            "the restore must still complete: \(gate.account.state)"
        )
    }

    func testAnAllowedSignInSupersedesAnInFlightRestore() async {
        // The opposite direction, and still correct: a sign-in that is allowed
        // to start does take a generation, and the restore it overtakes must
        // not write its own outcome afterwards.
        let tokens = InMemoryServerSessionTokenStore()
        let gate = makeGate(tokens: tokens)

        let restore = Task { await gate.account.restore() }
        await restore.value

        let outcome = await gate.coordinator.signInWithApple()

        XCTAssertEqual(outcome, .signedIn)
        XCTAssertTrue(gate.account.state.isAuthenticated)
    }
}

// MARK: - G: the local link follows the server

@MainActor
final class ProviderSignInLinkRecordingTests: XCTestCase {

    func testALinkIsRecordedOnlyAfterTheServerConfirms() async {
        let gate = makeGate()

        let outcome = await gate.coordinator.signInWithApple()

        XCTAssertEqual(outcome, .signedIn)
        XCTAssertEqual(gate.links.recorded.count, 1)
        XCTAssertEqual(gate.links.recorded.first?.provider, .apple)
        XCTAssertEqual(gate.links.recorded.first?.userIdentifier, "apple-user")
    }

    func testNoLinkIsRecordedWhenTheServerRefuses() async {
        let gate = makeGate()
        gate.api.appleResult = .failure(AccountAPIError.invalidCredentials)

        let outcome = await gate.coordinator.signInWithApple()

        XCTAssertEqual(outcome, .refused(.serverRefused))
        XCTAssertTrue(
            gate.links.recorded.isEmpty,
            "a local link would claim an account the server does not have"
        )
    }

    func testNoLinkIsRecordedWhenTheUserCancelsTheSheet() async {
        let gate = makeGate()
        gate.google.outcome = .cancelled

        let outcome = await gate.coordinator.signInWithGoogle()

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(gate.links.recorded.isEmpty)
        XCTAssertEqual(gate.account.state, .guest, "cancelling is not a failure")
    }
}

// MARK: - H: no anchor, no authorization

@MainActor
final class AppleAuthorizationAnchorTests: XCTestCase {

    func testNoAuthorizationIsStartedWithoutAPresentationAnchor() async {
        // The bridge used to fall back to a bare `ASPresentationAnchor()` — an
        // empty, unattached window. Apple then has nowhere real to present, and
        // the app sits holding a permit waiting for a callback that may never
        // arrive. Refusing to start is the only honest option.
        var performRequestsCount = 0
        let bridge = AppleAuthorizationBridge(
            anchorProvider: { nil },
            startRequests: { _ in performRequestsCount += 1 }
        )

        let outcome = await bridge.authorize()

        guard case .failed = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        XCTAssertEqual(
            performRequestsCount, 0,
            "no authorization may be started without a real anchor"
        )
    }

}
