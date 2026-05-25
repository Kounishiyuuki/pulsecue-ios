//
//  PhotoFoodEstimationEndpointClient.swift
//  Pulse Cue
//
//  Sub-abstraction below `PhotoFoodEstimating`: the conceptual
//  boundary a future real `PhotoFoodEstimating` implementation (spec
//  PR 65) will use to talk to the PulseCue backend. Defined ahead of
//  time so the request / response / error shape is locked in before
//  any networking code is added.
//
//  See Docs/photo-ai-backend-token-spec.md §7 (request), §8 (response)
//  and §11 (error states).
//
//  Boundaries (locked for this PR):
//   - This file is a contract only. It performs no networking, no
//     upload, no persistence, no logging. Conforming types do.
//   - The only conformer today is `MockPhotoFoodEstimationEndpointClient`
//     (deterministic and fully offline).
//   - `MockPhotoFoodEstimator` (the top-level `PhotoFoodEstimating`)
//     is **not** wired to this client. Both abstractions live in
//     parallel until a real-AI provider lands.
//

import Foundation

// MARK: - Request

/// Conceptual request sent to the future photo AI backend endpoint.
/// Plain value type — no networking, no upload happens here. Field
/// shape matches §7 of `Docs/photo-ai-backend-token-spec.md`; the
/// list deliberately excludes user / device IDs, location, weight,
/// and other sensitive context.
struct PhotoFoodEstimateRequest: Equatable, Sendable {
    /// Prepared image payload (JPEG bytes + shape). The bytes never
    /// leave the device in this PR; a future real client uploads
    /// them.
    let image: PhotoFoodImagePayload
    /// Optional meal-slot hint (the user picks the slot on capture
    /// and/or review).
    let slot: MealSlot?
    /// Optional short free-text note from the user. Trimmed; blank
    /// input becomes `nil`.
    let userNote: String?
    /// Optional locale hint such as `"ja-JP"`.
    let locale: String?
    /// Optional app version string for debugging — must not identify
    /// the user.
    let appVersion: String?
    /// Per-request identity used to correlate retries and logs
    /// *without* logging the image itself.
    let requestId: UUID

    init(
        image: PhotoFoodImagePayload,
        slot: MealSlot? = nil,
        userNote: String? = nil,
        locale: String? = nil,
        appVersion: String? = nil,
        requestId: UUID = UUID()
    ) {
        self.image = image
        self.slot = slot
        let trimmedNote = userNote?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.userNote = (trimmedNote?.isEmpty ?? true) ? nil : trimmedNote
        self.locale = locale
        self.appVersion = appVersion
        self.requestId = requestId
    }
}

// MARK: - Response

/// Normalized response from the future backend. The backend reshapes
/// provider-specific output into this PulseCue candidate form (see
/// §8 of `Docs/photo-ai-backend-token-spec.md`). It must not leak
/// provider secrets, raw provider responses, or internal endpoints —
/// only the fields below are surfaced to iOS.
struct PhotoFoodEstimateResponse: Equatable, Sendable {
    /// Suggested food name.
    var name: String
    /// Estimated calories.
    var kcal: Int
    /// Optional macros — present when the provider reports them.
    var proteinGrams: Int?
    var carbGrams: Int?
    var fatGrams: Int?
    /// Provider confidence in `[0, 1]`, if reported.
    var confidence: Double?
    /// User-facing warnings such as "分量推定の不確実性が高い". These
    /// are short strings safe to display on the review screen.
    var warnings: [String]?
    /// Safe-to-show model identifier — never a secret.
    var model: String?
    /// Echoed-back per-request id for client-side correlation.
    var requestId: UUID?

    /// Map the normalized response to the existing `PhotoFoodEstimate`
    /// candidate the review screen consumes.
    ///
    /// The slot comes from the calling context — the user selects it
    /// on capture or on the review screen, the backend response
    /// itself carries no slot. Warnings, if any, are joined into the
    /// candidate's `note` so they reach the review screen without a
    /// new field on `PhotoFoodEstimate`.
    func toCandidate(suggestedSlot: MealSlot = .snack) -> PhotoFoodEstimate {
        let note: String?
        if let warnings, !warnings.isEmpty {
            note = warnings.joined(separator: "\n")
        } else {
            note = nil
        }
        return PhotoFoodEstimate(
            name: name,
            kcal: kcal,
            proteinGrams: proteinGrams,
            slot: suggestedSlot,
            note: note
        )
    }
}

// MARK: - Error

/// Error cases a backend / token endpoint can surface, mirroring the
/// `error.code` set in §8 of `Docs/photo-ai-backend-token-spec.md`.
/// Provider-internal stack traces / raw provider errors are never
/// represented here.
enum PhotoFoodEstimateError: Error, Equatable, Sendable {
    case unauthenticated
    case rateLimited
    case quotaExceeded
    case unsupportedImage
    case noFoodDetected
    case providerUnavailable
    case badRequest
    case internalError
}

// MARK: - Client protocol

/// Abstraction over the future photo AI backend endpoint. A
/// conforming type takes a `PhotoFoodEstimateRequest` and produces a
/// normalized `PhotoFoodEstimateResponse`.
///
/// `async throws` keeps the call site stable when the real provider
/// (which performs I/O and can fail) replaces the mock — same shape
/// as the higher-level `PhotoFoodEstimating` protocol.
///
/// Today the only conformer is `MockPhotoFoodEstimationEndpointClient`,
/// which is fully offline and deterministic.
protocol PhotoFoodEstimationEndpointClient {
    func estimate(request: PhotoFoodEstimateRequest) async throws -> PhotoFoodEstimateResponse
}
