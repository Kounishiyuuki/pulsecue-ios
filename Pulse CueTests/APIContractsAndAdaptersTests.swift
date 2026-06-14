//
//  APIContractsAndAdaptersTests.swift
//  Pulse CueTests
//
//  Covers the API contract DTOs (`APIContracts`) and the mock-safe adapter
//  (`APIHealthService`) layered on `APIIntegrationFoundation` (PR #122).
//  Verifies: DTO encode/decode, request path building, the disabled client
//  performs no networking, the mock client returns fixtures, error mapping is
//  stable, no production URL is required, and no token is persisted.
//

import Foundation
import Testing
@testable import Pulse_Cue

// `@MainActor` because the app target uses `SWIFT_DEFAULT_ACTOR_ISOLATION =
// MainActor`, so these types are main-actor isolated. Mirrors
// `APIIntegrationFoundationTests`.
@Suite
@MainActor
struct APIContractsAndAdaptersTests {

    // MARK: - DTO encode / decode

    @Test
    func healthCheckResponseRoundTrips() throws {
        let original = HealthCheckResponse(status: "ok", version: "1.2.3")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HealthCheckResponse.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func healthCheckResponseDecodesWithoutVersion() throws {
        let json = Data(#"{"status":"ok"}"#.utf8)
        let decoded = try JSONDecoder().decode(HealthCheckResponse.self, from: json)
        #expect(decoded.status == "ok")
        #expect(decoded.version == nil)
    }

    @Test
    func errorResponseDecodesCodeAndMessage() throws {
        let json = Data(#"{"error":{"code":"rate_limited","message":"slow down"}}"#.utf8)
        let decoded = try JSONDecoder().decode(APIErrorResponse.self, from: json)
        #expect(decoded.code == .rateLimited)
        #expect(decoded.message == "slow down")
    }

    @Test
    func responseEnvelopeUnwrapsData() throws {
        let json = Data(#"{"data":{"status":"ok","version":"9"}}"#.utf8)
        let decoded = try JSONDecoder().decode(APIResponseEnvelope<HealthCheckResponse>.self, from: json)
        #expect(decoded.data.status == "ok")
        #expect(decoded.data.version == "9")
    }

    // MARK: - Error code mapping (stable)

    @Test
    func errorCodeMapsKnownAndUnknownRawValues() {
        #expect(APIErrorCode(rawCode: "token_expired") == .tokenExpired)
        #expect(APIErrorCode(rawCode: "not_found") == .notFound)
        #expect(APIErrorCode(rawCode: "totally_unrecognized") == .unknown)
        #expect(APIErrorCode(rawCode: nil) == .unknown)
    }

    @Test
    func clientErrorMappingIsStable() {
        #expect(APIHealthService.mapClientError(.disabled) == .disabled)
        #expect(APIHealthService.mapClientError(.unauthorized) == .server(.unauthorized))
        #expect(APIHealthService.mapClientError(.server(status: 404)) == .server(.notFound))
        #expect(APIHealthService.mapClientError(.server(status: 429)) == .server(.rateLimited))
        #expect(APIHealthService.mapClientError(.server(status: 503)) == .server(.serviceUnavailable))
        #expect(APIHealthService.mapClientError(.server(status: 500)) == .server(.serverError))
        #expect(APIHealthService.mapClientError(.timeout) == .transport)
        #expect(APIHealthService.mapClientError(.transportFailed) == .transport)
        #expect(APIHealthService.mapClientError(.invalidResponse) == .unknown)
    }

    // MARK: - Adapter: disabled by default performs no networking

    @Test
    func defaultServiceIsDisabledAndDoesNotNetwork() async {
        let service = APIHealthService() // default client = DisabledAPIClient
        await #expect(throws: APIServiceError.disabled) {
            _ = try await service.checkHealth()
        }
    }

    // MARK: - Adapter: request path is built correctly (no production URL)

    @Test
    func serviceBuildsExpectedRequestPathWithoutProductionURL() async throws {
        let captured = CapturedRequest()
        let client = MockAPIClient { request in
            await captured.store(request)
            return Data(#"{"status":"ok"}"#.utf8)
        }
        let service = APIHealthService(client: client) // no base URL needed here
        _ = try await service.checkHealth()
        let request = await captured.value
        #expect(request?.path == "api/health")
        #expect(request?.method == .get)
        #expect(request?.body == nil)
    }

    // MARK: - Adapter: mock client returns fixtures → mapped status

    @Test
    func serviceMapsHealthyFixture() async throws {
        let client = MockAPIClient { _ in Data(#"{"status":"ok","version":"2.0.0"}"#.utf8) }
        let status = try await APIHealthService(client: client).checkHealth()
        #expect(status.isHealthy == true)
        #expect(status.version == "2.0.0")
    }

    @Test
    func serviceMapsUnhealthyFixture() async throws {
        let client = MockAPIClient { _ in Data(#"{"status":"degraded"}"#.utf8) }
        let status = try await APIHealthService(client: client).checkHealth()
        #expect(status.isHealthy == false)
        #expect(status.version == nil)
    }

    @Test
    func serviceSurfacesDecodingFailureOnMalformedBody() async {
        let client = MockAPIClient { _ in Data("not json".utf8) }
        await #expect(throws: APIServiceError.decodingFailed) {
            _ = try await APIHealthService(client: client).checkHealth()
        }
    }

    @Test
    func serviceMapsServerErrorThroughClient() async {
        // A client that simulates a 404 → stable mapped service error.
        struct FailingClient: APIClient {
            func send(_ request: APIRequest) async throws -> Data {
                throw APIClientError.server(status: 404)
            }
        }
        let service = APIHealthService(client: FailingClient())
        await #expect(throws: APIServiceError.server(.notFound)) {
            _ = try await service.checkHealth()
        }
    }

    // MARK: - No token persistence introduced

    @Test
    func serviceHoldsNoCredentialState() {
        // The service stores only the client + a relative path — no token,
        // no base URL, no credential field exists to persist.
        let service = APIHealthService()
        #expect(service.path == "api/health")
        // Path is relative (no scheme/host), proving no production URL baked in.
        #expect(service.path.contains("://") == false)
    }

    /// Actor that captures the last request a mock client received, so a test
    /// can assert the built path without performing any networking.
    private actor CapturedRequest {
        private(set) var value: APIRequest?
        func store(_ request: APIRequest) { value = request }
    }
}
