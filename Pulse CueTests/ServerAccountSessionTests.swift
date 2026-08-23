//
//  ServerAccountSessionTests.swift
//  Pulse CueTests
//
//  The server-backed account layer: configuration, the API client's error
//  classification, the Keychain token store, and the state machine.
//
//  The tests that matter most are the ones about *not* signing someone out.
//  A 401 must clear the session; a timeout must not. Those two look almost
//  identical at the call site and mean opposite things, and getting them
//  backwards would sign users out for walking into a lift.
//

import Security
import XCTest
@testable import Pulse_Cue

// MARK: - Doubles

/// A scriptable API. Records what was sent so tests can assert on the body.
final class StubAccountAPI: PulseCueAccountAPI, @unchecked Sendable {
    var configured = true
    var isConfigured: Bool { configured }

    var appleResult: Result<ServerSessionResponse, Error> = .failure(AccountAPIError.unavailable)
    var googleResult: Result<ServerSessionResponse, Error> = .failure(AccountAPIError.unavailable)
    var profileResult: Result<ServerAccountProfile, Error> = .failure(AccountAPIError.unavailable)
    var logoutResult: Result<Void, Error> = .success(())
    var deleteResult: Result<AccountDeletionOutcome, Error> = .success(.deleted)

    private(set) var appleRequests: [AppleSignInRequest] = []
    private(set) var googleRequests: [GoogleSignInRequest] = []
    private(set) var profileTokens: [String] = []
    private(set) var logoutTokens: [String] = []
    private(set) var deleteTokens: [String] = []

    func signInWithApple(_ request: AppleSignInRequest) async throws -> ServerSessionResponse {
        appleRequests.append(request)
        return try appleResult.get()
    }

    func signInWithGoogle(_ request: GoogleSignInRequest) async throws -> ServerSessionResponse {
        googleRequests.append(request)
        return try googleResult.get()
    }

    func fetchProfile(sessionToken: String) async throws -> ServerAccountProfile {
        profileTokens.append(sessionToken)
        return try profileResult.get()
    }

    func logout(sessionToken: String) async throws {
        logoutTokens.append(sessionToken)
        try logoutResult.get()
    }

    func deleteAccount(sessionToken: String) async throws -> AccountDeletionOutcome {
        deleteTokens.append(sessionToken)
        return try deleteResult.get()
    }
}

/// A transport that replays a canned response or throws.
struct StubTransport: AccountHTTPTransport {
    var status: Int = 200
    var body: Data = Data("{}".utf8)
    var thrownError: Error?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let thrownError { throw thrownError }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    }
}

// MARK: - Fixtures

private func makeSession(token: String = "session-token-abc") -> ServerSessionResponse {
    ServerSessionResponse(
        sessionToken: token,
        expiresAt: 1_800_000_000,
        user: .init(id: "user-1", created: false)
    )
}

private func makeProfile(
    state: String = "active",
    providers: [String] = ["apple"]
) -> ServerAccountProfile {
    ServerAccountProfile(
        user: .init(id: "user-1", state: state, displayName: "テスト", createdAt: 1),
        linkedProviders: providers.map { .init(provider: $0, linkedAt: 1) },
        session: .init(expiresAt: 1_800_000_000)
    )
}

/// Takes a permit for a test that is exercising the store directly.
///
/// Production always goes through `ProviderSignInCoordinator`; these tests
/// drive the store beneath it, so they take the permit the coordinator would.
@MainActor
private func permitFor(
    _ store: ServerAccountStore,
    _ provider: AuthProviderKind
) -> ProviderSignInPermit {
    guard case let .allowed(permit) = store.prepareProviderSignIn(provider: provider) else {
        // A refusal here means the test's precondition is not what it thinks.
        // A placeholder permit keeps the call compiling and the store will
        // reject it, which is the correct outcome for a refused sign-in.
        return .rejectedPlaceholder(provider: provider)
    }
    return permit
}

/// Hands a parked sign-in's permit back, so a second provider sign-in can start
/// while the first is still inside the backend exchange.
///
/// The reservation makes that impossible through the real UI, and
/// `ProviderSignInGateTests` is what proves it. These tests are aimed one layer
/// lower — at the operation generation guard, which has to hold *even if* two
/// exchanges somehow end up in flight at once. Released only after the first
/// flow is provably parked, so its own permit check has already passed: that
/// reproduces the race without weakening the store.
@MainActor
private func releasePermit(
    _ permit: ProviderSignInPermit,
    on store: ServerAccountStore
) {
    store.finishProviderSignIn(permit)
}

@MainActor
private func makeStore(
    api: StubAccountAPI,
    tokenStore: InMemoryServerSessionTokenStore
) -> ServerAccountStore {
    ServerAccountStore(api: api, tokenStore: tokenStore, deviceName: "iPhone")
}

// MARK: - Configuration

final class PulseCueAPIConfigurationTests: XCTestCase {

    func testUnconfiguredWhenMissingBlankOrPlaceholder() {
        // A build without a real API must connect nowhere at all — not to a
        // guessed host, and not to localhost.
        for raw in [
            nil,
            "",
            "   ",
            PulseCueAPIConfiguration.placeholderBaseURL,
            "https://YOUR_PULSECUE_API_HOST/v1",
        ] {
            let configuration = PulseCueAPIConfiguration(rawValue: raw)
            XCTAssertFalse(configuration.isConfigured, "should reject \(raw ?? "nil")")
            XCTAssertNil(configuration.url(forPath: "v1/me"))
        }
    }

    func testRejectsAnythingThatIsNotPlainHTTPS() {
        // A session token must never leave the device in the clear, and a URL
        // carrying credentials would end up in logs and proxies.
        for raw in [
            "http://api.example.com",
            "ftp://api.example.com",
            "javascript:alert(1)",
            "https://",
            "https://user:pass@api.example.com",
            "not a url at all",
        ] {
            XCTAssertFalse(
                PulseCueAPIConfiguration(rawValue: raw).isConfigured,
                "should reject \(raw)"
            )
        }
    }

    func testBuildsPathsAgainstAConfiguredHost() {
        let configuration = PulseCueAPIConfiguration(rawValue: "https://api.example.com")
        XCTAssertTrue(configuration.isConfigured)
        XCTAssertEqual(
            configuration.url(forPath: "v1/me")?.absoluteString,
            "https://api.example.com/v1/me"
        )
    }

    func testKeepsABasePathInsteadOfDroppingIt() {
        // Without the normalising trailing slash, resolving a relative path
        // silently discards the last path component of the base.
        let configuration = PulseCueAPIConfiguration(rawValue: "https://api.example.com/pulsecue")
        XCTAssertEqual(
            configuration.url(forPath: "v1/me")?.absoluteString,
            "https://api.example.com/pulsecue/v1/me"
        )
    }

    func testStripsQueryAndFragmentFromTheBase() {
        let configuration = PulseCueAPIConfiguration(
            rawValue: "https://api.example.com?debug=1#frag"
        )
        XCTAssertEqual(
            configuration.url(forPath: "v1/me")?.absoluteString,
            "https://api.example.com/v1/me"
        )
    }
}

// MARK: - Google server client id

final class GoogleServerSignInConfigTests: XCTestCase {

    func testUnconfiguredForPlaceholderOrNonsense() {
        for raw in [
            nil,
            "",
            GoogleServerSignInConfig.placeholderServerClientID,
            "YOUR_WEB_SERVER_CLIENT_ID.apps.googleusercontent.com",
            "not-a-client-id",
            "123456.example.com",
        ] {
            XCTAssertFalse(
                GoogleServerSignInConfig(serverClientID: raw).isConfigured,
                "should reject \(raw ?? "nil")"
            )
        }
    }

    func testConfiguredForARealLookingWebClientID() {
        let config = GoogleServerSignInConfig(
            serverClientID: "123456-web.apps.googleusercontent.com"
        )
        XCTAssertTrue(config.isConfigured)
    }

    func testCatchesTheIOSClientIDPastedIntoTheServerSlot() {
        // Both end in .apps.googleusercontent.com, so shape cannot tell them
        // apart — but they must never be equal, and that is checkable. The
        // mistake fails closed (the backend rejects every token), which looks
        // like "sign-in is broken" rather than "wrong value".
        let iosClientID = "376943003827-ios.apps.googleusercontent.com"
        let wrong = GoogleServerSignInConfig(serverClientID: iosClientID)
        XCTAssertFalse(wrong.isDistinct(from: iosClientID))

        let right = GoogleServerSignInConfig(
            serverClientID: "376943003827-web.apps.googleusercontent.com"
        )
        XCTAssertTrue(right.isDistinct(from: iosClientID))
    }
}

