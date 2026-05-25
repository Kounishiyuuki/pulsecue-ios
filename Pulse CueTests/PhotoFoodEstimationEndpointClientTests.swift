//
//  PhotoFoodEstimationEndpointClientTests.swift
//  Pulse CueTests
//
//  Tests for the mock-only endpoint client abstraction. They exercise:
//   - `PhotoFoodEstimateRequest` construction from a local
//     `PhotoFoodImagePayload`
//   - `MockPhotoFoodEstimationEndpointClient` returning a
//     deterministic offline response
//   - `PhotoFoodEstimateResponse.toCandidate(suggestedSlot:)` mapping
//     to the existing `PhotoFoodEstimate` candidate the review screen
//     consumes
//   - error propagation through the protocol via a test-only failing
//     client
//
//  No real network, no live AI, no API keys. Image payloads are
//  synthesised in-process from tiny `UIImage`s.
//

import Foundation
import Testing
import UIKit
@testable import Pulse_Cue

struct PhotoFoodEstimationEndpointClientTests {

    private func makeImage(width: Int = 64, height: Int = 64) -> UIImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return UIImage(cgImage: context.makeImage()!)
    }

    private func makePayload() throws -> PhotoFoodImagePayload {
        try PhotoFoodImagePayloadPreparer.prepare(from: makeImage())
    }

    // MARK: - Request building

    @Test func requestCanBeBuiltFromImagePayload() throws {
        let payload = try makePayload()
        let request = PhotoFoodEstimateRequest(image: payload)
        #expect(request.image == payload)
        #expect(request.slot == nil)
        #expect(request.userNote == nil)
        #expect(request.locale == nil)
        #expect(request.appVersion == nil)
        // requestId defaults to a fresh UUID, which serialises to a
        // non-empty string.
        #expect(!request.requestId.uuidString.isEmpty)
    }

    @Test func requestKeepsExplicitFields() throws {
        let payload = try makePayload()
        let id = UUID()
        let request = PhotoFoodEstimateRequest(
            image: payload,
            slot: .lunch,
            userNote: "シリアル",
            locale: "ja-JP",
            appVersion: "1.0.0",
            requestId: id
        )
        #expect(request.slot == .lunch)
        #expect(request.userNote == "シリアル")
        #expect(request.locale == "ja-JP")
        #expect(request.appVersion == "1.0.0")
        #expect(request.requestId == id)
    }

    @Test func requestTreatsBlankUserNoteAsNil() throws {
        let payload = try makePayload()
        let request = PhotoFoodEstimateRequest(image: payload, userNote: "   ")
        #expect(request.userNote == nil)
    }

    @Test func requestTrimsUserNote() throws {
        let payload = try makePayload()
        let request = PhotoFoodEstimateRequest(image: payload, userNote: "  ご飯 大盛り  ")
        #expect(request.userNote == "ご飯 大盛り")
    }

    // MARK: - Mock client

    @Test func mockClientReturnsDeterministicResponse() async throws {
        let payload = try makePayload()
        let req = PhotoFoodEstimateRequest(image: payload)
        let client = MockPhotoFoodEstimationEndpointClient()
        let first = try await client.estimate(request: req)
        let second = try await client.estimate(request: req)
        #expect(first == second)
    }

    @Test func mockClientMatchesFixedValues() async throws {
        let payload = try makePayload()
        let req = PhotoFoodEstimateRequest(image: payload)
        let response = try await MockPhotoFoodEstimationEndpointClient()
            .estimate(request: req)
        #expect(response.name == "推定された食事（モックエンドポイント）")
        #expect(response.kcal == 510)
        #expect(response.proteinGrams == 24)
        #expect(response.carbGrams == 55)
        #expect(response.fatGrams == 18)
        #expect(response.confidence == 0.6)
        #expect(response.warnings?.isEmpty == false)
        #expect(response.model == "mock-photo-food-1")
    }

    @Test func mockClientEchoesRequestId() async throws {
        let payload = try makePayload()
        let id = UUID()
        let req = PhotoFoodEstimateRequest(image: payload, requestId: id)
        let response = try await MockPhotoFoodEstimationEndpointClient()
            .estimate(request: req)
        #expect(response.requestId == id)
    }

    /// The mock satisfies the `PhotoFoodEstimationEndpointClient`
    /// abstraction — a future real client can replace it behind the
    /// same protocol without changing the call site.
    @Test func mockConformsToEndpointClientProtocol() async throws {
        let payload = try makePayload()
        let client: any PhotoFoodEstimationEndpointClient =
            MockPhotoFoodEstimationEndpointClient()
        let response = try await client.estimate(
            request: PhotoFoodEstimateRequest(image: payload)
        )
        #expect(response.kcal > 0)
    }

    // MARK: - Response → candidate mapping

    @Test func responseMapsToPhotoFoodEstimateCandidate() {
        let response = PhotoFoodEstimateResponse(
            name: "Test Meal",
            kcal: 300,
            proteinGrams: 10,
            carbGrams: 40,
            fatGrams: 8,
            confidence: 0.7,
            warnings: nil,
            model: "test",
            requestId: UUID()
        )
        let candidate = response.toCandidate(suggestedSlot: .lunch)
        #expect(candidate.name == "Test Meal")
        #expect(candidate.kcal == 300)
        #expect(candidate.proteinGrams == 10)
        #expect(candidate.slot == .lunch)
        #expect(candidate.note == nil)
    }

    @Test func responseMapsWarningsIntoCandidateNote() {
        let response = PhotoFoodEstimateResponse(
            name: "x", kcal: 1,
            proteinGrams: nil, carbGrams: nil, fatGrams: nil,
            confidence: nil,
            warnings: ["分量の不確実性あり", "光量が低めです"],
            model: nil, requestId: nil
        )
        let candidate = response.toCandidate()
        #expect(candidate.note?.contains("分量の不確実性あり") == true)
        #expect(candidate.note?.contains("光量が低めです") == true)
    }

    @Test func responseDefaultSuggestedSlotIsSnack() {
        let response = PhotoFoodEstimateResponse(
            name: "x", kcal: 1,
            proteinGrams: nil, carbGrams: nil, fatGrams: nil,
            confidence: nil, warnings: nil, model: nil, requestId: nil
        )
        let candidate = response.toCandidate()
        #expect(candidate.slot == .snack)
    }

    /// Holding a response and converting it to a candidate must
    /// persist nothing on its own — the candidate is reviewed before
    /// any `MealEntry` is created.
    @Test func candidateAloneCreatesNoSideEffects() async throws {
        let payload = try makePayload()
        let response = try await MockPhotoFoodEstimationEndpointClient()
            .estimate(request: PhotoFoodEstimateRequest(image: payload))
        _ = response.toCandidate()
        // The flow that turns a candidate into a `MealEntry` lives in
        // `PhotoEstimateReviewView.save()` and is unchanged by this
        // PR (see `PhotoEstimateReviewSaveTests`). This test merely
        // documents the boundary: nothing was inserted here.
    }

    // MARK: - Failure path

    /// Test-only client that always throws the configured error.
    /// Not production code.
    private struct FailingPhotoFoodEstimationEndpointClient: PhotoFoodEstimationEndpointClient {
        let error: PhotoFoodEstimateError
        func estimate(request: PhotoFoodEstimateRequest) async throws -> PhotoFoodEstimateResponse {
            throw error
        }
    }

    @Test func failingClientPropagatesProviderUnavailable() async throws {
        let payload = try makePayload()
        let client = FailingPhotoFoodEstimationEndpointClient(error: .providerUnavailable)
        await #expect(throws: PhotoFoodEstimateError.providerUnavailable) {
            try await client.estimate(
                request: PhotoFoodEstimateRequest(image: payload)
            )
        }
    }

    @Test func failingClientPropagatesQuotaExceeded() async throws {
        let payload = try makePayload()
        let client = FailingPhotoFoodEstimationEndpointClient(error: .quotaExceeded)
        await #expect(throws: PhotoFoodEstimateError.quotaExceeded) {
            try await client.estimate(
                request: PhotoFoodEstimateRequest(image: payload)
            )
        }
    }

    @Test func errorCasesAreDistinct() {
        #expect(PhotoFoodEstimateError.unauthenticated != .rateLimited)
        #expect(PhotoFoodEstimateError.unsupportedImage != .noFoodDetected)
        #expect(PhotoFoodEstimateError.badRequest != .internalError)
    }
}
