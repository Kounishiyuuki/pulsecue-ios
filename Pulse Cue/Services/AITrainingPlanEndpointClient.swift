//
//  AITrainingPlanEndpointClient.swift
//  Pulse Cue
//
//  Network-capable `AITrainingPlanProviding` conformer that calls the
//  backend proxy endpoint `POST /api/ai/training-plan`
//  (see Docs/ai-training-plan-proxy-endpoint-spec.md, PR #78/#79).
//
//  Boundaries (locked for this PR):
//   - **Not wired by default.** `MockAITrainingPlanChatView` still uses
//     `MockAITrainingPlanProvider`; this client is constructed only with
//     an injected `baseURL` (tests / future dev wiring). There is NO
//     hardcoded production URL, no `*.workers.dev`, no provider key.
//   - No real AI / OpenAI / provider SDK here — this only talks to the
//     PulseCue backend proxy, which owns any provider key server-side.
//   - No token storage: an optional `tokenProvider` closure supplies an
//     `Authorization: Bearer` value when (and only when) injected. The
//     client never reads/writes Info.plist / UserDefaults / Keychain.
//   - Returns an `AITrainingPlanResponse` (raw, untrusted). It does NOT
//     normalize or persist — `AITrainingPlanNormalizer` remains the
//     caller-side final gate and saving stays explicit/user-driven.
//   - Never logs `userMessage` or raw responses.
//
//  Cancellation works naturally via the async `URLSession` API.
//

import Foundation

// MARK: - Error

/// Typed errors surfaced by the endpoint client. Mirrors the server
/// error envelope codes (spec §7) plus transport/decoding failures.
/// Provider-internal details / raw bodies are never represented here.
enum AITrainingPlanEndpointError: Error, Equatable, Sendable {
    case invalidConfiguration
    case encodingFailed
    case transportFailed
    case unauthorized
    case tokenExpired
    case invalidScope
    case rateLimited
    case timeout
    case providerUnavailable
    case invalidRequest
    case invalidProviderResponse
    case invalidResponse
    case unknown
}

// MARK: - Client

struct AITrainingPlanEndpointClient: AITrainingPlanProviding {
    /// Base URL of the PulseCue backend proxy. Injected — there is no
    /// default / production value baked in.
    let baseURL: URL
    /// Injected so tests can route through a stub `URLProtocol`; callers
    /// may pass a configured session. Defaults to `.shared`.
    let session: URLSession
    /// Optional source of a short-lived bearer token. When `nil`, no
    /// `Authorization` header is sent. The closure is `async` so a real
    /// token provider can mint/refresh on demand without this client
    /// persisting anything.
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

    func generatePlan(for request: AITrainingPlanRequest) async throws -> AITrainingPlanResponse {
        // 1. Build URL: POST {baseURL}/api/ai/training-plan
        guard let url = URL(string: "api/ai/training-plan", relativeTo: baseURL) else {
            throw AITrainingPlanEndpointError.invalidConfiguration
        }

        // 2. Encode the request body via a Codable wire DTO.
        let body: Data
        do {
            body = try JSONEncoder().encode(RequestDTO(request))
        } catch {
            throw AITrainingPlanEndpointError.encodingFailed
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body

        // 3. Authorization only when a token is injected.
        if let tokenProvider, let token = await tokenProvider(), !token.isEmpty {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // 4. Transport. Async URLSession cancels cooperatively.
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .timedOut {
            throw AITrainingPlanEndpointError.timeout
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AITrainingPlanEndpointError.transportFailed
        }

        guard let http = response as? HTTPURLResponse else {
            throw AITrainingPlanEndpointError.invalidResponse
        }

        // 5. Map non-2xx to typed errors using HTTP status + the
        //    server's error envelope `code` when present.
        if !(200..<300).contains(http.statusCode) {
            throw Self.mapError(status: http.statusCode, data: data)
        }

        // 6. Decode the success body into the raw response value type.
        do {
            return try JSONDecoder().decode(ResponseDTO.self, from: data).toResponse()
        } catch {
            throw AITrainingPlanEndpointError.invalidProviderResponse
        }
    }

    /// Maps an HTTP error status (and optional `{error:{code}}` body) to
    /// a typed client error. The error `code` takes precedence so the
    /// mapping stays aligned with the server even if status codes shift.
    private static func mapError(status: Int, data: Data) -> AITrainingPlanEndpointError {
        let code = (try? JSONDecoder().decode(ErrorEnvelopeDTO.self, from: data))?.error?.code
        switch code {
        case "unauthorized": return .unauthorized
        case "token_expired": return .tokenExpired
        case "invalid_scope": return .invalidScope
        case "rate_limited", "quota_exceeded": return .rateLimited
        case "timeout": return .timeout
        case "provider_unavailable": return .providerUnavailable
        case "invalid_request": return .invalidRequest
        case "invalid_provider_response": return .invalidProviderResponse
        default:
            break
        }
        switch status {
        case 401: return .unauthorized
        case 429: return .rateLimited
        case 400: return .invalidRequest
        case 502, 503: return .providerUnavailable
        case 504: return .timeout
        default: return .unknown
        }
    }
}

// MARK: - Wire DTOs
//
// The public `AITrainingPlanRequest` / `AITrainingPlanResponse` use Swift
// enums and are intentionally not `Codable`. These private DTOs own the
// JSON shape (enum raw-value strings) so the wire format stays decoupled
// from the in-app value types.

private struct RequestDTO: Encodable {
    let userMessage: String
    let goal: String?
    let daysPerWeek: Int?
    let targetBodyParts: [String]
    let experienceLevel: String?
    let preferredSplit: String?
    let availableMachineIds: [String]

    init(_ request: AITrainingPlanRequest) {
        userMessage = request.userMessage
        goal = request.goal?.rawValue
        daysPerWeek = request.daysPerWeek
        targetBodyParts = request.targetBodyParts.map(\.rawValue)
        experienceLevel = request.experienceLevel?.rawValue
        preferredSplit = request.preferredSplit?.rawValue
        availableMachineIds = request.availableMachineIds
    }
}

private struct ResponseDTO: Decodable {
    let title: String?
    let sessions: [SessionDTO]?
    let rationale: String?
    let warnings: [String]?

    struct SessionDTO: Decodable {
        let title: String?
        let exerciseMachineIds: [String]?
        let notes: String?
    }

    func toResponse() -> AITrainingPlanResponse {
        AITrainingPlanResponse(
            title: title,
            sessions: (sessions ?? []).map {
                AITrainingSessionResponse(
                    title: $0.title,
                    exerciseMachineIds: $0.exerciseMachineIds ?? [],
                    notes: $0.notes
                )
            },
            rationale: rationale,
            warnings: warnings ?? []
        )
    }
}

private struct ErrorEnvelopeDTO: Decodable {
    let error: ErrorDTO?
    struct ErrorDTO: Decodable {
        let code: String?
        let message: String?
    }
}
