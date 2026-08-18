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
    var deleteResult: Result<Void, Error> = .success(())

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

    func deleteAccount(sessionToken: String) async throws {
        deleteTokens.append(sessionToken)
        try deleteResult.get()
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
        defer { store.deleteToken() }

        XCTAssertNil(store.readToken())
        XCTAssertTrue(store.saveToken("first-token"))
        XCTAssertEqual(store.readToken(), "first-token")

        XCTAssertTrue(store.saveToken("second-token"))
        XCTAssertEqual(store.readToken(), "second-token")

        XCTAssertTrue(store.deleteToken())
        XCTAssertNil(store.readToken())
    }

    func testDeletingNothingIsStillSuccess() throws {
        try skipUnlessKeychainIsAvailable()
        // "Nothing there" is the end state a delete wanted.
        XCTAssertTrue(makeStore().deleteToken())
    }

    func testTwoStoresDoNotSeeEachOther() throws {
        try skipUnlessKeychainIsAvailable()
        let a = makeStore()
        let b = makeStore()
        defer { a.deleteToken(); b.deleteToken() }

        XCTAssertTrue(a.saveToken("token-a"))
        XCTAssertNil(b.readToken())
    }

    func testStoredItemIsThisDeviceOnlyAfterFirstUnlock() throws {
        try skipUnlessKeychainIsAvailable()
        // ThisDeviceOnly keeps the session out of backups so a restored image
        // cannot carry a live session onto different hardware. AfterFirstUnlock
        // lets a background launch restore without waiting for an unlock.
        let service = Self.service
        let account = "accessibility-\(UUID().uuidString)"
        let store = KeychainServerSessionTokenStore(service: service, account: account)
        defer { store.deleteToken() }
        XCTAssertTrue(store.saveToken("token"))

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
        XCTAssertEqual(tokens.readToken(), "stored-token")
    }

    func testRejectedSessionIsDiscarded() async {
        let api = StubAccountAPI()
        api.profileResult = .failure(AccountAPIError.invalidCredentials)
        let tokens = InMemoryServerSessionTokenStore(token: "stored-token")
        let store = makeStore(api: api, tokenStore: tokens)

        await store.restore()

        XCTAssertEqual(store.state, .guest)
        XCTAssertNil(tokens.readToken(), "a rejected session must not be kept")
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
            XCTAssertEqual(tokens.readToken(), "stored-token", "for \(failure)")
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
        XCTAssertNil(tokens.readToken())
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
        XCTAssertEqual(tokens.readToken(), "stored-token")
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
            identityToken: "id-token",
            authorizationCode: "auth-code",
            rawNonce: "raw-nonce"
        )

        XCTAssertTrue(store.state.isAuthenticated)
        XCTAssertEqual(tokens.readToken(), "session-token-abc")
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
            identityToken: "id-token",
            authorizationCode: "",
            rawNonce: "raw-nonce"
        )

        XCTAssertFalse(store.state.isAuthenticated)
        XCTAssertEqual(store.lastFailure, .missingProviderCredential)
        XCTAssertTrue(api.appleRequests.isEmpty, "must not reach the server")
        XCTAssertNil(tokens.readToken())
    }

    func testAppleSignInRefusesWithoutATokenOrNonce() async {
        for (token, nonce) in [("", "n"), ("t", "")] {
            let api = StubAccountAPI()
            let store = makeStore(api: api, tokenStore: InMemoryServerSessionTokenStore())
            await store.signInWithApple(
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

        await store.signInWithGoogle(idToken: "google-id-token")

        XCTAssertTrue(store.state.isAuthenticated)
        XCTAssertEqual(tokens.readToken(), "google-session")
        XCTAssertEqual(api.googleRequests.first?.idToken, "google-id-token")
        // There is nowhere on the request to put a userID or an email, which
        // is the point — it is not a discipline anyone has to remember.
        XCTAssertEqual(api.googleRequests.first?.deviceName, "iPhone")
    }

    func testGoogleSignInRefusesAnEmptyIDToken() async {
        let api = StubAccountAPI()
        let store = makeStore(api: api, tokenStore: InMemoryServerSessionTokenStore())

        await store.signInWithGoogle(idToken: "")

        XCTAssertEqual(store.lastFailure, .missingProviderCredential)
        XCTAssertTrue(api.googleRequests.isEmpty)
    }

    func testSignInIsUnavailableWhenTheBuildHasNoAPI() async {
        // No fake success: the app does not claim a PulseCue account exists.
        let api = StubAccountAPI()
        api.configured = false
        let store = makeStore(api: api, tokenStore: InMemoryServerSessionTokenStore())

        await store.signInWithGoogle(idToken: "google-id-token")

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
            identityToken: "t", authorizationCode: "c", rawNonce: "n"
        )

        XCTAssertEqual(store.state, .guest)
        XCTAssertEqual(store.lastFailure, .rejected)
        XCTAssertNil(tokens.readToken())
    }

    func testASessionThatCannotBeStoredIsReportedRatherThanPretended() async {
        // A session we cannot persist would evaporate at the next launch and
        // look like a random sign-out.
        let api = StubAccountAPI()
        api.appleResult = .success(makeSession())
        api.profileResult = .success(makeProfile())
        let tokens = InMemoryServerSessionTokenStore()
        tokens.failsToSave = true
        let store = makeStore(api: api, tokenStore: tokens)

        await store.signInWithApple(
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

        let revoked = await store.logout()

        XCTAssertTrue(revoked)
        XCTAssertEqual(api.logoutTokens, ["stored-token"])
        XCTAssertNil(tokens.readToken())
        XCTAssertEqual(store.state, .guest)
    }

    func testLogoutStillWorksWhenTheServerIsUnreachable() async {
        // A user must never be stuck signed in because the network is down.
        let api = StubAccountAPI()
        api.logoutResult = .failure(AccountAPIError.unavailable)
        let tokens = InMemoryServerSessionTokenStore(token: "stored-token")
        let store = makeStore(api: api, tokenStore: tokens)

        let revoked = await store.logout()

        XCTAssertFalse(revoked, "the caller can see the server was not reached")
        XCTAssertNil(tokens.readToken(), "but the device is signed out regardless")
        XCTAssertEqual(store.state, .guest)
    }

    func testLogoutOfAnAlreadyDeadSessionIsSuccess() async {
        let api = StubAccountAPI()
        api.logoutResult = .failure(AccountAPIError.invalidCredentials)
        let tokens = InMemoryServerSessionTokenStore(token: "stored-token")
        let store = makeStore(api: api, tokenStore: tokens)

        let outcome = await store.logout()
        XCTAssertTrue(outcome)
        XCTAssertNil(tokens.readToken())
    }

    func testDeletionClearsTheSessionOnSuccess() async {
        let api = StubAccountAPI()
        let tokens = InMemoryServerSessionTokenStore(token: "stored-token")
        let store = makeStore(api: api, tokenStore: tokens)

        let deleted = await store.deleteAccount()
        XCTAssertTrue(deleted)

        XCTAssertEqual(api.deleteTokens, ["stored-token"])
        XCTAssertNil(tokens.readToken())
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
        XCTAssertFalse(deleted)

        XCTAssertEqual(tokens.readToken(), "stored-token")
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
