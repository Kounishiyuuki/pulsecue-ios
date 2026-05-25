//
//  MockPhotoFoodEstimationEndpointClient.swift
//  Pulse Cue
//
//  Deterministic offline implementation of the future-backend
//  `PhotoFoodEstimationEndpointClient` boundary. It exists so the
//  request → response → candidate flow is exercised end-to-end
//  *before* any real networking or AI provider is added.
//
//  Boundaries (locked for this PR):
//   - No `URLSession`, no `URLRequest`, no `URLProtocol`, no upload.
//     Nothing in this file touches the network or persists anything.
//   - Returns a fixed response regardless of the request, echoing
//     back `request.requestId` for caller correlation.
//   - Does **not** log the image payload (or any field of the
//     request) — see §9 of `Docs/photo-ai-backend-token-spec.md`.
//
//  The values intentionally differ from `MockPhotoFoodEstimator`'s
//  so a future caller wiring this client through `PhotoFoodEstimating`
//  is distinguishable in tests and previews.
//

import Foundation

struct MockPhotoFoodEstimationEndpointClient: PhotoFoodEstimationEndpointClient {

    func estimate(request: PhotoFoodEstimateRequest) async throws -> PhotoFoodEstimateResponse {
        PhotoFoodEstimateResponse(
            name: "推定された食事（モックエンドポイント）",
            kcal: 510,
            proteinGrams: 24,
            carbGrams: 55,
            fatGrams: 18,
            confidence: 0.6,
            warnings: ["これはモック応答です。分量推定の不確実性があります。"],
            model: "mock-photo-food-1",
            requestId: request.requestId
        )
    }
}