// MARK: - Nonce

final class AppleSignInNonceTests: XCTestCase {

    func testRawNonceIsLongRandomHex() {
        let nonce = AppleSignInNonce.makeRawNonce()
        XCTAssertEqual(nonce.count, 64)
        XCTAssertNil(nonce.range(of: "[^0-9a-f]", options: .regularExpression))
    }

    func testEveryNonceIsDistinct() {
        // A predictable nonce removes the binding between the token and this
        // sign-in attempt entirely.
        let nonces = Set((0..<500).map { _ in AppleSignInNonce.makeRawNonce() })
        XCTAssertEqual(nonces.count, 500)
    }

    func testSHA256MatchesTheKnownVector() {
        // The server recomputes exactly this, so the encoding has to agree.
        XCTAssertEqual(
            AppleSignInNonce.sha256Hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testHashIsLowercaseHexOfTheRawNonce() {
        let raw = AppleSignInNonce.makeRawNonce()
        let hash = AppleSignInNonce.sha256Hex(raw)
        XCTAssertEqual(hash.count, 64)
        XCTAssertNotEqual(hash, raw)
        XCTAssertEqual(hash, AppleSignInNonce.sha256Hex(raw))
    }
}

// MARK: - Error classification

final class AccountAPIErrorClassificationTests: XCTestCase {

    private func client(_ transport: StubTransport) -> PulseCueAccountAPIClient {
        PulseCueAccountAPIClient(
            configuration: PulseCueAPIConfiguration(rawValue: "https://api.example.com"),
            transport: transport
        )
    }

    func testOnlyRejectionInvalidatesAStoredSession() {
        // The whole point of the type: exactly one case may destroy a session.
        XCTAssertTrue(AccountAPIError.invalidCredentials.invalidatesStoredSession)
        for error in [
            AccountAPIError.unavailable,
            .notConfigured,
            .malformedResponse,
        ] {
            XCTAssertFalse(error.invalidatesStoredSession, "\(error) must not sign anyone out")
        }
    }

    func testUnauthorizedAndForbiddenAreRejections() async {
        for status in [401, 403] {
            do {
                _ = try await client(StubTransport(status: status))
                    .fetchProfile(sessionToken: "t")
                XCTFail("expected a rejection for \(status)")
            } catch {
                XCTAssertEqual(error as? AccountAPIError, .invalidCredentials)
            }
        }
    }

    func testServerTroubleIsNeverAVerdictOnTheSession() async {
        // 400 is included deliberately: a request this app got wrong is our
        // bug, not a reason to destroy the user's session.
        for status in [400, 404, 429, 500, 502, 503] {
            do {
                _ = try await client(StubTransport(status: status))
                    .fetchProfile(sessionToken: "t")
                XCTFail("expected unavailable for \(status)")
            } catch {
                XCTAssertEqual(
                    error as? AccountAPIError,
                    .unavailable,
                    "status \(status) must not invalidate the session"
                )
            }
        }
    }

    func testTransportFailureIsUnavailable() async {
        let transport = StubTransport(
            thrownError: URLError(.timedOut)
        )
        do {
            _ = try await client(transport).fetchProfile(sessionToken: "t")
            XCTFail("expected unavailable")
        } catch {
            XCTAssertEqual(error as? AccountAPIError, .unavailable)
        }
    }

    func testUnreadableBodyIsMalformedNotARejection() async {
        let transport = StubTransport(status: 200, body: Data("not json".utf8))
        do {
            _ = try await client(transport).fetchProfile(sessionToken: "t")
            XCTFail("expected malformedResponse")
        } catch {
            XCTAssertEqual(error as? AccountAPIError, .malformedResponse)
            XCTAssertFalse((error as! AccountAPIError).invalidatesStoredSession)
        }
    }

    func testUnconfiguredClientRefusesBeforeReachingTheNetwork() async {
        let client = PulseCueAccountAPIClient(
            configuration: PulseCueAPIConfiguration(rawValue: nil),
            transport: StubTransport(status: 200)
        )
        do {
            _ = try await client.fetchProfile(sessionToken: "t")
            XCTFail("expected notConfigured")
        } catch {
            XCTAssertEqual(error as? AccountAPIError, .notConfigured)
        }
    }

    func testDeletionAcceptsA202AsSuccess() async throws {
        // 202 means "irreversible, not yet finished" — a success for the app,
        // not something to retry.
        try await client(StubTransport(status: 202, body: Data()))
            .deleteAccount(sessionToken: "t")
    }

    func testRequestCarriesTheBearerTokenAndNoIdentityFields() async throws {
        final class Capturing: AccountHTTPTransport, @unchecked Sendable {
            var captured: URLRequest?
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                captured = request
                let body = Data(
                    #"{"sessionToken":"t","expiresAt":1,"user":{"id":"u","created":true}}"#.utf8
                )
                return (
                    body,
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    )!
                )
            }
        }
        let transport = Capturing()
        let client = PulseCueAccountAPIClient(
            configuration: PulseCueAPIConfiguration(rawValue: "https://api.example.com"),
            transport: transport
        )

        _ = try await client.signInWithApple(
            AppleSignInRequest(
                identityToken: "id-token",
                authorizationCode: "auth-code",
                rawNonce: "raw-nonce",
                deviceName: "iPhone"
            )
        )

        let body = String(data: transport.captured?.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("identityToken"))
        XCTAssertTrue(body.contains("authorizationCode"))
        XCTAssertTrue(body.contains("rawNonce"))
        // The server takes identity from the signature, never from the client.
        XCTAssertFalse(body.contains("userIdentifier"))
        XCTAssertFalse(body.contains("email"))
        XCTAssertFalse(body.contains("subject"))
    }
}

// MARK: - Keychain store

@MainActor
final class ServerSessionTokenStoreTests: XCTestCase {

    private func makeStore() -> KeychainServerSessionTokenStore {
        KeychainServerSessionTokenStore(
            service: Self.service,
            account: "test-\(UUID().uuidString)"
        )
    }

    private static let service = "com.kounishiyuuki.pulsecue.tests.session"

    /// The simulator only grants Keychain access to a *signed* test host.
    ///
    /// These tests are built with `CODE_SIGNING_ALLOWED=NO` in CI and locally,
    /// which leaves the bundle without the entitlement `SecItemAdd` needs, and
    /// every call returns `errSecMissingEntitlement` (-34018).
    ///
    /// Skipping is the honest outcome: the assertions below are real and pass
    /// under a signed run, and pretending otherwise by rewriting them against
    /// the in-memory double would test nothing about the Keychain at all. The
    /// skip message names exactly how to run them for real.
    private func skipUnlessKeychainIsAvailable() throws {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "entitlement-probe",
            kSecValueData as String: Data("probe".utf8),
        ]
        SecItemDelete(probe as CFDictionary)
        let status = SecItemAdd(probe as CFDictionary, nil)
        SecItemDelete(probe as CFDictionary)

