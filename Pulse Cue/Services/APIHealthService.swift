//
//  APIHealthService.swift
//  Pulse Cue
//
//  A small, mock-safe *adapter / service* layered on the `APIClient` seam
//  (PR #122) + `APIContracts`. It demonstrates the future request → decode →
//  map pattern with a read-only health probe, without enabling real
//  networking or touching any existing flow.
//
//  Boundaries:
//    - **Disabled by default.** The injected client defaults to
//      `DisabledAPIClient`, so a default-constructed service performs NO
//      networking and surfaces `.disabled`.
//    - **No user data.** `checkHealth()` is a GET with no body and decodes a
//      trivial status/version DTO. Nothing about the user is sent.
//    - **No production URL / token.** The path is relative; the base URL and
//      any bearer token stay injected through the foundation. This file
//      hardcodes no host and stores no credential.
//    - **Not wired into app UI.** No existing screen constructs or calls this.
//

import Foundation

/// App-facing errors for endpoint services, mapped from the lower-level
/// `APIClientError`. No raw bodies or provider internals are represented.
enum APIServiceError: Error, Equatable, Sendable {
    /// Networking is disabled (the local-first default) — no request was sent.
    case disabled
    case decodingFailed
    case unauthorized
    case server(APIErrorCode)
    case transport
    case unknown
}

/// Read-only adapter that probes a future backend's health endpoint through
/// the injected `APIClient`. Defaults to the disabled client (no networking).
struct APIHealthService {
    let client: APIClient
    /// Path relative to the configured base URL. No production host here.
    let path: String

    init(client: APIClient = DisabledAPIClient(), path: String = "api/health") {
        self.client = client
        self.path = path
    }

    /// Sends `GET {baseURL}/{path}` (no body, no user data), decodes the
    /// health DTO, and maps it to an app-facing status. With the default
    /// disabled client this throws `.disabled` and performs no networking.
    func checkHealth() async throws -> APIHealthStatus {
        let request = APIRequest(method: .get, path: path)
        let data: Data
        do {
            data = try await client.send(request)
        } catch let error as APIClientError {
            throw Self.mapClientError(error)
        }
        do {
            let dto = try JSONDecoder().decode(HealthCheckResponse.self, from: data)
            return APIHealthStatus(
                isHealthy: dto.status.lowercased() == "ok",
                version: dto.version
            )
        } catch {
            throw APIServiceError.decodingFailed
        }
    }

    /// Stable mapping from transport-level `APIClientError` to the app-facing
    /// `APIServiceError`. Kept deterministic so callers/tests can rely on it.
    static func mapClientError(_ error: APIClientError) -> APIServiceError {
        switch error {
        case .disabled:
            return .disabled
        case .unauthorized:
            return .server(.unauthorized)
        case let .server(status):
            switch status {
            case 404: return .server(.notFound)
            case 429: return .server(.rateLimited)
            case 503: return .server(.serviceUnavailable)
            case 500...599: return .server(.serverError)
            default: return .server(.unknown)
            }
        case .timeout, .transportFailed:
            return .transport
        case .invalidRequest, .invalidResponse:
            return .unknown
        }
    }
}
