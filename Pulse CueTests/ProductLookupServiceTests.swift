//
//  ProductLookupServiceTests.swift
//  Pulse CueTests
//
//  Decoding / error-mapping tests for the barcode product lookup
//  (PR #45). Exercises `OpenFoodFactsProductLookupService` end-to-end
//  against *fixture JSON* served by a stub `URLProtocol` — the live
//  Open Food Facts network is never contacted.
//
//  Coverage:
//   - product found with calories + protein
//   - product found with missing protein
//   - product found with missing calories
//   - string-typed nutriment values are parsed and rounded
//   - negative / blank values are treated as absent
//   - barcode is trimmed before lookup
//   - Open Food Facts `status: 0` maps to `.notFound`
//   - malformed / wrong-shape JSON maps to `.invalidResponse`
//   - transport failure and non-2xx HTTP map to `.network`
//   - a blank barcode short-circuits to `.notFound` with no request
//
//  The suite is `.serialized` so the single shared stub responder is
//  set and read without a data race.
//

import Foundation
import Testing
@testable import Pulse_Cue

@Suite(.serialized)
struct ProductLookupServiceTests {

    // MARK: - Stub networking

    /// Minimal `URLProtocol` that answers every request from an
    /// in-test closure. It lets `OpenFoodFactsProductLookupService`
    /// run its real request/decode path without touching the live
    /// Open Food Facts servers.
    final class FixtureURLProtocol: URLProtocol {
        /// Set before each lookup. Returns the (response, body) to
        /// deliver, or throws to simulate a transport failure.
        nonisolated(unsafe) static var responder:
            ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
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
    }

    /// A service whose `URLSession` is routed through the stub
    /// protocol — no real network access.
    private func makeService() -> OpenFoodFactsProductLookupService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureURLProtocol.self]
        return OpenFoodFactsProductLookupService(session: URLSession(configuration: config))
    }

    /// Arms the stub to answer the next request with `json` and the
    /// given HTTP status.
    private func respond(json: String, statusCode: Int = 200) {
        FixtureURLProtocol.responder = { request in
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://world.openfoodfacts.org")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(json.utf8))
        }
    }

    // MARK: - Found product

    @Test func foundProductExposesCaloriesAndProtein() async throws {
        respond(json: """
        {"status":1,"product":{"product_name":"プロテインヨーグルト",\
        "serving_size":"110 g",\
        "nutriments":{"energy-kcal_100g":59,"proteins_100g":10}}}
        """)
        let result = try await makeService().lookup(barcode: "4901234567894")
        #expect(result.barcode == "4901234567894")
        #expect(result.name == "プロテインヨーグルト")
        #expect(result.kcal == 59)
        #expect(result.proteinGrams == 10)
        #expect(result.servingDescription == "110 g")
    }

    @Test func foundProductWithMissingProteinHasNilProtein() async throws {
        respond(json: """
        {"status":1,"product":{"product_name":"クラッカー",\
        "nutriments":{"energy-kcal_100g":480}}}
        """)
        let result = try await makeService().lookup(barcode: "0000000000000")
        #expect(result.name == "クラッカー")
        #expect(result.kcal == 480)
        #expect(result.proteinGrams == nil)
    }

    @Test func foundProductWithMissingCaloriesHasNilKcal() async throws {
        respond(json: """
        {"status":1,"product":{"product_name":"プロテインサプリ",\
        "nutriments":{"proteins_100g":21}}}
        """)
        let result = try await makeService().lookup(barcode: "1111111111111")
        #expect(result.kcal == nil)
        #expect(result.proteinGrams == 21)
    }

    @Test func nutrimentStringValuesAreParsedAndRounded() async throws {
        // Open Food Facts sometimes reports nutriment values as JSON
        // strings; they must still parse, and per-100 g values are
        // rounded to whole numbers.
        respond(json: """
        {"status":1,"product":{"product_name":"スポーツ飲料",\
        "nutriments":{"energy-kcal_100g":"41.6","proteins_100g":"3.4"}}}
        """)
        let result = try await makeService().lookup(barcode: "2222222222222")
        #expect(result.kcal == 42)
        #expect(result.proteinGrams == 3)
    }

    @Test func negativeNutrimentValuesAreTreatedAsAbsent() async throws {
        respond(json: """
        {"status":1,"product":{"product_name":"テスト商品",\
        "nutriments":{"energy-kcal_100g":-5,"proteins_100g":-1}}}
        """)
        let result = try await makeService().lookup(barcode: "6666666666666")
        #expect(result.kcal == nil)
        #expect(result.proteinGrams == nil)
    }

    @Test func blankProductNameBecomesNil() async throws {
        respond(json: """
        {"status":1,"product":{"product_name":"   ",\
        "nutriments":{"energy-kcal_100g":100}}}
        """)
        let result = try await makeService().lookup(barcode: "7777777777777")
        #expect(result.name == nil)
        #expect(result.kcal == 100)
    }

    @Test func barcodeIsTrimmedBeforeLookup() async throws {
        respond(json: """
        {"status":1,"product":{"product_name":"X",\
        "nutriments":{"energy-kcal_100g":100}}}
        """)
        let result = try await makeService().lookup(barcode: "  4901234567894  ")
        #expect(result.barcode == "4901234567894")
    }

    // MARK: - Not found

    @Test func statusZeroThrowsNotFound() async throws {
        // Open Food Facts returns HTTP 200 with `status: 0` for an
        // unknown barcode; "not found" must be read from the body.
        respond(json: #"{"status":0,"product":null}"#)
        await #expect(throws: ProductLookupError.notFound) {
            try await makeService().lookup(barcode: "9999999999999")
        }
    }

    @Test func blankBarcodeThrowsNotFoundWithoutRequest() async throws {
        FixtureURLProtocol.responder = { _ in
            Issue.record("a blank barcode must not trigger a network request")
            throw URLError(.badURL)
        }
        await #expect(throws: ProductLookupError.notFound) {
            try await makeService().lookup(barcode: "   ")
        }
    }

    // MARK: - Invalid response

    @Test func malformedJSONThrowsInvalidResponse() async throws {
        respond(json: "{ this is not valid json")
        await #expect(throws: ProductLookupError.invalidResponse) {
            try await makeService().lookup(barcode: "3333333333333")
        }
    }

    @Test func validJSONWithWrongShapeThrowsInvalidResponse() async throws {
        // Syntactically valid JSON, but missing the required `status`
        // field — decoding fails and maps to `.invalidResponse`.
        respond(json: #"{"unexpected":true}"#)
        await #expect(throws: ProductLookupError.invalidResponse) {
            try await makeService().lookup(barcode: "8888888888888")
        }
    }

    // MARK: - Network failure

    @Test func transportFailureThrowsNetwork() async throws {
        FixtureURLProtocol.responder = { _ in
            throw URLError(.notConnectedToInternet)
        }
        await #expect(throws: ProductLookupError.network) {
            try await makeService().lookup(barcode: "4444444444444")
        }
    }

    @Test func serverErrorStatusThrowsNetwork() async throws {
        respond(json: #"{"status":1}"#, statusCode: 503)
        await #expect(throws: ProductLookupError.network) {
            try await makeService().lookup(barcode: "5555555555555")
        }
    }
}