        if status == errSecMissingEntitlement {
            throw XCTSkip(
                """
                Keychain is unavailable to an unsigned test host \
                (errSecMissingEntitlement). Run with code signing enabled to \
                exercise these: xcodebuild test -scheme "Pulse Cue" \
                -only-testing:"Pulse CueTests/ServerSessionTokenStoreTests"
                """
            )
        }
        XCTAssertEqual(status, errSecSuccess, "unexpected Keychain status")
    }

    func testSavesReadsReplacesAndDeletes() throws {
        try skipUnlessKeychainIsAvailable()
        let store = makeStore()
        defer { _ = store.delete() }

        XCTAssertEqual(store.read(), .absent)
        XCTAssertEqual(store.store("first-token"), .stored)
        XCTAssertEqual(store.read(), .token("first-token"))

        XCTAssertEqual(store.store("second-token"), .stored)
        XCTAssertEqual(store.read(), .token("second-token"))

        XCTAssertEqual(store.delete(), .removed)
        XCTAssertEqual(store.read(), .absent)
    }

    func testDeletingNothingIsStillSuccess() throws {
        try skipUnlessKeychainIsAvailable()
        // "Nothing there" is the end state a delete wanted.
        XCTAssertEqual(makeStore().delete(), .absent)
    }

    func testTwoStoresDoNotSeeEachOther() throws {
        try skipUnlessKeychainIsAvailable()
        let a = makeStore()
        let b = makeStore()
        defer { _ = a.delete(); _ = b.delete() }

        XCTAssertEqual(a.store("token-a"), .stored)
        XCTAssertEqual(b.read(), .absent)
    }

    func testStoredItemIsThisDeviceOnlyAfterFirstUnlock() throws {
        try skipUnlessKeychainIsAvailable()
        // ThisDeviceOnly keeps the session out of backups so a restored image
        // cannot carry a live session onto different hardware. AfterFirstUnlock
        // lets a background launch restore without waiting for an unlock.
        let service = Self.service
        let account = "accessibility-\(UUID().uuidString)"
        let store = KeychainServerSessionTokenStore(service: service, account: account)
        defer { _ = store.delete() }
        XCTAssertEqual(store.store("token"), .stored)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        query.removeAll()

        XCTAssertEqual(status, errSecSuccess)
        let attributes = item as? [String: Any]
        XCTAssertEqual(
            attributes?[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }
}

// MARK: - Launch restore

@MainActor
final class ServerAccountRestoreTests: XCTestCase {

    func testNoTokenMeansGuest() async {
        let api = StubAccountAPI()
        let store = makeStore(api: api, tokenStore: InMemoryServerSessionTokenStore())

        await store.restore()

        XCTAssertEqual(store.state, .guest)
        XCTAssertTrue(api.profileTokens.isEmpty)
    }

    func testValidSessionBecomesAuthenticated() async {
        let api = StubAccountAPI()
        api.profileResult = .success(makeProfile())
        let tokens = InMemoryServerSessionTokenStore(token: "stored-token")
        let store = makeStore(api: api, tokenStore: tokens)

        await store.restore()

        XCTAssertTrue(store.state.isAuthenticated)
        XCTAssertEqual(api.profileTokens, ["stored-token"])
        XCTAssertEqual(tokens.read(), .token("stored-token"))
    }

    func testRejectedSessionIsDiscarded() async {
        let api = StubAccountAPI()
        api.profileResult = .failure(AccountAPIError.invalidCredentials)
        let tokens = InMemoryServerSessionTokenStore(token: "stored-token")
        let store = makeStore(api: api, tokenStore: tokens)

        await store.restore()

        XCTAssertEqual(store.state, .guest)
        XCTAssertEqual(tokens.read(), .absent, "a rejected session must not be kept")
    }

    func testTransientFailureKeepsTheSession() async {
        // The one that matters. A timeout says nothing about the session;
        // dropping it here would sign people out for riding a train.
        for failure in [
            AccountAPIError.unavailable,
            .malformedResponse,
        ] {
            let api = StubAccountAPI()
            api.profileResult = .failure(failure)
            let tokens = InMemoryServerSessionTokenStore(token: "stored-token")
            let store = makeStore(api: api, tokenStore: tokens)

            await store.restore()

            XCTAssertEqual(store.state, .unreachable, "for \(failure)")
            XCTAssertEqual(tokens.read(), .token("stored-token"), "for \(failure)")
            XCTAssertTrue(store.state.holdsSession)
        }
    }

    func testDeletingAccountIsNotRestored() async {
        let api = StubAccountAPI()
        api.profileResult = .success(makeProfile(state: "deleting"))
        let tokens = InMemoryServerSessionTokenStore(token: "stored-token")
        let store = makeStore(api: api, tokenStore: tokens)

        await store.restore()

        XCTAssertEqual(store.state, .guest)
        XCTAssertEqual(tokens.read(), .absent)
    }

    func testUnconfiguredBuildNeverCallsTheNetwork() async {
        let api = StubAccountAPI()
        api.configured = false
        let tokens = InMemoryServerSessionTokenStore(token: "stored-token")
        let store = makeStore(api: api, tokenStore: tokens)

        await store.restore()

        XCTAssertEqual(store.state, .notConfigured)
        XCTAssertTrue(api.profileTokens.isEmpty)
        // Nothing was destroyed just because this build has no API.
        XCTAssertEqual(tokens.read(), .token("stored-token"))
    }
}

// MARK: - Sign-in

@MainActor
final class ServerAccountSignInTests: XCTestCase {

    func testAppleSignInStoresTheSessionAndConfirmsIt() async {
        let api = StubAccountAPI()
        api.appleResult = .success(makeSession())
        api.profileResult = .success(makeProfile())
        let tokens = InMemoryServerSessionTokenStore()
        let store = makeStore(api: api, tokenStore: tokens)

        await store.signInWithApple(
            permit: permitFor(store, .apple),
            identityToken: "id-token",
            authorizationCode: "auth-code",
            rawNonce: "raw-nonce"
        )

        XCTAssertTrue(store.state.isAuthenticated)
        XCTAssertEqual(tokens.read(), .token("session-token-abc"))
        XCTAssertEqual(api.appleRequests.first?.identityToken, "id-token")
        XCTAssertEqual(api.appleRequests.first?.authorizationCode, "auth-code")
        XCTAssertEqual(api.appleRequests.first?.rawNonce, "raw-nonce")
    }

    func testAppleSignInRefusesWithoutAnAuthorizationCode() async {
        // Without it the server cannot obtain the refresh token it needs to
        // revoke at deletion, so the account could never be deleted properly.
        let api = StubAccountAPI()
        api.appleResult = .success(makeSession())
        let tokens = InMemoryServerSessionTokenStore()
        let store = makeStore(api: api, tokenStore: tokens)

        await store.signInWithApple(
            permit: permitFor(store, .apple),
            identityToken: "id-token",
            authorizationCode: "",
            rawNonce: "raw-nonce"
        )

        XCTAssertFalse(store.state.isAuthenticated)
        XCTAssertEqual(store.lastFailure, .missingProviderCredential)
        XCTAssertTrue(api.appleRequests.isEmpty, "must not reach the server")
        XCTAssertEqual(tokens.read(), .absent)
    }

    func testAppleSignInRefusesWithoutATokenOrNonce() async {
        for (token, nonce) in [("", "n"), ("t", "")] {
            let api = StubAccountAPI()
            let store = makeStore(api: api, tokenStore: InMemoryServerSessionTokenStore())
            await store.signInWithApple(
                permit: permitFor(store, .apple),
                identityToken: token,
                authorizationCode: "code",
                rawNonce: nonce
            )
            XCTAssertEqual(store.lastFailure, .missingProviderCredential)
            XCTAssertTrue(api.appleRequests.isEmpty)
        }
    }

    func testGoogleSignInSendsOnlyTheIDToken() async {
        let api = StubAccountAPI()
        api.googleResult = .success(makeSession(token: "google-session"))
        api.profileResult = .success(makeProfile(providers: ["google"]))
        let tokens = InMemoryServerSessionTokenStore()
        let store = makeStore(api: api, tokenStore: tokens)

        await store.signInWithGoogle(permit: permitFor(store, .google), idToken: "google-id-token")

        XCTAssertTrue(store.state.isAuthenticated)
        XCTAssertEqual(tokens.read(), .token("google-session"))
        XCTAssertEqual(api.googleRequests.first?.idToken, "google-id-token")
        // There is nowhere on the request to put a userID or an email, which
        // is the point — it is not a discipline anyone has to remember.
        XCTAssertEqual(api.googleRequests.first?.deviceName, "iPhone")
    }

    func testGoogleSignInRefusesAnEmptyIDToken() async {
        let api = StubAccountAPI()
        let store = makeStore(api: api, tokenStore: InMemoryServerSessionTokenStore())

        await store.signInWithGoogle(permit: permitFor(store, .google), idToken: "")

        XCTAssertEqual(store.lastFailure, .missingProviderCredential)
        XCTAssertTrue(api.googleRequests.isEmpty)
    }

    func testSignInIsUnavailableWhenTheBuildHasNoAPI() async {
        // No fake success: the app does not claim a PulseCue account exists.
        let api = StubAccountAPI()
        api.configured = false
        let store = makeStore(api: api, tokenStore: InMemoryServerSessionTokenStore())

        await store.signInWithGoogle(permit: permitFor(store, .google), idToken: "google-id-token")

        XCTAssertFalse(store.state.isAuthenticated)
        XCTAssertEqual(store.lastFailure, .notConfigured)
        XCTAssertTrue(api.googleRequests.isEmpty)
    }

    func testRejectedSignInLeavesTheUserAsGuest() async {
        let api = StubAccountAPI()
        api.appleResult = .failure(AccountAPIError.invalidCredentials)
        let tokens = InMemoryServerSessionTokenStore()
        let store = makeStore(api: api, tokenStore: tokens)

        await store.signInWithApple(
            permit: permitFor(store, .apple),
            identityToken: "t", authorizationCode: "c", rawNonce: "n"
        )

        XCTAssertEqual(store.state, .guest)
        XCTAssertEqual(store.lastFailure, .rejected)
        XCTAssertEqual(tokens.read(), .absent)
    }

    func testASessionThatCannotBeStoredIsReportedRatherThanPretended() async {
        // A session we cannot persist would evaporate at the next launch and
        // look like a random sign-out.
        let api = StubAccountAPI()
        api.appleResult = .success(makeSession())
        api.profileResult = .success(makeProfile())
        let tokens = InMemoryServerSessionTokenStore()
        tokens.writeFailure = errSecIO
        let store = makeStore(api: api, tokenStore: tokens)

        await store.signInWithApple(
            permit: permitFor(store, .apple),
            identityToken: "t", authorizationCode: "c", rawNonce: "n"
        )

        XCTAssertFalse(store.state.isAuthenticated)
        XCTAssertEqual(store.lastFailure, .couldNotStoreSession)
    }
}

// MARK: - Logout and deletion

@MainActor
final class ServerAccountLogoutAndDeletionTests: XCTestCase {

    func testLogoutRevokesAndClearsLocally() async {
        let api = StubAccountAPI()
        let tokens = InMemoryServerSessionTokenStore(token: "stored-token")
        let store = makeStore(api: api, tokenStore: tokens)

        let result = await store.logout()

        XCTAssertEqual(result, .signedOut)
        XCTAssertEqual(api.logoutTokens, ["stored-token"])
        XCTAssertEqual(tokens.read(), .absent)
        XCTAssertEqual(store.state, .guest)
    }

    func testLogoutStillWorksWhenTheServerIsUnreachable() async {
        // A user must never be stuck signed in because the network is down.
        let api = StubAccountAPI()
        api.logoutResult = .failure(AccountAPIError.unavailable)
        let tokens = InMemoryServerSessionTokenStore(token: "stored-token")
        let store = makeStore(api: api, tokenStore: tokens)

        let result = await store.logout()

        XCTAssertEqual(result, .signedOut, "the device is signed out regardless")
        XCTAssertEqual(tokens.read(), .absent, "but the device is signed out regardless")
        XCTAssertEqual(store.state, .guest)
    }

    func testLogoutOfAnAlreadyDeadSessionIsSuccess() async {
        let api = StubAccountAPI()
        api.logoutResult = .failure(AccountAPIError.invalidCredentials)
        let tokens = InMemoryServerSessionTokenStore(token: "stored-token")
        let store = makeStore(api: api, tokenStore: tokens)

        let outcome = await store.logout()
        XCTAssertEqual(outcome, .signedOut)
        XCTAssertEqual(tokens.read(), .absent)
    }

    func testDeletionClearsTheSessionOnSuccess() async {
        let api = StubAccountAPI()
        let tokens = InMemoryServerSessionTokenStore(token: "stored-token")
        let store = makeStore(api: api, tokenStore: tokens)

        let deleted = await store.deleteAccount()
        XCTAssertEqual(deleted, .deleted)

        XCTAssertEqual(api.deleteTokens, ["stored-token"])
        XCTAssertEqual(tokens.read(), .absent)
        XCTAssertEqual(store.state, .guest)
    }

    func testDeletionFailureKeepsTheSessionAndReportsIt() async {
        // The account still exists. Clearing the session would tell the user
        // it worked when it did not.
        let api = StubAccountAPI()
        api.deleteResult = .failure(AccountAPIError.unavailable)
        let tokens = InMemoryServerSessionTokenStore(token: "stored-token")
        let store = makeStore(api: api, tokenStore: tokens)

        let deleted = await store.deleteAccount()
        XCTAssertEqual(deleted, .notConfirmed(.unreachable))

        XCTAssertEqual(tokens.read(), .token("stored-token"))
        XCTAssertEqual(store.lastFailure, .unreachable)
    }
}

// MARK: - State semantics

@MainActor
final class ServerAccountStateTests: XCTestCase {

    func testOnlyAConfirmedAccountCountsAsAuthenticated() {
        // A stored token or a leftover local LinkedAccount must never drive
        // "連携済み" — only a server-confirmed profile does.
        XCTAssertFalse(ServerAccountState.guest.isAuthenticated)
        XCTAssertFalse(ServerAccountState.restoring.isAuthenticated)
        XCTAssertFalse(ServerAccountState.signingIn.isAuthenticated)
        XCTAssertFalse(ServerAccountState.unreachable.isAuthenticated)
        XCTAssertFalse(ServerAccountState.notConfigured.isAuthenticated)
        XCTAssertTrue(ServerAccountState.authenticated(makeProfile()).isAuthenticated)
    }

    func testOfflineStillHoldsTheSession() {
        XCTAssertTrue(ServerAccountState.unreachable.holdsSession)
        XCTAssertTrue(ServerAccountState.restoring.holdsSession)
        XCTAssertFalse(ServerAccountState.guest.holdsSession)
        XCTAssertFalse(ServerAccountState.notConfigured.holdsSession)
    }

    func testNoStatusLabelClaimsSyncOrBackup() {
        // Nothing syncs yet. Claiming otherwise is a promise a user only
        // discovers is false when they lose a phone.
        let states: [ServerAccountState] = [
            .guest, .restoring, .signingIn, .unreachable, .notConfigured,
            .authenticated(makeProfile(providers: ["apple", "google"])),
        ]
        for state in states {
            let label = state.statusLabel
            XCTAssertFalse(label.contains("同期"), "\(label) must not claim sync")
            XCTAssertFalse(label.contains("バックアップ"), "\(label) must not claim backup")
            XCTAssertFalse(label.isEmpty)
        }
    }

    func testAuthenticatedLabelNamesTheLinkedProviders() {
        XCTAssertEqual(
            ServerAccountState.authenticated(makeProfile(providers: ["apple"])).statusLabel,
            "Appleでサインイン済み"
        )
        XCTAssertEqual(
            ServerAccountState
                .authenticated(makeProfile(providers: ["google", "apple"]))
                .statusLabel,
            "Apple・Googleでサインイン済み"
        )
    }

    func testGuestLabelDoesNotSoundLikeAnError() {
        XCTAssertEqual(ServerAccountState.guest.statusLabel, "ゲスト（この端末に保存）")
    }
}

// MARK: - The Keychain cannot always answer

@MainActor
final class ServerAccountKeychainUnavailableTests: XCTestCase {

    func testAnUnreadableKeychainDoesNotSignTheUserOut() async {
        // A background launch before the first unlock returns
        // errSecInteractionNotAllowed. Reading that as "no session" would drop
        // the user to Guest for a transient condition — and the next sign-in
        // would overwrite a session that was there all along.
        let api = StubAccountAPI()
        api.profileResult = .success(makeProfile())
        let tokens = InMemoryServerSessionTokenStore(token: "stored-token")
        tokens.readFailure = errSecInteractionNotAllowed
        let store = makeStore(api: api, tokenStore: tokens)

        await store.restore()

        XCTAssertEqual(store.state, .unreachable)
        XCTAssertTrue(store.state.holdsSession)
        // Nothing was deleted, and the server was never asked.
        XCTAssertTrue(api.profileTokens.isEmpty)
        tokens.readFailure = nil
        XCTAssertEqual(tokens.read(), .token("stored-token"))
    }

    func testAnEmptyKeychainIsGuest() async {
        // The other half of the distinction: a successful read that finds
        // nothing really is a guest.
        let api = StubAccountAPI()
        let store = makeStore(api: api, tokenStore: InMemoryServerSessionTokenStore())

        await store.restore()

        XCTAssertEqual(store.state, .guest)
    }

    func testTheTwoReadOutcomesAreNotConflated() {
        let empty = InMemoryServerSessionTokenStore()
        XCTAssertEqual(empty.read(), .absent)
        XCTAssertNil(empty.tokenIfPresent())

        let broken = InMemoryServerSessionTokenStore(token: "t")
        broken.readFailure = errSecInteractionNotAllowed
        XCTAssertEqual(broken.read(), .unavailable(errSecInteractionNotAllowed))
        // `tokenIfPresent` collapses them, which is why restore does not use it.
        XCTAssertNil(broken.tokenIfPresent())
    }
}

// MARK: - 202 is not 200

@MainActor
final class ServerAccountDeletionOutcomeTests: XCTestCase {

    func testAcceptedDeletionIsReportedAsPendingNotDeleted() async {
        // The server answers 202 when the deletion is irreversible but
        // provider revocation has not confirmed. Telling the user their
        // account is gone would claim something the server did not say.
        let api = StubAccountAPI()
        api.deleteResult = .success(.pending)
        let tokens = InMemoryServerSessionTokenStore(token: "stored-token")
        let store = makeStore(api: api, tokenStore: tokens)

        let result = await store.deleteAccount()

        XCTAssertEqual(result, .pending)
        // Either way this device is signed out.
        XCTAssertEqual(tokens.read(), .absent)
        XCTAssertEqual(store.state, .guest)
    }

    func testConfirmedDeletionIsReportedAsDeleted() async {
        let api = StubAccountAPI()
        api.deleteResult = .success(.deleted)
        let store = makeStore(
            api: api,
            tokenStore: InMemoryServerSessionTokenStore(token: "stored-token")
        )

        let result = await store.deleteAccount()

        XCTAssertEqual(result, .deleted)
    }

    func testAFailedDeletionKeepsTheSessionAndSaysSo() async {
        let api = StubAccountAPI()
        api.deleteResult = .failure(AccountAPIError.unavailable)
        let tokens = InMemoryServerSessionTokenStore(token: "stored-token")
        let store = makeStore(api: api, tokenStore: tokens)

        let result = await store.deleteAccount()

        XCTAssertEqual(result, .notConfirmed(.unreachable))
        XCTAssertEqual(tokens.read(), .token("stored-token"))
        XCTAssertEqual(store.lastFailure, .unreachable)
    }

    func testTheClientMapsStatusCodesToTheRightOutcome() async throws {
        let client = { (status: Int) in
            PulseCueAccountAPIClient(
                configuration: PulseCueAPIConfiguration(rawValue: "https://api.example.com"),
                transport: StubTransport(status: status, body: Data())
            )
        }
        let deleted = try await client(200).deleteAccount(sessionToken: "t")
        XCTAssertEqual(deleted, .deleted)
        let pending = try await client(202).deleteAccount(sessionToken: "t")
        XCTAssertEqual(pending, .pending)
    }
}

// MARK: - A local link is not a server account

@MainActor
final class LegacyLinkedAccountIndependenceTests: XCTestCase {

    func testALocalLinkAloneNeverReadsAsAuthenticated() async {
        // `LinkedAccount` is the local-only record from before there was a
        // server: it means a provider was once attached to this device, not
        // that a PulseCue account exists. The two stores are deliberately
        // separate, and only a server-confirmed profile is authenticated.
        let legacy = AuthSessionStore(
            linkedAccountStore: InMemoryLinkedAccountStore(
                linkedAccount: LinkedAccount(
                    provider: .apple,
                    userIdentifier: "000123.local.only",
                    displayName: "テスト",
                    email: "user@example.com"
                )
            )
        )
        XCTAssertNotNil(legacy.linkedAccount)

        let api = StubAccountAPI()
        let store = makeStore(api: api, tokenStore: InMemoryServerSessionTokenStore())
        await store.restore()

        XCTAssertEqual(store.state, .guest)
        XCTAssertFalse(store.state.isAuthenticated)
        // And the server was never contacted on the strength of a local link.
        XCTAssertTrue(api.profileTokens.isEmpty)
    }

    func testTheServerStoreNeverTouchesTheLocalLink() async {
        // Restore, logout and deletion all run without a LinkedAccountStoring
        // dependency at all — the strongest form of "does not rewrite it".
        let api = StubAccountAPI()
        api.profileResult = .failure(AccountAPIError.unavailable)
        let tokens = InMemoryServerSessionTokenStore(token: "stored-token")
        let store = makeStore(api: api, tokenStore: tokens)

        await store.restore()
        _ = await store.logout()

        // Nothing above could have altered a local link, because the store has
        // no reference to one. Asserted by construction plus behaviour.
        XCTAssertEqual(store.state, .guest)
    }
}

// MARK: - A token the server immediately rejects

@MainActor
final class ServerAccountSignInRejectionTests: XCTestCase {

    func testATokenRejectedRightAfterIssueIsDiscarded() async {
        // Sign-in returned a token, then /me answered 401 — the account went
        // away between the two calls, or the token was never usable. Keeping
        // it would leave a session that can never work and make the next
        // launch look like a mysterious sign-out.
        let api = StubAccountAPI()
        api.appleResult = .success(makeSession())
        api.profileResult = .failure(AccountAPIError.invalidCredentials)
        let tokens = InMemoryServerSessionTokenStore()
        let store = makeStore(api: api, tokenStore: tokens)

        await store.signInWithApple(
            permit: permitFor(store, .apple),
            identityToken: "t", authorizationCode: "c", rawNonce: "n"
        )

        XCTAssertFalse(store.state.isAuthenticated)
        XCTAssertEqual(store.state, .guest)
        XCTAssertEqual(tokens.read(), .absent, "a rejected token must not be kept")
    }

    func testATransientFailureAfterIssueHandsTheSessionBack() async {
        // This test used to assert the opposite — that the token was kept and
        // the state became `.unreachable`. That conflated two different
        // situations:
        //
        //   *offline restore*: the token is already ours, already persisted,
        //     and a network blip says nothing about it. It is kept.
        //
        //   *sign-in that never completed*: the token was issued seconds ago
        //     and has never been recorded anywhere. Keeping it means a live
        //     60-day session that no launch will ever find and no user can
        //     revoke.
        //
        // The second is this case, so the session is handed back and the
        // sign-in fails honestly.
        let api = StubAccountAPI()
        api.appleResult = .success(makeSession())
        api.profileResult = .failure(AccountAPIError.unavailable)
        let tokens = InMemoryServerSessionTokenStore()
        let store = makeStore(api: api, tokenStore: tokens)

        let authenticated = await store.signInWithApple(
            permit: permitFor(store, .apple),
            identityToken: "t", authorizationCode: "c", rawNonce: "n"
        )

        XCTAssertFalse(authenticated)
        XCTAssertFalse(store.state.isAuthenticated)
        XCTAssertEqual(tokens.read(), .absent, "an unrecorded session is not kept")
        XCTAssertEqual(
            api.logoutTokens, ["session-token-abc"],
            "and it is handed back rather than stranded"
        )
    }
}

// MARK: - Controllable API for real race semantics

/// An API whose calls suspend until the test releases them.
///
/// `@MainActor` serialises *steps*, not *operations*: every one of these
/// methods has an `await` inside it, so a second operation can start and
/// finish while the first is parked. That is the whole class of bug these
/// tests exist for, and it cannot be reproduced without controlling exactly
/// where the suspension happens.
final class ControllableAccountAPI: PulseCueAccountAPI, @unchecked Sendable {
    var configured = true
    var isConfigured: Bool { configured }

    private let lock = NSLock()
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private var opened: Set<String> = []

    var appleResult: Result<ServerSessionResponse, Error> = .failure(AccountAPIError.unavailable)
    var googleResult: Result<ServerSessionResponse, Error> = .failure(AccountAPIError.unavailable)
    var profileResult: Result<ServerAccountProfile, Error> = .failure(AccountAPIError.unavailable)
    var deleteResult: Result<AccountDeletionOutcome, Error> = .success(.deleted)

    private(set) var logoutTokens: [String] = []
    private(set) var profileTokens: [String] = []
    private(set) var deleteTokens: [String] = []

    /// Backend sign-in exchanges actually reached.
    ///
    /// Counted at entry, before the gate, so a call that parks still counts —
    /// the point is that the server was contacted at all, which is the moment
    /// a session can be minted.
    private(set) var appleSignInCount = 0
    private(set) var googleSignInCount = 0

    /// Suspends the named call until `release` is invoked for it.
    var gated: Set<String> = []

    private var arrivals: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var arrived: Set<String> = []

    /// Suspends until the gated call has actually been entered.
    ///
    /// `Task.yield()` only offers the scheduler a chance to run the other
    /// task; it does not promise it reached anything in particular. Tests that
    /// relied on it were asserting on a hope. This is a real handshake: the
    /// competing operation does not start until the first one is provably
    /// parked inside the gate.
    func waitUntilEntered(_ name: String) async {
        let alreadyThere: Bool = {
            lock.lock(); defer { lock.unlock() }
            return arrived.contains(name)
        }()
        guard !alreadyThere else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if arrived.contains(name) {
                lock.unlock()
                continuation.resume()
            } else {
                arrivals[name, default: []].append(continuation)
                lock.unlock()
            }
        }
    }

    private func noteArrival(_ name: String) {
        lock.lock()
        arrived.insert(name)
        let waiting = arrivals.removeValue(forKey: name) ?? []
        lock.unlock()
        for continuation in waiting { continuation.resume() }
    }

    private func waitIfGated(_ name: String) async {
        let shouldWait: Bool = {
            lock.lock(); defer { lock.unlock() }
            return gated.contains(name) && !opened.contains(name)
        }()
        noteArrival(name)
        guard shouldWait else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened.contains(name) {
                lock.unlock()
                continuation.resume()
            } else {
                gates[name] = continuation
                lock.unlock()
            }
        }
    }

    func release(_ name: String) {
        lock.lock()
        opened.insert(name)
        let continuation = gates.removeValue(forKey: name)
        lock.unlock()
        continuation?.resume()
    }

    func signInWithApple(_ request: AppleSignInRequest) async throws -> ServerSessionResponse {
        lock.lock(); appleSignInCount += 1; lock.unlock()
        await waitIfGated("apple")
        return try appleResult.get()
    }

    func signInWithGoogle(_ request: GoogleSignInRequest) async throws -> ServerSessionResponse {
        lock.lock(); googleSignInCount += 1; lock.unlock()
        await waitIfGated("google")
        return try googleResult.get()
    }

    func fetchProfile(sessionToken: String) async throws -> ServerAccountProfile {
        await waitIfGated("profile")
        lock.lock(); profileTokens.append(sessionToken); lock.unlock()
        return try profileResult.get()
    }

    func logout(sessionToken: String) async throws {
        await waitIfGated("logout")
        lock.lock(); logoutTokens.append(sessionToken); lock.unlock()
    }

    func deleteAccount(sessionToken: String) async throws -> AccountDeletionOutcome {
        await waitIfGated("delete")
        lock.lock(); deleteTokens.append(sessionToken); lock.unlock()
        return try deleteResult.get()
    }
}

