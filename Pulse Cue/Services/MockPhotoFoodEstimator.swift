//
//  MockPhotoFoodEstimator.swift
//  Pulse Cue
//
//  Mock-only `PhotoFoodEstimating` provider. Produces a reviewable
//  candidate so the photo → candidate → review → confirm → save flow
//  and its safety boundary stay exercised *before* any real AI
//  integration.
//
//  Boundaries (locked for this PR):
//   - No real AI, no OpenAI, no network, no photo upload. The mock
//     does not even take the image — a mock has nothing to infer,
//     and not passing the photo makes "no upload" structural.
//   - The result is a *candidate* only (see `PhotoFoodEstimating`).
//     It creates no MealEntry and never touches DayLog.
//   - Deterministic: every call returns the same candidate, so the
//     flow and its tests are stable.
//
//  A later PR adds a real, image-aware provider conforming to the
//  same `PhotoFoodEstimating` protocol; the candidate type and the
//  review/confirm flow it feeds are designed to stay the same.
//

import Foundation

/// The only `PhotoFoodEstimating` implementation today: a fully
/// offline, deterministic placeholder.
struct MockPhotoFoodEstimator: PhotoFoodEstimating {

    /// Returns the fixed candidate every mock estimation produces.
    ///
    /// `input` is **deliberately ignored**: the mock has nothing to
    /// infer from the image, and never reading it keeps the mock
    /// offline and upload-free. A real provider conforming to
    /// `PhotoFoodEstimating` will use `input.image`. The values are a
    /// plausible placeholder meal — they are *not* inferred from any
    /// image. The method is `async throws` only to satisfy the
    /// protocol; the mock does no async work and never throws. The
    /// review screen makes the mock nature explicit and lets the user
    /// correct every field before saving.
    func estimate(input: PhotoFoodEstimationInput) async throws -> PhotoFoodEstimate {
        PhotoFoodEstimate(
            name: "推定された食事（モック）",
            kcal: 480,
            proteinGrams: 22,
            slot: .lunch,
            note: nil
        )
    }
}
