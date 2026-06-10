//
//  AITrainingPlanProviderFactoryTests.swift
//  Pulse CueTests
//
//  Verifies the provider-selection boundary: the factory defaults to the
//  offline mock, only builds the endpoint client when explicit
//  configuration is supplied, and passes injected dependencies through.
//  No network is performed — endpoint mode is constructed and inspected,
//  never invoked.
//

import Foundation
import Testing
@testable import Pulse_Cue

// `@MainActor` because the app target uses `SWIFT_DEFAULT_ACTOR_ISOLATION =
// MainActor`, so the factory, providers, and `MockAITrainingPlanChatView`
// are main-actor isolated. Mirrors `AITrainingPlanEndpointClientTests`.
@Suite
@MainActor
struct AITrainingPlanProviderFactoryTests {

    private func endpointConfig(
        baseURL: URL = URL(string: "https://backend.test/")!,
        tokenProvider: (@Sendable () async -> String?)? = nil
    ) -> AITrainingPlanEndpointConfiguration {
        AITrainingPlanEndpointConfiguration(baseURL: baseURL, tokenProvider: tokenProvider)
    }

    // MARK: - Default / mock selection

    @Test
    func defaultProviderIsMock() {
        let provider = AITrainingPlanProviderFactory.makeProvider()
        #expect(provider is MockAITrainingPlanProvider)
    }

    @Test
    func explicitMockModeReturnsMock() {
        let provider = AITrainingPlanProviderFactory.makeProvider(mode: .mock)
        #expect(provider is MockAITrainingPlanProvider)
    }

    @Test
    func mockModeRequiresNoConfigurationOrToken() async throws {
        // The mock needs no baseURL/token and still produces a response.
        let provider = AITrainingPlanProviderFactory.makeProvider(mode: .mock)
        let response = try await provider.generatePlan(
            for: AITrainingPlanRequest(userMessage: "胸を鍛えたい", daysPerWeek: 2)
        )
        #expect(!response.sessions.isEmpty)
    }

    // MARK: - Endpoint selection

    @Test
    func endpointModeReturnsEndpointClientOnlyWithExplicitConfig() throws {
        let provider = AITrainingPlanProviderFactory.makeProvider(
            mode: .endpoint(endpointConfig())
        )
        #expect(provider is AITrainingPlanEndpointClient)
    }

    @Test
    func endpointClientUsesInjectedBaseURL() throws {
        let url = URL(string: "https://backend.test/")!
        let provider = AITrainingPlanProviderFactory.makeProvider(
            mode: .endpoint(endpointConfig(baseURL: url))
        )
        let client = try #require(provider as? AITrainingPlanEndpointClient)
        #expect(client.baseURL == url)
    }

    // MARK: - Token pass-through (endpoint mode only)

    @Test
    func injectedTokenProviderIsPassedThroughInEndpointMode() async throws {
        let provider = AITrainingPlanProviderFactory.makeProvider(
            mode: .endpoint(endpointConfig(tokenProvider: { "short-lived-token" }))
        )
        let client = try #require(provider as? AITrainingPlanEndpointClient)
        let token = await client.tokenProvider?()
        #expect(token == "short-lived-token")
    }

    @Test
    func endpointModeWithoutTokenProviderHasNoToken() throws {
        let provider = AITrainingPlanProviderFactory.makeProvider(
            mode: .endpoint(endpointConfig(tokenProvider: nil))
        )
        let client = try #require(provider as? AITrainingPlanEndpointClient)
        #expect(client.tokenProvider == nil)
    }

    @Test
    func mockModeNeverCarriesAToken() {
        // A mock provider is not the endpoint client and so exposes no token.
        let provider = AITrainingPlanProviderFactory.makeProvider(mode: .mock)
        #expect((provider as? AITrainingPlanEndpointClient) == nil)
    }

    // MARK: - Configuration defaults

    @Test
    func endpointConfigurationDefaultsAreSafe() {
        let config = AITrainingPlanEndpointConfiguration(
            baseURL: URL(string: "https://backend.test/")!
        )
        #expect(config.tokenProvider == nil)
        #expect(config.timeout == 30)
        #expect(config.session === URLSession.shared)
    }

