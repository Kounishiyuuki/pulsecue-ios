//
//  APIIntegrationFoundation.swift
//  Pulse Cue
//
//  iOS-side API integration *foundation* for a future real-backend phase.
//  This file is additive and intentionally NOT wired into any existing flow:
//  the app stays local-first and performs no API networking by default.
//
//  Design mirrors the existing `AITrainingPlanEndpointClient` boundaries so
//  there is one consistent, safe networking pattern across the app:
//    - **No production / Worker URL default.** Real networking is reachable
//      only through `.custom(baseURL:)`, whose base URL must be injected.
//      The shipping default is `.disabled`, so Release can never silently
//      reach a backend.
//    - **No credential storage.** An optional `tokenProvider` closure may
//      supply a short-lived `Authorization: Bearer` value when (and only
//      when) injected. Nothing here reads/writes Keychain, UserDefaults,
//      Info.plist, or any token store. No refresh / OAuth exchange.
//    - **No user-data sync.** This is request plumbing only; it starts no
//      background sync and touches no SwiftData models.
//    - Auth seam: tokens flow in via the closure only — `AuthSession`
//      remains provider/displayName/email and gains no token fields.
//

import Foundation

// MARK: - Environment

/// Where the iOS app may talk to a future PulseCue backend.
///
/// Defaults to `.disabled` (`APIEnvironment.default`), so the app performs
/// NO API networking unless a later phase explicitly injects a custom
/// configuration. There is intentionally no production / `*.workers.dev`
/// URL baked in — `.custom(baseURL:)` must be supplied to reach a network.
enum APIEnvironment: Equatable {
    /// No backend. The current local-first default — no networking.
    case disabled
    /// In-memory mock for tests / dev. No real networking.
    case mock
    /// Explicitly injected base URL. The ONLY case that permits networking.
    case custom(baseURL: URL)

    /// The shipping default: disabled.
    static let `default`: APIEnvironment = .disabled

    /// The base URL, present only for `.custom`. `nil` for disabled / mock,
    /// so callers can never accidentally hit a production endpoint.
    var baseURL: URL? {
        if case let .custom(baseURL) = self { return baseURL }
        return nil
    }

    /// Whether real network requests are permitted in this environment.
    var allowsNetworking: Bool {
        if case .custom = self { return true }
        return false
    }
}

// MARK: - Configuration

/// Immutable API configuration: an environment, an optional async bearer
/// token provider (closure only — nothing is persisted), and a timeout.
/// No credentials, no Keychain, no UserDefaults.
struct APIConfiguration {
    let environment: APIEnvironment
    /// Optional short-lived bearer token source. When `nil`, no
    /// `Authorization` header is sent. `async` so a future provider can mint
    /// on demand without this layer storing anything. Mirrors
    /// `AITrainingPlanEndpointClient.tokenProvider`.
    let tokenProvider: (@Sendable () async -> String?)?
    /// Request timeout in seconds.
    let timeout: TimeInterval

    init(
        environment: APIEnvironment = .default,
        tokenProvider: (@Sendable () async -> String?)? = nil,
        timeout: TimeInterval = 30
    ) {
        self.environment = environment
        self.tokenProvider = tokenProvider
        self.timeout = timeout
    }

    /// The local-first default: disabled, no token, no networking. This is
    /// what every shipping call site gets unless a later phase injects more.
    static let localFirstDefault = APIConfiguration(environment: .disabled)
}

// MARK: - Errors

/// Typed errors surfaced by the API client foundation. No raw bodies or
/// provider-internal details are represented here.
enum APIClientError: Error, Equatable, Sendable {
    /// The environment forbids networking (`.disabled` / `.mock` without a
    /// responder). The shipping default surfaces this rather than reaching
    /// any network.
    case disabled
    case invalidRequest
    case transportFailed
    case timeout
    case unauthorized
    case server(status: Int)
    case invalidResponse
}

// MARK: - Request

/// Minimal, transport-independent description of an API request. Turned into
/// a `URLRequest` by `APIRequestBuilder` against an injected base URL.
struct APIRequest: Equatable {
    enum Method: String, Equatable {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
    }

