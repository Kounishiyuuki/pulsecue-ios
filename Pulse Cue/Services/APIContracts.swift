//
//  APIContracts.swift
//  Pulse Cue
//
//  Concrete API *contract* types (DTOs + envelopes) for a future real-backend
//  phase, layered on top of `APIIntegrationFoundation` (PR #122). Additive and
//  NOT wired into any existing flow — the app stays local-first and performs
//  no API networking by default.
//
//  Boundaries:
//    - **Wire DTOs only.** These types own the JSON shape and are intentionally
//      kept separate from the SwiftData `@Model` types (Routine / Session /
//      DayLog / UserProfile / Gym …). No `@Model` is touched.
//    - **No user data.** The only concrete endpoint modeled here is a
//      read-only health/version probe, which sends and receives no user data.
//    - **No production URL / token.** Contracts carry no host or credential;
//      the base URL and any token stay injected through the foundation.
//

import Foundation

// MARK: - Error contract

/// Stable, app-facing error codes mapped from a future PulseCue backend error
/// envelope. String-backed so the wire format can evolve without breaking the
/// switch; `.unknown` covers any unrecognized / missing code.
enum APIErrorCode: String, Equatable, Sendable {
    case unauthorized
    case tokenExpired = "token_expired"
    case invalidScope = "invalid_scope"
    case rateLimited = "rate_limited"
    case invalidRequest = "invalid_request"
    case notFound = "not_found"
    case serverError = "server_error"
    case serviceUnavailable = "service_unavailable"
    case unknown

    /// Maps a raw wire `code` (or `nil`) to a stable case.
    init(rawCode: String?) {
        self = rawCode.flatMap(APIErrorCode.init(rawValue:)) ?? .unknown
    }
}

/// Decodable server error envelope: `{ "error": { "code", "message" } }`.
/// Display-only — carries no provider internals and is separate from any
/// SwiftData model.
struct APIErrorResponse: Decodable, Equatable {
    struct Body: Decodable, Equatable {
        let code: String?
        let message: String?
    }

    let error: Body?

    /// The mapped, stable error code (`.unknown` when absent/unrecognized).
    var code: APIErrorCode { APIErrorCode(rawCode: error?.code) }
    /// Optional human-readable message for display only.
    var message: String? { error?.message }
}

/// Generic success envelope `{ "data": T }` for endpoints that wrap their
/// payload. Optional helper — endpoints may also decode a bare body.
struct APIResponseEnvelope<T: Decodable>: Decodable {
    let data: T
}

// MARK: - Health check contract (read-only, no user data)

/// Wire DTO for a read-only health/version probe. Intentionally trivial and
/// carries no user data. Separate from any SwiftData `@Model`.
struct HealthCheckResponse: Codable, Equatable {
    let status: String
    let version: String?

    enum CodingKeys: String, CodingKey {
        case status
        case version
    }
}

/// App-facing health result mapped from `HealthCheckResponse`. This is the
/// value a future UI/diagnostic could display; it is not persisted.
struct APIHealthStatus: Equatable {
    let isHealthy: Bool
    let version: String?
}
