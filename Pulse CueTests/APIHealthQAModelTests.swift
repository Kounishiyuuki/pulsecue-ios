//
//  APIHealthQAModelTests.swift
//  Pulse CueTests
//
//  Covers the DEBUG-only API health QA model (`APIHealthQAModel`). The whole
//  file is `#if DEBUG`, matching the model it tests. No real networking is
//  performed: services are exercised either with the default disabled client
//  or with an injected `MockAPIClient` returning fixtures.
//

#if DEBUG
import Foundation
import Testing
@testable import Pulse_Cue

@Suite
@MainActor
struct APIHealthQAModelTests {

    // MARK: - makeService: empty / invalid never builds a networking service

    @Test
    func emptyBaseURLProducesNoService() {
        #expect(APIHealthQAModel.makeService(baseURLString: "") == nil)
        #expect(APIHealthQAModel.makeService(baseURLString: "   ") == nil)
    }

    @Test
    func invalidBaseURLProducesNoService() {
        // No scheme/host → not a usable absolute URL → nil (→ .notConfigured).
        #expect(APIHealthQAModel.makeService(baseURLString: "not a url") == nil)
        #expect(APIHealthQAModel.makeService(baseURLString: "api/health") == nil)
    }

    @Test
    func validBaseURLProducesAService() {
        #expect(APIHealthQAModel.makeService(baseURLString: "https://example.test/") != nil)
    }

    // MARK: - check(baseURLString:): empty/invalid short-circuits without networking

    @Test
    func checkWithEmptyStringIsNotConfiguredAndDoesNotNetwork() async {
        let result = await APIHealthQAModel.check(baseURLString: "")
        #expect(result == .notConfigured)
    }

    @Test
    func checkWithInvalidStringIsNotConfigured() async {
        let result = await APIHealthQAModel.check(baseURLString: "nonsense")
        #expect(result == .notConfigured)
    }

    // MARK: - check(using:): result mapping is stable (mock-backed, no network)

    @Test
    func healthyFixtureMapsToHealthy() async {
        let service = APIHealthService(client: MockAPIClient { _ in
            Data(#"{"status":"ok","version":"3.1"}"#.utf8)
        })
        let result = await APIHealthQAModel.check(using: service)
        #expect(result == .healthy(version: "3.1"))
    }

    @Test
    func degradedFixtureMapsToDegraded() async {
        let service = APIHealthService(client: MockAPIClient { _ in
            Data(#"{"status":"degraded"}"#.utf8)
        })
        let result = await APIHealthQAModel.check(using: service)
        #expect(result == .degraded(version: nil))
    }

    @Test
    func defaultDisabledServiceMapsToDisabledWithoutNetworking() async {
        // Default APIHealthService uses DisabledAPIClient → no networking.
        let result = await APIHealthQAModel.check(using: APIHealthService())
        #expect(result == .disabled)
    }

    @Test
    func malformedBodyMapsToFailed() async {
        let service = APIHealthService(client: MockAPIClient { _ in Data("nope".utf8) })
        let result = await APIHealthQAModel.check(using: service)
        if case .failed = result {
            // expected
        } else {
            Issue.record("expected .failed, got \(result)")
        }
    }

    @Test
    func serverErrorMapsToFailed() async {
        struct FailingClient: APIClient {
            func send(_ request: APIRequest) async throws -> Data {
                throw APIClientError.server(status: 503)
            }
        }
        let result = await APIHealthQAModel.check(using: APIHealthService(client: FailingClient()))
        if case .failed = result {
            // expected (mapped from .server(.serviceUnavailable))
        } else {
            Issue.record("expected .failed, got \(result)")
        }
    }

    // MARK: - Error message mapping (display-only, no raw internals)

    @Test
    func errorMessagesAreStableAndDisplayOnly() {
        #expect(APIHealthQAModel.message(for: .disabled) == "通信は無効です")
        #expect(APIHealthQAModel.message(for: .unauthorized) == "認証エラー (401)")
        #expect(APIHealthQAModel.message(for: .transport) == "接続に失敗しました")
        #expect(APIHealthQAModel.message(for: .server(.notFound)) == "サーバーエラー (not_found)")
    }
}
#endif