    // MARK: - Convenience seams (dev-only endpoint wiring)

    @Test
    func makeDefaultProviderReturnsMock() {
        let provider = AITrainingPlanProviderFactory.makeDefaultProvider()
        #expect(provider is MockAITrainingPlanProvider)
        #expect((provider as? AITrainingPlanEndpointClient) == nil)
    }

    @Test
    func makeEndpointProviderRequiresExplicitConfigAndReturnsEndpointClient() throws {
        let url = URL(string: "https://backend.test/")!
        let provider = AITrainingPlanProviderFactory.makeEndpointProvider(
            config: endpointConfig(baseURL: url)
        )
        let client = try #require(provider as? AITrainingPlanEndpointClient)
        #expect(client.baseURL == url)
    }

    @Test
    func makeEndpointProviderPassesInjectedTokenProviderThrough() async throws {
        let provider = AITrainingPlanProviderFactory.makeEndpointProvider(
            config: endpointConfig(tokenProvider: { "short-lived-token" })
        )
        let client = try #require(provider as? AITrainingPlanEndpointClient)
        let token = await client.tokenProvider?()
        #expect(token == "short-lived-token")
    }

    @Test
    func makeEndpointProviderHasNoTokenWhenNoneInjected() throws {
        let provider = AITrainingPlanProviderFactory.makeEndpointProvider(
            config: endpointConfig(tokenProvider: nil)
        )
        let client = try #require(provider as? AITrainingPlanEndpointClient)
        #expect(client.tokenProvider == nil)
    }

    // MARK: - View wiring (default stays mock; dev seam is explicit)

    @Test
    func defaultChatViewInitRequiresNoEndpointConfiguration() {
        // The shipping/default initializer takes no endpoint config and
        // builds without one — proving normal users stay off the endpoint.
        _ = MockAITrainingPlanChatView()
    }

    @Test
    func devEndpointChatViewInitAcceptsExplicitConfiguration() {
        // The DEBUG-only dev seam constructs the screen from explicit local
        // configuration. No URL/token is read from storage; the caller
        // supplies a fake test URL.
        _ = MockAITrainingPlanChatView(
            endpointConfiguration: endpointConfig()
        )
    }

    // MARK: - QA request machine ids (endpoint path must send real catalog ids)

    @Test
    func endpointQARequestSendsNonEmptyRealCatalogMachineIds() {
        let ids = MockAITrainingPlanChatView.qaRequestMachineIds(isEndpointQA: true)
        #expect(!ids.isEmpty)
        // Every id must resolve in the local catalog so the normalizer keeps it.
        let catalog = Set(MachineCatalog.all.map(\.id))
        #expect(ids.allSatisfy { catalog.contains($0) })
        #expect(ids == MachineCatalog.all.map(\.id)) // deterministic
    }

    @Test
    func offlineRequestSendsNoMachineIdsSoMockFallbackIsUnchanged() {
        // The offline/default path sends none; the mock fills the catalog
        // itself, so the shipping screen's output is unchanged.
        #expect(MockAITrainingPlanChatView.qaRequestMachineIds(isEndpointQA: false).isEmpty)
    }

    @Test
    func catalogIdsRoundTripIntoNonEmptyNormalizedSessions() {
        // Reproduces the server mock shape: sessions referencing real catalog
        // ids should normalize into non-empty sessions (the 0-session symptom
        // was caused by sending no availableMachineIds, not a catalog mismatch).
        let ids = MockAITrainingPlanChatView.qaRequestMachineIds(isEndpointQA: true)
        let response = AITrainingPlanResponse(
            title: "QA",
            sessions: [
                AITrainingSessionResponse(title: "Day 1", exerciseMachineIds: Array(ids.prefix(2))),
                AITrainingSessionResponse(title: "Day 2", exerciseMachineIds: Array(ids.dropFirst(2).prefix(2))),
            ]
        )
        let candidate = AITrainingPlanNormalizer.normalize(
            response: response,
            request: AITrainingPlanRequest(availableMachineIds: ids)
        )
        #expect(!candidate.sessions.isEmpty)
        #expect(candidate.sessions.allSatisfy { !$0.exercises.isEmpty })
    }

#if DEBUG
    // MARK: - DEBUG-only local QA harness configuration

