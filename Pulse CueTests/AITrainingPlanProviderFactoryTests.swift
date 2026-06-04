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
}