@MainActor
private func makeControllableStore(
    api: ControllableAccountAPI,
    tokenStore: InMemoryServerSessionTokenStore
) -> ServerAccountStore {
    ServerAccountStore(api: api, tokenStore: tokenStore, deviceName: "iPhone")
}

// MARK: - Race A/C: a stale response must not win

@MainActor
final class ServerAccountStaleOperationTests: XCTestCase {

    func testAStaleRestoreCannotResurrectASignedOutSession() async {
        // restore starts → /me suspends → logout completes → old /me returns
        // 200. Without operation ownership the late 200 would put the app back
        // into `authenticated` over a session the user deliberately ended.
        let api = ControllableAccountAPI()
        api.gated = ["profile"]
        api.profileResult = .success(makeProfile())
        let tokens = InMemoryServerSessionTokenStore(token: "stored-token")
        let store = makeControllableStore(api: api, tokenStore: tokens)

        let restoring = Task { await store.restore() }
        await api.waitUntilEntered("profile")

        let loggedOut = await store.logout()
        XCTAssertEqual(loggedOut, .signedOut)

        api.release("profile")
        await restoring.value

        XCTAssertEqual(store.state, .guest)
        XCTAssertFalse(store.state.isAuthenticated)
        XCTAssertEqual(tokens.read(), .absent)
    }

