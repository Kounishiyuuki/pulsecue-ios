//
//  MockPhotoFoodEstimator.swift
//  Pulse Cue
//
//  Mock-only photo food estimation. Produces a reviewable candidate
//  so the photo → candidate → review → confirm → save flow and its
//  safety boundary can be locked in *before* any real AI integration.
//
//  Boundaries (locked for this PR):
//   - No real AI, no OpenAI, no network, no photo upload. The mock
//     does not even take the image — a mock has nothing to infer,
//     and not passing the photo makes "no upload" structural.
//   - The result is a *candidate* only. It creates no MealEntry and
//     never touches DayLog / NutritionLedger / ProteinTotals; the
//     save happens only after the user confirms on the review screen.
//   - Deterministic: every call returns the same candidate, so the
//     flow and its tests are stable.
//
//  A later PR replaces this with an async, image-aware provider
//  behind an abstraction (see Docs/photo-food-estimation-flow.md).
//  The candidate type and the review/confirm flow it feeds are
//  designed to stay the same.
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

enum MockPhotoFoodEstimator {

    /// The fixed candidate every mock estimation returns.
    ///
    /// The values are a plausible placeholder meal — they are *not*
    /// inferred from any image. The review screen makes the mock
    /// nature explicit and lets the user correct every field before
    /// saving.
    static func estimate() -> PhotoFoodEstimate {
        PhotoFoodEstimate(
            name: "推定された食事（モック）",
            kcal: 480,
            proteinGrams: 22,
            slot: .lunch,
            note: nil
        )
    }
}