    @Test
    func debugLocalMockConfigurationIsLoopbackOnlyWithNoToken() {
        let config = AITrainingPlanEndpointConfiguration.debugLocalMock
        // Loopback only — never a production host or Worker URL.
        #expect(config.baseURL.host == "127.0.0.1")
        #expect(config.baseURL.scheme == "http")
        // No token is bundled with the QA configuration.
        #expect(config.tokenProvider == nil)
    }

    @Test
    func debugLocalMockBuildsEndpointClientForLocalBaseURL() throws {
        let config = AITrainingPlanEndpointConfiguration.debugLocalMock
        let provider = AITrainingPlanProviderFactory.makeEndpointProvider(config: config)
        let client = try #require(provider as? AITrainingPlanEndpointClient)
        #expect(client.baseURL == config.baseURL)
        #expect(client.tokenProvider == nil)
    }

    @Test
    func debugEndpointQAChatViewCanBeBuiltFromLocalMock() {
        // The DEBUG QA Settings entry builds the screen from the loopback
        // configuration; this mirrors that call site without any network.
        _ = MockAITrainingPlanChatView(endpointConfiguration: .debugLocalMock)
    }

    // MARK: - DEBUG-only fake-token QA configuration

    @Test
    func debugFakeTokenConfigStaysLoopbackAndInjectsValidToken() async throws {
        let config = AITrainingPlanEndpointConfiguration.debugLocalMockWithFakeToken()
        // Same loopback target as the no-token QA config.
        #expect(config.baseURL == AITrainingPlanEndpointConfiguration.debugLocalMock.baseURL)
        #expect(config.baseURL.host == "127.0.0.1")
        // Defaults to the fake VALID token (success path).
        let token = await config.tokenProvider?()
        #expect(token == AITrainingPlanEndpointConfiguration.DebugFakeToken.valid)
        #expect(token == "fake-valid-ai-training-plan-token")
    }

    @Test
    func debugFakeTokenConfigCanInjectExpiredAndWrongScopeTokens() async throws {
        let expired = AITrainingPlanEndpointConfiguration.debugLocalMockWithFakeToken(
            AITrainingPlanEndpointConfiguration.DebugFakeToken.expired
        )
        let wrongScope = AITrainingPlanEndpointConfiguration.debugLocalMockWithFakeToken(
            AITrainingPlanEndpointConfiguration.DebugFakeToken.wrongScope
        )
        #expect(await expired.tokenProvider?() == "fake-expired-ai-training-plan-token")
        #expect(await wrongScope.tokenProvider?() == "fake-wrong-scope-ai-token")
    }

    @Test
    func debugFakeTokenConfigBuildsEndpointClientCarryingTheFakeToken() async throws {
        let config = AITrainingPlanEndpointConfiguration.debugLocalMockWithFakeToken()
        let provider = AITrainingPlanProviderFactory.makeEndpointProvider(config: config)
        let client = try #require(provider as? AITrainingPlanEndpointClient)
        #expect(client.baseURL == config.baseURL)
        // The endpoint client carries the injected fake token provider.
        #expect(await client.tokenProvider?() == "fake-valid-ai-training-plan-token")
    }

    @Test
    func noTokenQAConfigStillHasNoToken() {
        // The original loopback QA config remains unauthenticated.
        #expect(AITrainingPlanEndpointConfiguration.debugLocalMock.tokenProvider == nil)
    }

    @Test
    func debugFakeTokenChatViewCanBeBuilt() {
        // Mirrors the fake-token QA Settings entry; no network performed.
        _ = MockAITrainingPlanChatView(
            endpointConfiguration: .debugLocalMockWithFakeToken()
        )
    }
#endif
}
