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
//

import Foundation

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

/// Abstraction over photo food estimation: a conforming type turns
/// the photo-capture step into a reviewable `PhotoFoodEstimate`
/// candidate.
///
/// `async throws` is intentional even though the only implementation
/// today is a synchronous, infallible mock. A real provider (a later
/// PR) will perform on-device or networked inference that takes time
/// and can fail; keeping the contract async/throwing now means the
/// UI call site does not change when the real provider lands.
///
/// The current method takes no input. A real, image-aware provider
/// will accept image data — via an added parameter or a dedicated
/// method — when it is introduced. The mock deliberately has no image
/// input so that "no photo upload" stays structurally guaranteed
/// until a real provider is deliberately added.
protocol PhotoFoodEstimating {
    /// Produce a candidate estimate for review. The result is a
    /// candidate only — the caller never persists it without an
    /// explicit user confirmation.
    func estimate() async throws -> PhotoFoodEstimate
}
