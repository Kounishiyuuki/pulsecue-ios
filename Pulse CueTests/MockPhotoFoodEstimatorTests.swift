//
//  MockPhotoFoodEstimatorTests.swift
//  Pulse CueTests
//
//  Tests for the mock-only photo food estimation provider and the
//  image-aware input contract. They confirm the mock conforms to the
//  `PhotoFoodEstimating` abstraction, is deterministic + offline, and
//  deliberately ignores its input. No real AI, no network — the mock
//  is a pure offline placeholder behind the provider protocol.
//

import Testing
import UIKit
@testable import Pulse_Cue

struct MockPhotoFoodEstimatorTests {

    /// A tiny solid image for input-construction tests. Built from a
    /// `CGContext` so the dimensions are exact and deterministic.
    private func makeImage(width: Int, height: Int) -> UIImage {
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
        return UIImage(cgImage: context.makeImage()!)
    }

    // MARK: - Input contract

    @Test func inputCanBeConstructedForALocalImageCandidate() {
        let input = PhotoFoodEstimationInput(image: makeImage(width: 4, height: 2))
        #expect(input.image != nil)
        #expect(input.pixelSize == CGSize(width: 4, height: 2))
    }

    @Test func inputCanBeConstructedWithoutAnImage() {
        // The contract is exercisable without a real UIImage.
        let input = PhotoFoodEstimationInput(image: nil)
        #expect(input.image == nil)
        #expect(input.pixelSize == nil)
    }

    // MARK: - Mock provider

    @Test func estimateReturnsDeterministicValues() async throws {
        let input = PhotoFoodEstimationInput(image: nil)
        let first = try await MockPhotoFoodEstimator().estimate(input: input)
        let second = try await MockPhotoFoodEstimator().estimate(input: input)
        #expect(first == second)
    }

    @Test func estimateMatchesTheFixedMockCandidate() async throws {
        let estimate = try await MockPhotoFoodEstimator()
            .estimate(input: PhotoFoodEstimationInput(image: nil))
        #expect(estimate.name == "推定された食事（モック）")
        #expect(estimate.kcal == 480)
        #expect(estimate.proteinGrams == 22)
        #expect(estimate.slot == .lunch)
        #expect(estimate.note == nil)
    }

    @Test func estimateIsAUsableMealCandidate() async throws {
        let estimate = try await MockPhotoFoodEstimator()
            .estimate(input: PhotoFoodEstimationInput(image: nil))
        #expect(estimate.kcal > 0)
        #expect(!estimate.name.isEmpty)
        #expect(estimate.proteinGrams != nil)
        #expect(MealSlot.allCases.contains(estimate.slot))
    }

    /// The mock deliberately ignores its input — a large image, a
    /// small image, and no image all yield the same candidate. This
    /// is intentional: the mock has nothing to infer and never reads
    /// the image, which keeps it offline and upload-free.
    @Test func estimateIgnoresInputByDesign() async throws {
        let estimator = MockPhotoFoodEstimator()
        let fromLargeImage = try await estimator
            .estimate(input: PhotoFoodEstimationInput(image: makeImage(width: 64, height: 64)))
        let fromSmallImage = try await estimator
            .estimate(input: PhotoFoodEstimationInput(image: makeImage(width: 4, height: 4)))
        let fromNoImage = try await estimator
            .estimate(input: PhotoFoodEstimationInput(image: nil))
        #expect(fromLargeImage == fromSmallImage)
        #expect(fromSmallImage == fromNoImage)
    }

    /// The mock satisfies the `PhotoFoodEstimating` abstraction —
    /// a real provider can replace it behind the same protocol
    /// without changing the call site.
    @Test func mockConformsToPhotoFoodEstimating() async throws {
        let provider: any PhotoFoodEstimating = MockPhotoFoodEstimator()
        let viaProtocol = try await provider
            .estimate(input: PhotoFoodEstimationInput(image: nil))
        let viaConcrete = try await MockPhotoFoodEstimator()
            .estimate(input: PhotoFoodEstimationInput(image: nil))
        #expect(viaProtocol == viaConcrete)
    }
}

/// Test-only `PhotoFoodEstimating` that always throws — used to
/// exercise `PhotoEstimationRunner`'s failure path. Not production code.
private struct FailingPhotoFoodEstimator: PhotoFoodEstimating {
    struct EstimationFailure: Error {}
    func estimate(input: PhotoFoodEstimationInput) async throws -> PhotoFoodEstimate {
        throw EstimationFailure()
    }
}

/// Tests for `PhotoEstimationRunner` — the pure helper that maps a
/// provider call to a success/failure outcome. A fallible provider
/// becomes a retryable `.failure`, never a crash or silent drop.
struct PhotoEstimationRunnerTests {

    @Test func successfulProviderYieldsCandidateOutcome() async throws {
        let input = PhotoFoodEstimationInput(image: nil)
        let expected = try await MockPhotoFoodEstimator().estimate(input: input)
        let outcome = await PhotoEstimationRunner.run(
            estimator: MockPhotoFoodEstimator(),
            input: input
        )
        #expect(outcome == .candidate(expected))
    }

    @Test func failingProviderYieldsFailureOutcome() async {
        let outcome = await PhotoEstimationRunner.run(
            estimator: FailingPhotoFoodEstimator(),
            input: PhotoFoodEstimationInput(image: nil)
        )
        #expect(outcome == .failure(message: PhotoEstimationRunner.failureMessage))
    }

    /// A failure outcome must carry a non-empty user-facing message
    /// so the capture screen can show a visible, retryable error.
    @Test func failureOutcomeCarriesANonEmptyUserMessage() async {
        let outcome = await PhotoEstimationRunner.run(
            estimator: FailingPhotoFoodEstimator(),
            input: PhotoFoodEstimationInput(image: nil)
        )
        if case .failure(let message) = outcome {
            #expect(!message.isEmpty)
        } else {
            Issue.record("expected a failure outcome from a failing provider")
        }
    }

    /// The runner never persists anything — it only maps a provider
    /// result to an outcome value.
    @Test func runnerProducesACandidateOutcomeWithoutSideEffects() async {
        let outcome = await PhotoEstimationRunner.run(
            estimator: MockPhotoFoodEstimator(),
            input: PhotoFoodEstimationInput(image: nil)
        )
        guard case .candidate = outcome else {
            Issue.record("expected a candidate outcome from the mock provider")
            return
        }
    }
}