    func testAnOlderSignInCannotOverwriteANewerOne() async {
        // Sign-in A starts, sign-in B starts and finishes, then A returns.
        // A must not overwrite B's token or state — and A's own session must
        // not be left alive on the server either.
        let api = ControllableAccountAPI()
        api.gated = ["google"]
        api.googleResult = .success(makeSession(token: "session-A"))
        api.profileResult = .success(makeProfile(providers: ["google"]))
        let tokens = InMemoryServerSessionTokenStore()
        let store = makeControllableStore(api: api, tokenStore: tokens)

        let first = Task { await store.signInWithGoogle(permit: permitFor(store, .google), idToken: "token-A") }
        await api.waitUntilEntered("google")

        // B supersedes A by starting a newer authoritative operation.
        let loggedOut = await store.logout()
        XCTAssertEqual(loggedOut, .signedOut)

        api.release("google")
        let firstSucceeded = await first.value

        XCTAssertFalse(firstSucceeded)
        XCTAssertFalse(store.state.isAuthenticated)
        XCTAssertEqual(tokens.read(), .absent, "the stale session must not be stored")
        // And the orphan was handed back rather than dropped.
        XCTAssertTrue(
            api.logoutTokens.contains("session-A"),
            "a superseded sign-in must revoke the session it obtained"
        )
    }