    let method: Method
    /// Path relative to the configuration's base URL.
    let path: String
    var headers: [String: String]
    var body: Data?

    init(method: Method = .get, path: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

// MARK: - Request building

/// Builds a `URLRequest` from an `APIRequest` against an injected base URL,
/// attaching `Authorization: Bearer` ONLY when the token provider yields a
/// non-empty value. The token is never persisted or logged.
struct APIRequestBuilder {
    let baseURL: URL
    let tokenProvider: (@Sendable () async -> String?)?
    let timeout: TimeInterval

    init(
        baseURL: URL,
        tokenProvider: (@Sendable () async -> String?)? = nil,
        timeout: TimeInterval = 30
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.timeout = timeout
    }

    func makeURLRequest(for request: APIRequest) async throws -> URLRequest {
        guard let url = URL(string: request.path, relativeTo: baseURL) else {
            throw APIClientError.invalidRequest
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = timeout
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        urlRequest.httpBody = request.body
        // Authorization only when a token is explicitly injected & non-empty.
        if let tokenProvider, let token = await tokenProvider(), !token.isEmpty {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return urlRequest
    }
}

// MARK: - Client protocol + implementations

/// Protocol-based API client seam. Conformers decide whether and how to
/// perform networking. The shipping app uses `DisabledAPIClient`.
protocol APIClient {
    func send(_ request: APIRequest) async throws -> Data
}

/// The current local-first default: refuses all requests. No networking,
/// ever. Lets app code depend on the `APIClient` seam with no active backend.
struct DisabledAPIClient: APIClient {
    func send(_ request: APIRequest) async throws -> Data {
        throw APIClientError.disabled
    }
}

/// Test / dev client that returns canned data via an injected responder and
/// performs no networking. Defaults to throwing `.disabled`, so even a
/// misuse in app code cannot reach a network.
struct MockAPIClient: APIClient {
    let responder: (@Sendable (APIRequest) async throws -> Data)?

    init(responder: (@Sendable (APIRequest) async throws -> Data)? = nil) {
        self.responder = responder
    }

    func send(_ request: APIRequest) async throws -> Data {
        guard let responder else { throw APIClientError.disabled }
        return try await responder(request)
    }
}

/// URLSession-backed client. Constructed ONLY from a `.custom` environment
/// with an explicitly injected base URL — there is no production default and
/// it is not wired into any app flow. Mirrors `AITrainingPlanEndpointClient`.
struct URLSessionAPIClient: APIClient {
    let builder: APIRequestBuilder
    let session: URLSession

    init(
        baseURL: URL,
        tokenProvider: (@Sendable () async -> String?)? = nil,
        timeout: TimeInterval = 30,
        session: URLSession = .shared
    ) {
        self.builder = APIRequestBuilder(baseURL: baseURL, tokenProvider: tokenProvider, timeout: timeout)
        self.session = session
    }

    func send(_ request: APIRequest) async throws -> Data {
        let urlRequest = try await builder.makeURLRequest(for: request)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .timedOut {
            throw APIClientError.timeout
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIClientError.transportFailed
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }
        if http.statusCode == 401 { throw APIClientError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw APIClientError.server(status: http.statusCode)
        }
        return data
    }
}

// MARK: - Factory

/// Builds the `APIClient` for a configuration. The default is the disabled,
/// no-networking client; the URLSession client is returned ONLY for a
/// `.custom(baseURL:)` environment. There is no production URL anywhere, so
/// Release can never silently reach a backend. Mirrors
/// `AITrainingPlanProviderFactory`.
enum APIClientFactory {
    static func makeClient(for configuration: APIConfiguration = .localFirstDefault) -> APIClient {
        switch configuration.environment {
        case .disabled:
            return DisabledAPIClient()
        case .mock:
            return MockAPIClient()
        case let .custom(baseURL):
            return URLSessionAPIClient(
                baseURL: baseURL,
                tokenProvider: configuration.tokenProvider,
                timeout: configuration.timeout
            )
        }
    }

    /// Spelled-out default for shipping call sites: no networking.
    static func makeDefaultClient() -> APIClient {
        makeClient(for: .localFirstDefault)
    }
}
