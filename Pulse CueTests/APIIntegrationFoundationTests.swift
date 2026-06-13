//
//  APIIntegrationFoundationTests.swift
//  Pulse CueTests
//
//  Verifies the API integration *foundation* boundaries: the default is
//  disabled (no networking), there is no production / Worker URL baked in,
//  Authorization is attached only when a token is explicitly injected, and
//  no token-persistence path exists. No real network is performed — the
//  disabled / mock paths are exercised, and request building is inspected.
//

import Foundation
import Testing
@testable import Pulse_Cue

// `@MainActor` because the app target uses `SWIFT_DEFAULT_ACTOR_ISOLATION =
// MainActor`, so the foundation types are main-actor isolated. Mirrors
// `AITrainingPlanProviderFactoryTests`.
@Suite
@MainActor
struct APIIntegrationFoundationTests {

    // MARK: - Environment / configuration defaults

    @Test
    func defaultEnvironmentIsDisabledWithNoBaseURL() {
        #expect(APIEnvironment.default == .disabled)
        #expect(APIEnvironment.default.baseURL == nil)
        #expect(APIEnvironment.default.allowsNetworking == false)
    }

    @Test
    func mockEnvironmentPerformsNoNetworkingAndHasNoBaseURL() {
        #expect(APIEnvironment.mock.baseURL == nil)
        #expect(APIEnvironment.mock.allowsNetworking == false)
    }

    @Test
    func customEnvironmentExposesOnlyTheInjectedBaseURL() {
        let url = URL(string: "https://backend.test/")!
        let env = APIEnvironment.custom(baseURL: url)
        #expect(env.baseURL == url)
        #expect(env.allowsNetworking == true)
    }

    @Test
    func localFirstDefaultConfigurationIsDisabledWithNoToken() {
        let config = APIConfiguration.localFirstDefault
        #expect(config.environment == .disabled)
        #expect(config.tokenProvider == nil)
    }

    @Test
    func configurationDefaultInitIsDisabled() {
        // No production / Worker URL default: a bare configuration is disabled.
        let config = APIConfiguration()
        #expect(config.environment == .disabled)
        #expect(config.environment.baseURL == nil)
    }

    // MARK: - Factory: no production default, disabled/mock do not network

    @Test
    func defaultClientIsDisabledAndRefusesNetworking() async {
        let client = APIClientFactory.makeDefaultClient()
        await #expect(throws: APIClientError.disabled) {
            _ = try await client.send(APIRequest(path: "anything"))
        }
    }

    @Test
    func disabledEnvironmentClientThrowsDisabled() async {
        let client = APIClientFactory.makeClient(for: APIConfiguration(environment: .disabled))
        await #expect(throws: APIClientError.disabled) {
            _ = try await client.send(APIRequest(method: .post, path: "x"))
        }
    }

    @Test
    func mockEnvironmentClientThrowsDisabledWithoutResponder() async {
        let client = APIClientFactory.makeClient(for: APIConfiguration(environment: .mock))
        await #expect(throws: APIClientError.disabled) {
            _ = try await client.send(APIRequest(path: "x"))
        }
    }

    @Test
    func mockClientWithResponderReturnsCannedDataWithoutNetworking() async throws {
        let canned = Data("ok".utf8)
        let client = MockAPIClient { _ in canned }
        let data = try await client.send(APIRequest(path: "x"))
        #expect(data == canned)
    }

    // MARK: - Request building: Authorization only when token injected

    @Test
    func requestBuilderOmitsAuthorizationWhenNoTokenProvider() async throws {
        let builder = APIRequestBuilder(baseURL: URL(string: "https://backend.test/")!)
        let urlRequest = try await builder.makeURLRequest(for: APIRequest(path: "ping"))
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(urlRequest.url?.absoluteString == "https://backend.test/ping")
    }

    @Test
    func requestBuilderOmitsAuthorizationWhenTokenProviderReturnsNil() async throws {
        let builder = APIRequestBuilder(
            baseURL: URL(string: "https://backend.test/")!,
            tokenProvider: { nil }
        )
        let urlRequest = try await builder.makeURLRequest(for: APIRequest(path: "ping"))
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func requestBuilderOmitsAuthorizationWhenTokenIsEmpty() async throws {
        let builder = APIRequestBuilder(
            baseURL: URL(string: "https://backend.test/")!,
            tokenProvider: { "" }
        )
        let urlRequest = try await builder.makeURLRequest(for: APIRequest(path: "ping"))
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func requestBuilderAddsAuthorizationOnlyWhenTokenProvided() async throws {
        let builder = APIRequestBuilder(
            baseURL: URL(string: "https://backend.test/")!,
            tokenProvider: { "abc123" }
        )
        let urlRequest = try await builder.makeURLRequest(for: APIRequest(path: "ping"))
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer abc123")
    }

    @Test
    func requestBuilderPassesMethodHeadersAndBody() async throws {
        let builder = APIRequestBuilder(baseURL: URL(string: "https://backend.test/")!)
        let body = Data("{}".utf8)
        let request = APIRequest(
            method: .post,
            path: "echo",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        let urlRequest = try await builder.makeURLRequest(for: request)
        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(urlRequest.httpBody == body)
    }

    // MARK: - No token-persistence path

    @Test
    func tokenProviderIsNotRetainedAsCredentialState() async throws {
        // The builder holds only the closure; calling it twice re-invokes the
        // provider rather than caching a token, proving nothing is persisted.
        let callCount = TokenCallCounter()
        let builder = APIRequestBuilder(
            baseURL: URL(string: "https://backend.test/")!,
            tokenProvider: { await callCount.next() }
        )
        let first = try await builder.makeURLRequest(for: APIRequest(path: "a"))
        let second = try await builder.makeURLRequest(for: APIRequest(path: "b"))
        // Distinct tokens each call → the provider is the only source of
        // truth; the builder caches/persists nothing.
        #expect(first.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
        #expect(second.value(forHTTPHeaderField: "Authorization") == "Bearer token-2")
        #expect(await callCount.count == 2)
    }

    /// Actor counter that yields a fresh token per call, so the test can prove
    /// the builder re-invokes the provider instead of caching a credential.
    private actor TokenCallCounter {
        private(set) var count = 0
        func next() -> String {
            count += 1
            return "token-\(count)"
        }
    }
}
