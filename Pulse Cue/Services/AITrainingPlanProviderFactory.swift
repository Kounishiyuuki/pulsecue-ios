//
//  AITrainingPlanProviderFactory.swift
//  Pulse Cue
//
//  Explicit selection boundary between the offline `MockAITrainingPlanProvider`
//  and the network-capable `AITrainingPlanEndpointClient`, both of which
//  conform to `AITrainingPlanProviding`. Call sites keep depending on the
//  protocol; this factory decides *which* conformer to construct.
//
//  Boundaries (locked for this PR):
//   - **Default is mock.** `makeProvider()` with no arguments returns
//     `MockAITrainingPlanProvider`. No call site gets the endpoint client
//     unless it explicitly passes `.endpoint(config)`.
//   - **Endpoint mode requires injected configuration.** The only way to
//     reach the endpoint client is to supply an
//     `AITrainingPlanEndpointConfiguration`, whose `baseURL` is
//     non-optional — so an endpoint provider cannot be expressed without a
//     base URL. There is NO default / production / `*.workers.dev` URL.
//   - **No ambient configuration.** This file never reads Info.plist /
//     xcconfig / UserDefaults / Keychain / environment variables, and
//     hardcodes no URL, token, or secret.
//   - **Not wired into production UI by default.** `MockAITrainingPlanChatView`
//     still resolves to the mock provider via `makeProvider()`.
//

import Foundation

// MARK: - Endpoint configuration

/// Everything needed to construct an `AITrainingPlanEndpointClient`,
/// supplied explicitly by the caller. There are no production defaults:
/// `baseURL` must be provided, so endpoint mode is impossible to express
/// without one. `session` / `tokenProvider` / `timeout` mirror the client's
/// own injectable dependencies.
struct AITrainingPlanEndpointConfiguration {
    /// Base URL of the PulseCue backend proxy. Injected — no default.
    let baseURL: URL
    /// Transport. Defaults to `.shared`; tests inject a stubbed session.
    let session: URLSession
    /// Optional source of a short-lived bearer token. When `nil`, the
    /// client sends no `Authorization` header. Nothing is persisted here.
    let tokenProvider: (@Sendable () async -> String?)?
    /// Request timeout in seconds.
    let timeout: TimeInterval

    init(
        baseURL: URL,
        session: URLSession = .shared,
        tokenProvider: (@Sendable () async -> String?)? = nil,
        timeout: TimeInterval = 30
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
        self.timeout = timeout
    }
}

// MARK: - Provider mode

/// Which `AITrainingPlanProviding` conformer to build. `endpoint` carries
/// its required configuration in the associated value, so there is no way
/// to ask for the network provider without supplying a `baseURL`.
enum AITrainingPlanProviderMode {
    case mock
    case endpoint(AITrainingPlanEndpointConfiguration)
}

// MARK: - Factory

/// Constructs the chosen provider. Default is the offline mock; the
/// endpoint client is only built when `.endpoint(config)` is passed.
enum AITrainingPlanProviderFactory {
    static func makeProvider(
        mode: AITrainingPlanProviderMode = .mock
    ) -> AITrainingPlanProviding {
        switch mode {
        case .mock:
            return MockAITrainingPlanProvider()
        case .endpoint(let config):
            return AITrainingPlanEndpointClient(
                baseURL: config.baseURL,
                session: config.session,
                tokenProvider: config.tokenProvider,
                timeout: config.timeout
            )
        }
    }
}