    func testAStaleSignInDoesNotWriteALocalLink() async {
        // The store never touches LinkedAccount, and LoginView only writes one
        // when `signInWithApple` returns true — which a superseded operation
        // never does.
        let api = ControllableAccountAPI()
        api.gated = ["apple"]
        api.appleResult = .success(makeSession(token: "session-stale"))
        api.profileResult = .success(makeProfile())
        let store = makeControllableStore(
            api: api,
            tokenStore: InMemoryServerSessionTokenStore()
        )

        let signIn = Task {
            await store.signInWithApple(
                permit: permitFor(store, .apple),
                identityToken: "t", authorizationCode: "c", rawNonce: "n"
            )
        }
        await api.waitUntilEntered("apple")
        _ = await store.logout()
        api.release("apple")

        let authenticated = await signIn.value
        XCTAssertFalse(authenticated, "LoginView keys the local link off this")
    }
}

// MARK: - Race B/D: a session we obtained but will not keep

@MainActor
final class ServerAccountOrphanSessionTests: XCTestCase {

    func testAKeychainWriteFailureHandsTheSessionBack() async {
        // The server issued a 60-day session. If we cannot persist it, leaving
        // it alone would mean a live session nobody on this device can see or
        // revoke.
        let api = ControllableAccountAPI()
        api.appleResult = .success(makeSession(token: "orphan-session"))
        api.profileResult = .success(makeProfile())
        let tokens = InMemoryServerSessionTokenStore()
        tokens.writeFailure = errSecIO
        let store = makeControllableStore(api: api, tokenStore: tokens)

        let authenticated = await store.signInWithApple(
            permit: permitFor(store, .apple),
            identityToken: "t", authorizationCode: "c", rawNonce: "n"
        )

        XCTAssertFalse(authenticated)
        XCTAssertFalse(store.state.isAuthenticated)
        XCTAssertEqual(store.lastFailure, .couldNotStoreSession)
        XCTAssertEqual(tokens.read(), .absent)
        XCTAssertEqual(api.logoutTokens, ["orphan-session"])
    }

    func testAFailedVerificationHandsTheSessionBack() async {
        // Sign-in got a token but could not confirm it. That is not the
        // "offline restore" case — there the token is already ours and is
        // kept. Here it was never recorded, so it must not be stranded.
        let api = ControllableAccountAPI()
        api.appleResult = .success(makeSession(token: "unverified-session"))
        api.profileResult = .failure(AccountAPIError.unavailable)
        let tokens = InMemoryServerSessionTokenStore()
        let store = makeControllableStore(api: api, tokenStore: tokens)

        let authenticated = await store.signInWithApple(
            permit: permitFor(store, .apple),
            identityToken: "t", authorizationCode: "c", rawNonce: "n"
        )

        XCTAssertFalse(authenticated)
        XCTAssertEqual(tokens.read(), .absent)
        XCTAssertEqual(api.logoutTokens, ["unverified-session"])
    }

    func testARejectedSessionIsNotHandedBackBecauseItIsAlreadyDead() async {
        let api = ControllableAccountAPI()
        api.appleResult = .success(makeSession(token: "rejected-session"))
        api.profileResult = .failure(AccountAPIError.invalidCredentials)
        let tokens = InMemoryServerSessionTokenStore()
        let store = makeControllableStore(api: api, tokenStore: tokens)

        let authenticated = await store.signInWithApple(
            permit: permitFor(store, .apple),
            identityToken: "t", authorizationCode: "c", rawNonce: "n"
        )

        XCTAssertFalse(authenticated)
        XCTAssertEqual(tokens.read(), .absent)
        XCTAssertTrue(api.logoutTokens.isEmpty, "no point revoking a dead session")
    }

    func testTheTokenIsNeverStoredBeforeItIsVerified() async {
        // Ordering: /me is asked before the Keychain is written, so a token the
        // server will not honour never reaches disk.
        let api = ControllableAccountAPI()
        api.gated = ["profile"]
        api.appleResult = .success(makeSession(token: "unverified"))
        api.profileResult = .success(makeProfile())
        let tokens = InMemoryServerSessionTokenStore()
        let store = makeControllableStore(api: api, tokenStore: tokens)

        let signIn = Task {
            await store.signInWithApple(
                permit: permitFor(store, .apple),
                identityToken: "t", authorizationCode: "c", rawNonce: "n"
            )
        }
        await api.waitUntilEntered("profile")

        XCTAssertNil(tokens.storedToken, "nothing may be written before /me answers")

        api.release("profile")
        _ = await signIn.value
        XCTAssertEqual(tokens.read(), .token("unverified"))
    }
}

// MARK: - Keychain failures must not be reported as success

@MainActor
final class ServerAccountKeychainFailureTests: XCTestCase {

