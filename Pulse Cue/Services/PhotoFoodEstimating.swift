//
//  PhotoFoodEstimating.swift
//  Pulse Cue
//
//  Provider abstraction for photo food estimation. This is the clean
//  boundary the photo-estimation flow depends on, so a real AI
//  provider can be added later without rewriting the capture UI or
//  the review/save flow.
//
//  Boundaries (locked for this PR):
//   - This file defines a *contract* only. It performs no estimation,
//     no networking, no AI, and no photo upload — concrete providers
//     do. The single provider today is the offline `MockPhotoFoodEstimator`.
//   - A `PhotoFoodEstimate` is a *candidate* only. It creates no
//     MealEntry and never touches DayLog / NutritionLedger /
//     ProteinTotals; the save happens only after the user confirms
//     on `PhotoEstimateReviewView`.
//   - `PhotoFoodEstimationInput` carries the image in memory only.
//     This app never persists or uploads it, and a real provider
//     must not log or store the image data either — see
//     Docs/photo-ai-provider-strategy.md §7.
//

import Foundation
import UIKit

/// Input handed to a `PhotoFoodEstimating` provider: a selected or
/// captured meal image, represented locally.
///
/// Lightweight and local by design:
///  - `image` is held in memory only. This app never persists or
///    uploads it; a real provider must not log or store it either.
///  - `image` is optional so the contract is exercisable in tests
///    (and by a future prepared-payload provider) without a real
///    `UIImage`.
///  - `id` is a per-selection identity a provider may use to
///    correlate retries or logs *without* logging the image itself.
///
/// `@unchecked Sendable`: every stored value is an immutable `let`,
/// and the `UIImage` is treated as read-only and never mutated, so
/// the value is safe to hand to a provider running off the main actor.
struct PhotoFoodEstimationInput: @unchecked Sendable {
    /// Stable per-selection identity. Carries no image data.
    let id: UUID
    /// Pixel dimensions of the image, if one is present.
    let pixelSize: CGSize?
    /// The selected / captured image, in memory only — never
    /// persisted or uploaded by this app.
    let image: UIImage?

    init(image: UIImage?, id: UUID = UUID()) {
        self.id = id
        self.image = image
        if let cgImage = image?.cgImage {
            self.pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        } else {
            self.pixelSize = nil
        }
    }
}

/// A reviewable photo-food-estimation candidate. Plain value type —
/// it creates no MealEntry and touches no store; the review screen
/// turns it into a confirmed meal only after the user confirms.
struct PhotoFoodEstimate: Equatable {
    /// Suggested food name. Editable on the review screen.
    var name: String
    /// Estimated calories. Editable on the review screen.
    var kcal: Int
    /// Estimated protein grams, if the estimator produced one.
    var proteinGrams: Int?
    /// Suggested meal slot. Editable on the review screen.
    var slot: MealSlot
    /// Optional free-text note carried into the review screen.
    var note: String?
}

/// Abstraction over photo food estimation: a conforming type turns a
/// selected/captured image into a reviewable `PhotoFoodEstimate`
/// candidate.
///
/// `async throws` is intentional even though the only implementation
/// today is a synchronous, infallible mock. A real provider (a later
/// PR) will perform on-device or networked inference that takes time
/// and can fail; keeping the contract async/throwing means the UI
/// call site does not change when the real provider lands.
///
/// `estimate(input:)` takes a `PhotoFoodEstimationInput` so the
/// boundary is ready for a real, image-aware provider. The current
/// `MockPhotoFoodEstimator` ignores the input — it has nothing to
/// infer and never reads the image, so "no photo upload" stays
/// structurally guaranteed until a real provider is deliberately
/// added.
protocol PhotoFoodEstimating {
    /// Produce a candidate estimate for review from `input`. The
    /// result is a candidate only — the caller never persists it
    /// without an explicit user confirmation.
    func estimate(input: PhotoFoodEstimationInput) async throws -> PhotoFoodEstimate
}
