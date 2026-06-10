//
//  AITrainingPlanEndpointClientTests.swift
//  Pulse CueTests
//
//  Request/response + error-mapping tests for the network-capable
//  `AITrainingPlanEndpointClient`. Exercises the real encode → request →
//  decode path against fixture responses served by a stub `URLProtocol` —
//  no live network, no real URL, no token, no API key, no server running.
//
//  The suite is `.serialized` because the stub responder is a single
//  shared closure.
//

import Foundation
import Testing
@testable import Pulse_Cue

@Suite(.serialized)
@MainActor
struct AITrainingPlanEndpointClientTests {

    // MARK: - Stub networking

    /// Captures the last request and answers from an in-test closure so
    /// the client runs its real request/decode path offline.
    final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var responder:
            ((URLRequest) throws -> (HTTPURLResponse, Data))?
        /// Last request seen, including a captured copy of the body
        /// (`URLProtocol` strips `httpBody` into `httpBodyStream`).
        nonisolated(unsafe) static var lastRequest: URLRequest?
        nonisolated(unsafe) static var lastBody: Data?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastRequest = request
            Self.lastBody = Self.readBody(request)
            guard let responder = Self.responder else {
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                return
            }
            do {
                let (response, data) = try responder(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}

        private static func readBody(_ request: URLRequest) -> Data? {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }

    private func makeClient(
        tokenProvider: (@Sendable () async -> String?)? = nil
    ) -> AITrainingPlanEndpointClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return AITrainingPlanEndpointClient(
            baseURL: URL(string: "https://backend.test/")!,
            session: URLSession(configuration: config),
            tokenProvider: tokenProvider
        )
    }