    func testLogoutWithAFailedDeleteIsNotGuest() async {
        // The token is still on disk, so the next launch would read it back.
        // Showing Guest would be a claim the device cannot support.
        let api = ControllableAccountAPI()
        let tokens = InMemoryServerSessionTokenStore(token: "stored-token")
        tokens.deleteFailure = errSecIO
        let store = makeControllableStore(api: api, tokenStore: tokens)

        let result = await store.logout()

        XCTAssertEqual(result, .localCleanupFailed)
        XCTAssertEqual(store.state, .localCleanupFailed)
        XCTAssertNotEqual(store.state, .guest)
        XCTAssertEqual(store.lastFailure, .couldNotClearSession)
        XCTAssertTrue(store.state.holdsSession)
        XCTAssertEqual(tokens.storedToken, "stored-token")
    }

    func testRestoreRejectionWithAFailedDeleteIsNotGuest() async {
        let api = ControllableAccountAPI()
        api.profileResult = .failure(AccountAPIError.invalidCredentials)
        let tokens = InMemoryServerSessionTokenStore(token: "stored-token")
        tokens.deleteFailure = errSecIO
        let store = makeControllableStore(api: api, tokenStore: tokens)

        await store.restore()

        XCTAssertEqual(store.state, .localCleanupFailed)
        XCTAssertNotEqual(store.state, .guest)
    }

    func testASucceedingDeleteReachesGuest() async {
        let api = ControllableAccountAPI()
        let tokens = InMemoryServerSessionTokenStore(token: "stored-token")
        let store = makeControllableStore(api: api, tokenStore: tokens)

        let result = await store.logout()
        XCTAssertEqual(result, .signedOut)
        XCTAssertEqual(store.state, .guest)
        XCTAssertFalse(store.state.holdsSession)
    }
}

// MARK: - Deletion contract

@MainActor
final class ServerAccountDeletionContractTests: XCTestCase {

    func testAnUnreadableKeychainSendsNoRequestAndClaimsNothing() async {
        // Without a token there is no authenticated DELETE to send — and a
        // request never sent cannot have deleted anything.
        let api = ControllableAccountAPI()
        let tokens = InMemoryServerSessionTokenStore(token: "stored-token")
        tokens.readFailure = errSecInteractionNotAllowed
        let store = makeControllableStore(api: api, tokenStore: tokens)

        let result = await store.deleteAccount()

        XCTAssertEqual(result, .notAttempted(.credentialUnavailable))
        XCTAssertTrue(api.deleteTokens.isEmpty, "no DELETE may be sent")
        XCTAssertEqual(store.lastFailure, .credentialUnavailable)
        // Nothing was destroyed on the strength of a read we could not do.
        tokens.readFailure = nil
        XCTAssertEqual(tokens.read(), .token("stored-token"))
    }

    func testAnAbsentTokenIsNotTreatedAsAlreadyDeleted() async {
        let api = ControllableAccountAPI()
        let store = makeControllableStore(
            api: api,
            tokenStore: InMemoryServerSessionTokenStore()
        )

        let result = await store.deleteAccount()

        XCTAssertEqual(result, .notAttempted(.notSignedIn))
        XCTAssertTrue(api.deleteTokens.isEmpty)
    }

    func testOnly200MeansDeleted() async {
        let api = ControllableAccountAPI()
        api.deleteResult = .success(.deleted)
        let store = makeControllableStore(
            api: api,
            tokenStore: InMemoryServerSessionTokenStore(token: "t")
        )

        let result = await store.deleteAccount()
        XCTAssertEqual(result, .deleted)
    }

    func test202MeansPending() async {
        let api = ControllableAccountAPI()
        api.deleteResult = .success(.pending)
        let store = makeControllableStore(
            api: api,
            tokenStore: InMemoryServerSessionTokenStore(token: "t")
        )

        let result = await store.deleteAccount()
        XCTAssertEqual(result, .pending)
    }

    func test401DoesNotMeanDeleted() async {
        // The lost-response case: the first DELETE succeeded server-side, its
        // response never arrived, and the retry uses a token the server has
        // already revoked. From here that is indistinguishable from a session
        // that simply expired — so claiming deletion would be a guess.
        let api = ControllableAccountAPI()
        api.deleteResult = .failure(AccountAPIError.invalidCredentials)
        let tokens = InMemoryServerSessionTokenStore(token: "revoked-token")
        let store = makeControllableStore(api: api, tokenStore: tokens)

        let result = await store.deleteAccount()

        XCTAssertEqual(result, .notConfirmed(.authenticationRequired))
        XCTAssertNotEqual(result, .deleted)
        // The token really is dead, so clearing it is right.
        XCTAssertEqual(tokens.read(), .absent)
    }

    func testServerTroubleDoesNotMeanDeleted() async {
        for error in [AccountAPIError.unavailable, .malformedResponse] {
            let api = ControllableAccountAPI()
            api.deleteResult = .failure(error)
            let tokens = InMemoryServerSessionTokenStore(token: "t")
            let store = makeControllableStore(api: api, tokenStore: tokens)

            let result = await store.deleteAccount()

            XCTAssertEqual(result, .notConfirmed(.unreachable), "for \(error)")
            // The session may still be valid; it is kept.
            XCTAssertEqual(tokens.read(), .token("t"))
        }
    }

    func testASupersededDeletionClaimsNothing() async {
        let api = ControllableAccountAPI()
        api.gated = ["delete"]
        api.deleteResult = .success(.deleted)
        let store = makeControllableStore(
            api: api,
            tokenStore: InMemoryServerSessionTokenStore(token: "t")
        )

        let deleting = Task { await store.deleteAccount() }
        await api.waitUntilEntered("delete")
        _ = await store.logout()
        api.release("delete")

        let result = await deleting.value
        XCTAssertEqual(result, .notAttempted(.superseded))
    }
}

// MARK: - One session at a time

@MainActor
final class ServerAccountExistingSessionTests: XCTestCase {

    func testAppleSignInIsRefusedWhileASessionIsHeld() async {
        // Signing in again would mint a second server session and overwrite
        // the first in the Keychain, leaving the original valid on the server
        // with nothing here tracking it. Refuse before the provider SDK or the
        // backend is touched, so no second session is ever minted.
        let api = ControllableAccountAPI()
        api.appleResult = .success(makeSession(token: "session-B"))
        api.profileResult = .success(makeProfile())
        let tokens = InMemoryServerSessionTokenStore(token: "session-A")
        let store = makeControllableStore(api: api, tokenStore: tokens)

        let authenticated = await store.signInWithApple(
            permit: permitFor(store, .apple),
            identityToken: "t", authorizationCode: "c", rawNonce: "n"
        )

        XCTAssertFalse(authenticated)
        XCTAssertEqual(store.lastFailure, .existingSessionHeld)
        // Nothing reached the backend, so nothing was issued to orphan.
        XCTAssertTrue(api.profileTokens.isEmpty)
        XCTAssertTrue(api.logoutTokens.isEmpty)
        // The existing session is untouched, and not revoked behind the user.
        XCTAssertEqual(tokens.read(), .token("session-A"))
    }

    func testGoogleSignInIsRefusedWhileASessionIsHeld() async {
        let api = ControllableAccountAPI()
        api.googleResult = .success(makeSession(token: "session-B"))
        let tokens = InMemoryServerSessionTokenStore(token: "session-A")
        let store = makeControllableStore(api: api, tokenStore: tokens)

        let authenticated = await store.signInWithGoogle(permit: permitFor(store, .google), idToken: "id-token")

        XCTAssertFalse(authenticated)
        XCTAssertEqual(store.lastFailure, .existingSessionHeld)
        XCTAssertTrue(api.profileTokens.isEmpty)
        XCTAssertEqual(tokens.read(), .token("session-A"))
    }

    func testRefusalDoesNotDropTheUserToGuest() async {
        // The refusal must not itself be a downgrade: the existing session is
        // still the current one.
        let api = ControllableAccountAPI()
        api.profileResult = .success(makeProfile())
        let tokens = InMemoryServerSessionTokenStore(token: "session-A")
        let store = makeControllableStore(api: api, tokenStore: tokens)
        await store.restore()
        XCTAssertTrue(store.state.isAuthenticated)

        _ = await store.signInWithApple(
            permit: permitFor(store, .apple),
            identityToken: "t", authorizationCode: "c", rawNonce: "n"
        )

        XCTAssertTrue(store.state.isAuthenticated, "still signed in as before")
        XCTAssertNotEqual(store.state, .guest)
    }

