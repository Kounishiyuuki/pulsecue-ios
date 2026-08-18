//
//  PulseCueAccountAPI.swift
//  Pulse Cue
//
//  The five account calls, and — more importantly — how their failures are
//  classified.
//
//  The classification is the part that matters, because the app makes a
//  destructive decision from it. A `401` means the session is genuinely dead
//  and the Keychain copy should be thrown away. A timeout on the train means
//  nothing about the session at all, and throwing the token away there would
//  sign the user out for riding through a tunnel. Those two must never
//  collapse into "the request failed".
//
//  So `AccountAPIError` separates:
//
//    .invalidCredentials — the server said no. Drop the session.
//    .unavailable        — network, timeout, 5xx, 503. Keep the session.
//    .notConfigured      — no API URL in this build. Keep whatever exists.
//    .malformedResponse  — we got something we cannot read. Treat as
//                          unavailable, never as a verdict on the session.
//
//  Nothing here logs a token, an identity token, or an authorization code.
//

import Foundation

// MARK: - Wire types

/// What the server returns from a successful sign-in.
struct ServerSessionResponse: Decodable, Equatable {
    let sessionToken: String
    let expiresAt: Int
    let user: ServerSessionUser

    struct ServerSessionUser: Decodable, Equatable {
        let id: String
        let created: Bool
    }
}

/// The allowlisted profile from `GET /v1/me`.
struct ServerAccountProfile: Decodable, Equatable {
    let user: User
    let linkedProviders: [LinkedProvider]
    let session: Session

    struct User: Decodable, Equatable {
        let id: String
        let state: String
        let displayName: String?
        let createdAt: Int
    }

    struct LinkedProvider: Decodable, Equatable {
        let provider: String
        let linkedAt: Int
    }

    struct Session: Decodable, Equatable {
        let expiresAt: Int
    }

    var isActive: Bool { user.state == "active" }
    var hasApple: Bool { linkedProviders.contains { $0.provider == "apple" } }
    var hasGoogle: Bool { linkedProviders.contains { $0.provider == "google" } }
}

// MARK: - Errors

enum AccountAPIError: Error, Equatable {
    /// The server rejected the credential or session. Safe to drop it.
    case invalidCredentials
    /// Transport or server-side trouble. Says nothing about the session.
    case unavailable
    /// No API base URL in this build.
    case notConfigured
    /// A response we could not read. Deliberately not a session verdict.
    case malformedResponse

    /// Whether a stored session should be discarded because of this error.
    ///
    /// Only one case says yes, and that is the whole point of the type.
    var invalidatesStoredSession: Bool {
        self == .invalidCredentials
    }
}

// MARK: - Transport

/// The single seam the tests replace. Keeps `URLSession` out of the store.
protocol AccountHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionAccountTransport: AccountHTTPTransport {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            // Short enough that a dead network does not hold a launch, long
            // enough for a slow cellular handshake.
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AccountAPIError.malformedResponse
        }
        return (data, http)
    }
}

// MARK: - Client

protocol PulseCueAccountAPI: Sendable {
    var isConfigured: Bool { get }
    func signInWithApple(_ request: AppleSignInRequest) async throws -> ServerSessionResponse
    func signInWithGoogle(_ request: GoogleSignInRequest) async throws -> ServerSessionResponse
    func fetchProfile(sessionToken: String) async throws -> ServerAccountProfile
    func logout(sessionToken: String) async throws
    func deleteAccount(sessionToken: String) async throws
}

/// Exactly what the server needs for Apple. Note what is absent: the Apple
/// user identifier, the email and the display name are **not** sent as
/// identity — the server takes the subject from the signed token only.
struct AppleSignInRequest: Encodable, Equatable {
    let identityToken: String
    let authorizationCode: String
    let rawNonce: String
    let deviceName: String?
}

/// Likewise for Google: the ID token and nothing that claims who the user is.
struct GoogleSignInRequest: Encodable, Equatable {
    let idToken: String
    let deviceName: String?
}

struct PulseCueAccountAPIClient: PulseCueAccountAPI {
    private let configuration: PulseCueAPIConfiguration
    private let transport: any AccountHTTPTransport

    init(
        configuration: PulseCueAPIConfiguration,
        transport: any AccountHTTPTransport = URLSessionAccountTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    var isConfigured: Bool { configuration.isConfigured }

    func signInWithApple(_ request: AppleSignInRequest) async throws -> ServerSessionResponse {
        try await post(path: "v1/auth/apple", body: request)
    }

    func signInWithGoogle(_ request: GoogleSignInRequest) async throws -> ServerSessionResponse {
        try await post(path: "v1/auth/google", body: request)
    }

    func fetchProfile(sessionToken: String) async throws -> ServerAccountProfile {
        let (data, response) = try await perform(
            path: "v1/me",
            method: "GET",
            body: Optional<AppleSignInRequest>.none,
            sessionToken: sessionToken
        )
        try classify(response)
        return try decode(ServerAccountProfile.self, from: data)
    }

    func logout(sessionToken: String) async throws {
        let (_, response) = try await perform(
            path: "v1/auth/logout",
            method: "POST",
            body: Optional<AppleSignInRequest>.none,
            sessionToken: sessionToken
        )
        try classify(response)
    }

    func deleteAccount(sessionToken: String) async throws {
        let (_, response) = try await perform(
            path: "v1/me",
            method: "DELETE",
            body: Optional<AppleSignInRequest>.none,
            sessionToken: sessionToken
        )
        // 202 means the deletion is under way and irreversible — a success
        // from the app's point of view, not something to retry.
        guard response.statusCode != 202 else { return }
        try classify(response)
    }

    // MARK: - Internals

    private func post<Body: Encodable, Result: Decodable>(
        path: String,
        body: Body
    ) async throws -> Result {
        let (data, response) = try await perform(
            path: path,
            method: "POST",
            body: body,
            sessionToken: nil
        )
        try classify(response)
        return try decode(Result.self, from: data)
    }

    private func perform<Body: Encodable>(
        path: String,
        method: String,
        body: Body?,
        sessionToken: String?
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = configuration.url(forPath: path) else {
            throw AccountAPIError.notConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let sessionToken {
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try JSONEncoder().encode(body)
            } catch {
                // Encoding our own request cannot be a session verdict.
                throw AccountAPIError.malformedResponse
            }
        }

        do {
            return try await transport.send(request)
        } catch let error as AccountAPIError {
            throw error
        } catch {
            // Offline, timed out, DNS, TLS. None of it says the session is
            // bad, and treating it as such would sign the user out for
            // walking into a lift.
            throw AccountAPIError.unavailable
        }
    }

    private func classify(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw AccountAPIError.invalidCredentials
        default:
            // 400 included: a request this app got wrong is our bug, not a
            // reason to destroy the user's session.
            throw AccountAPIError.unavailable
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AccountAPIError.malformedResponse
        }
    }
}