    private func arm(status: Int, json: String) {
        StubURLProtocol.lastRequest = nil
        StubURLProtocol.lastBody = nil
        StubURLProtocol.responder = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(json.utf8))
        }
    }

    private let okJSON = """
    {
      "title": "筋肥大プラン（モックAI下書き）",
      "rationale": "テスト",
      "warnings": ["注意"],
      "sessions": [
        { "title": "Day 1", "exerciseMachineIds": ["chest_press"], "notes": null }
      ]
    }
    """

    private func sampleRequest() -> AITrainingPlanRequest {
        AITrainingPlanRequest(
            userMessage: "胸を鍛えたい",
            goal: .hypertrophy,
            daysPerWeek: 3,
            targetBodyParts: [.chest],
            experienceLevel: .beginner,
            preferredSplit: .fullBody,
            availableMachineIds: ["chest_press"]
        )
    }

    // MARK: - Success path

    @Test
    func successDecodesResponse() async throws {
        arm(status: 200, json: okJSON)
        let response = try await makeClient().generatePlan(for: sampleRequest())
        #expect(response.title == "筋肥大プラン（モックAI下書き）")
        #expect(response.warnings == ["注意"])
        #expect(response.sessions.count == 1)
        #expect(response.sessions.first?.exerciseMachineIds == ["chest_press"])
    }

    @Test
    func requestHitsTrainingPlanPathWithPostAndEncodesFields() async throws {
        arm(status: 200, json: okJSON)
        _ = try await makeClient().generatePlan(for: sampleRequest())

        let req = try #require(StubURLProtocol.lastRequest)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/api/ai/training-plan")

        let body = try #require(StubURLProtocol.lastBody)
        let obj = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(obj["userMessage"] as? String == "胸を鍛えたい")
        #expect(obj["goal"] as? String == "hypertrophy")          // enum rawValue
        #expect(obj["daysPerWeek"] as? Int == 3)
        #expect(obj["targetBodyParts"] as? [String] == ["chest"])
        #expect(obj["experienceLevel"] as? String == "beginner")
        #expect(obj["preferredSplit"] as? String == "fullBody")
        #expect(obj["availableMachineIds"] as? [String] == ["chest_press"])
    }

    // MARK: - Authorization header

    @Test
    func noAuthorizationHeaderWhenNoTokenProvided() async throws {
        arm(status: 200, json: okJSON)
        _ = try await makeClient(tokenProvider: nil).generatePlan(for: sampleRequest())
        let req = try #require(StubURLProtocol.lastRequest)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func authorizationHeaderPresentOnlyWhenTokenInjected() async throws {
        arm(status: 200, json: okJSON)
        _ = try await makeClient(tokenProvider: { "short-lived-token" })
            .generatePlan(for: sampleRequest())
        let req = try #require(StubURLProtocol.lastRequest)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer short-lived-token")
    }

    @Test
    func emptyTokenDoesNotSetAuthorizationHeader() async throws {
        arm(status: 200, json: okJSON)
        _ = try await makeClient(tokenProvider: { "" }).generatePlan(for: sampleRequest())
        let req = try #require(StubURLProtocol.lastRequest)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - Error mapping

    private func expectError(
        _ expected: AITrainingPlanEndpointError,
        status: Int,
        json: String
    ) async {
        arm(status: status, json: json)
        await #expect(throws: expected) {
            try await makeClient().generatePlan(for: sampleRequest())
        }
    }

    @Test
    func unauthorizedMapsFrom401() async {
        await expectError(.unauthorized, status: 401,
                          json: #"{"error":{"code":"unauthorized","message":"x","requestId":"req-1"}}"#)
    }

    @Test
    func tokenExpiredMapsFrom401Envelope() async {
        await expectError(.tokenExpired, status: 401,
                          json: #"{"error":{"code":"token_expired","message":"x","requestId":"req-2"}}"#)
    }

    @Test
    func invalidScopeMapsFrom403Envelope() async {
        await expectError(.invalidScope, status: 403,
                          json: #"{"error":{"code":"invalid_scope","message":"x","requestId":"req-3"}}"#)
    }

    @Test
    func rateLimitedMapsFrom429() async {
        await expectError(.rateLimited, status: 429,
                          json: #"{"error":{"code":"rate_limited","message":"x"}}"#)
    }

    @Test
    func invalidRequestMapsFrom400() async {
        await expectError(.invalidRequest, status: 400,
                          json: #"{"error":{"code":"invalid_request","message":"x"}}"#)
    }

    @Test
    func providerUnavailableMapsFrom503() async {
        await expectError(.providerUnavailable, status: 503, json: "{}")
    }

    @Test
    func invalidProviderResponseCodeStillMapsToInvalidProviderResponse() async {
        await expectError(.invalidProviderResponse, status: 502,
                          json: #"{"error":{"code":"invalid_provider_response","message":"x"}}"#)
    }

    @Test
    func malformedAuthEnvelopeMapsSafely() async {
        await expectError(.unauthorized, status: 401, json: "not json at all")
        await expectError(.unknown, status: 403, json: "{}")
    }

    @Test
    func authErrorsDoNotExposeTokenOrUserMessageInDisplayedCopy() {
        let rawToken = "fake-token-that-should-not-appear"
        let rawUserMessage = "PLEASE_DO_NOT_SHOW_THIS_USER_MESSAGE"
        let messages = [
            AIPlanGenerationError.from(AITrainingPlanEndpointError.unauthorized).message,
            AIPlanGenerationError.from(AITrainingPlanEndpointError.tokenExpired).message,
            AIPlanGenerationError.from(AITrainingPlanEndpointError.invalidScope).message,
        ]
        for message in messages {
            #expect(!message.contains(rawToken))
            #expect(!message.contains(rawUserMessage))
            #expect(!message.contains("Authorization"))
            #expect(!message.contains("Bearer"))
        }
    }

    @Test
    func malformedSuccessJSONMapsToInvalidProviderResponse() async {
        await expectError(.invalidProviderResponse, status: 200, json: "not json at all")
    }

    @Test
    func unknownStatusMapsToUnknown() async {
        await expectError(.unknown, status: 418, json: "{}")
    }

    // MARK: - Transport

    @Test
    func transportFailureMapsToTransportFailed() async {
        StubURLProtocol.responder = { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: AITrainingPlanEndpointError.transportFailed) {
            try await makeClient().generatePlan(for: sampleRequest())
        }
    }

    @Test
    func timeoutMapsToTimeout() async {
        StubURLProtocol.responder = { _ in throw URLError(.timedOut) }
        await #expect(throws: AITrainingPlanEndpointError.timeout) {
            try await makeClient().generatePlan(for: sampleRequest())
        }
    }
}