    func testSignInIsRefusedWhenTheKeychainCannotBeRead() async {
        // Unreadable is not empty. Proceeding could overwrite a session we
        // simply could not see.
        for provider in ["apple", "google"] {
            let api = ControllableAccountAPI()
            api.appleResult = .success(makeSession(token: "session-B"))
            api.googleResult = .success(makeSession(token: "session-B"))
            let tokens = InMemoryServerSessionTokenStore(token: "session-A")
            tokens.readFailure = errSecInteractionNotAllowed
            let store = makeControllableStore(api: api, tokenStore: tokens)

            let authenticated: Bool
            if provider == "apple" {
                authenticated = await store.signInWithApple(
                    permit: permitFor(store, .apple),
                    identityToken: "t", authorizationCode: "c", rawNonce: "n"
                )
            } else {
                authenticated = await store.signInWithGoogle(permit: permitFor(store, .google), idToken: "id-token")
            }

            XCTAssertFalse(authenticated, "\(provider)")
            XCTAssertEqual(store.lastFailure, .credentialUnavailable, "\(provider)")
            XCTAssertTrue(api.profileTokens.isEmpty, "\(provider)")
            XCTAssertNotEqual(store.state, .guest, "\(provider)")
            // Nothing was written over a Keychain we could not read.
            tokens.readFailure = nil
            XCTAssertEqual(tokens.read(), .token("session-A"), "\(provider)")
        }
    }

    func testSignInProceedsWhenTheKeychainIsConfirmedEmpty() async {
        let api = ControllableAccountAPI()
        api.appleResult = .success(makeSession(token: "session-new"))
        api.profileResult = .success(makeProfile())
        let tokens = InMemoryServerSessionTokenStore()
        let store = makeControllableStore(api: api, tokenStore: tokens)

        let authenticated = await store.signInWithApple(
            permit: permitFor(store, .apple),
            identityToken: "t", authorizationCode: "c", rawNonce: "n"
        )

        XCTAssertTrue(authenticated)
        XCTAssertEqual(tokens.read(), .token("session-new"))
    }
}

// MARK: - A failed write must reconcile with the disk

@MainActor
final class ServerAccountWriteFailureReconciliationTests: XCTestCase {

    /// Signs in against an empty Keychain whose write then fails, leaving
    /// `leftover` behind (whatever the disk turns out to hold afterwards).
    private func signInWithFailingWrite(
        leftover: String?,
        readFailureAfterwards: OSStatus? = nil
    ) async -> (ServerAccountStore, ControllableAccountAPI, InMemoryServerSessionTokenStore) {
        let api = ControllableAccountAPI()
        api.appleResult = .success(makeSession(token: "session-new"))
        api.profileResult = .success(makeProfile())
        let tokens = InMemoryServerSessionTokenStore()
        let store = makeControllableStore(api: api, tokenStore: tokens)

        tokens.writeFailure = errSecIO
        // The preflight must still see an empty Keychain — otherwise the
        // sign-in is refused and the write never happens. `leftover` is what
        // the disk turns out to hold *afterwards*, which is what
        // reconciliation has to cope with.
        tokens.tokenAfterFailedWrite = leftover
        tokens.readFailureAfterWrite = readFailureAfterwards

        _ = await store.signInWithApple(
            permit: permitFor(store, .apple),
            identityToken: "t", authorizationCode: "c", rawNonce: "n"
        )
        return (store, api, tokens)
    }

    func testAConfirmedEmptyKeychainMayReachGuest() async {
        let (store, api, _) = await signInWithFailingWrite(leftover: nil)

        XCTAssertEqual(store.state, .guest)
        XCTAssertFalse(store.state.holdsSession)
        XCTAssertEqual(store.lastFailure, .couldNotStoreSession)
        // The session we could not persist was handed back.
        XCTAssertEqual(api.logoutTokens, ["session-new"])
    }

    func testARetainedTokenForbidsGuest() async {
        // The write failed but an older token is still on disk. Showing Guest
        // would put the UI at odds with what the device actually holds — and
        // the next launch would restore that token.
        let (store, api, _) = await signInWithFailingWrite(leftover: "session-old")

        XCTAssertNotEqual(store.state, .guest)
        XCTAssertEqual(store.state, .localCleanupFailed)
        XCTAssertTrue(store.state.holdsSession)
        XCTAssertEqual(api.logoutTokens, ["session-new"], "only the new one")
    }

    func testAnUnreadableKeychainForbidsGuest() async {
        // We cannot prove the device holds nothing, so we cannot claim to be
        // signed out.
        let (store, _, _) = await signInWithFailingWrite(
            leftover: nil,
            readFailureAfterwards: errSecInteractionNotAllowed
        )

        XCTAssertNotEqual(store.state, .guest)
        XCTAssertEqual(store.state, .unreachable)
        XCTAssertTrue(store.state.holdsSession)
    }
}

// MARK: - Two real sign-ins racing

@MainActor
final class ServerAccountDoubleSignInTests: XCTestCase {

    func testTheNewerSignInWinsAndTheOlderRevokesItsOwnSession() async {
        // Apple A parks inside the backend exchange; Google B runs to
        // completion; then A resumes holding a session nobody wants.
        let api = ControllableAccountAPI()
        api.gated = ["apple"]
        api.appleResult = .success(makeSession(token: "session-A"))
        api.googleResult = .success(makeSession(token: "session-B"))
        api.profileResult = .success(makeProfile(providers: ["google"]))
        let tokens = InMemoryServerSessionTokenStore()
        let store = makeControllableStore(api: api, tokenStore: tokens)

        let applePermit = permitFor(store, .apple)
        let appleSignIn = Task {
            await store.signInWithApple(
                permit: applePermit,
                identityToken: "t", authorizationCode: "c", rawNonce: "n"
            )
        }
        // A real handshake: B does not start until A is provably parked.
        await api.waitUntilEntered("apple")
        releasePermit(applePermit, on: store)

        let googleSucceeded = await store.signInWithGoogle(
            permit: permitFor(store, .google),
            idToken: "id-token"
        )
        XCTAssertTrue(googleSucceeded)
        XCTAssertEqual(tokens.read(), .token("session-B"))

        api.release("apple")
        let appleSucceeded = await appleSignIn.value

        XCTAssertFalse(appleSucceeded, "the stale sign-in must not win")
        // B's token survives untouched — A must not delete or overwrite it.
        XCTAssertEqual(tokens.read(), .token("session-B"))
        XCTAssertTrue(store.state.isAuthenticated)
        // And A handed its own session back rather than stranding it.
        XCTAssertTrue(api.logoutTokens.contains("session-A"))
        XCTAssertFalse(
            api.logoutTokens.contains("session-B"),
            "the winner's session must not be revoked by the loser"
        )
    }

    func testAStaleSignInNeverDeletesTheWinnersToken() async {
        // The same shape, with the stale operation resuming after the winner
        // has already stored its token. A blind `delete()` here would sign the
        // user out of the session they just created.
        let api = ControllableAccountAPI()
        api.gated = ["apple"]
        api.appleResult = .success(makeSession(token: "session-A"))
        api.googleResult = .success(makeSession(token: "session-B"))
        api.profileResult = .success(makeProfile())
        let tokens = InMemoryServerSessionTokenStore()
        let store = makeControllableStore(api: api, tokenStore: tokens)

        let applePermit = permitFor(store, .apple)
        let appleSignIn = Task {
            await store.signInWithApple(
                permit: applePermit,
                identityToken: "t", authorizationCode: "c", rawNonce: "n"
            )
        }
        await api.waitUntilEntered("apple")
        releasePermit(applePermit, on: store)
        _ = await store.signInWithGoogle(
            permit: permitFor(store, .google),
            idToken: "id-token"
        )
        api.release("apple")
        _ = await appleSignIn.value

        XCTAssertEqual(tokens.read(), .token("session-B"))
        XCTAssertTrue(store.state.isAuthenticated)
    }

    func testTheRaceIsStableAcrossRepeatedRuns() async {
        // Deterministic, not lucky: the handshake means this holds every time
        // rather than depending on scheduler timing.
        for _ in 0..<20 {
            let api = ControllableAccountAPI()
            api.gated = ["apple"]
            api.appleResult = .success(makeSession(token: "session-A"))
            api.googleResult = .success(makeSession(token: "session-B"))
            api.profileResult = .success(makeProfile())
            let tokens = InMemoryServerSessionTokenStore()
            let store = makeControllableStore(api: api, tokenStore: tokens)

            let applePermit = permitFor(store, .apple)
            let appleSignIn = Task {
                await store.signInWithApple(
                    permit: applePermit,
                    identityToken: "t", authorizationCode: "c", rawNonce: "n"
                )
            }
            await api.waitUntilEntered("apple")
            releasePermit(applePermit, on: store)
            _ = await store.signInWithGoogle(
                permit: permitFor(store, .google),
                idToken: "id-token"
            )
            api.release("apple")
            let appleSucceeded = await appleSignIn.value

            XCTAssertFalse(appleSucceeded)
            XCTAssertEqual(tokens.read(), .token("session-B"))
        }
    }
}
