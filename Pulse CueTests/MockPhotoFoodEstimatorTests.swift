//
//  MockPhotoFoodEstimatorTests.swift
//  Pulse CueTests
//
//  Tests for the mock-only photo food estimation provider. They
//  confirm the mock conforms to the `PhotoFoodEstimating` abstraction
//  and is deterministic + offline. No real AI, no network — the mock
//  is a pure offline placeholder behind the provider protocol.
//

import Testing
@testable import Pulse_Cue

struct MockPhotoFoodEstimatorTests {

    @Test func estimateReturnsDeterministicValues() async throws {
        // Every call returns an identical candidate — the flow and
        // its tests stay stable.
        let first = try await MockPhotoFoodEstimator().estimate()
        let second = try await MockPhotoFoodEstimator().estimate()
        #expect(first == second)
    }

    @Test func estimateMatchesTheFixedMockCandidate() async throws {
        let estimate = try await MockPhotoFoodEstimator().estimate()
        #expect(estimate.name == "推定された食事（モック）")
        #expect(estimate.kcal == 480)
        #expect(estimate.proteinGrams == 22)
        #expect(estimate.slot == .lunch)
        #expect(estimate.note == nil)
    }

    @Test func estimateIsAUsableMealCandidate() async throws {
        let estimate = try await MockPhotoFoodEstimator().estimate()
        #expect(estimate.kcal > 0)
        #expect(!estimate.name.isEmpty)
        #expect(estimate.proteinGrams != nil)
        #expect(MealSlot.allCases.contains(estimate.slot))
    }

    /// The mock satisfies the `PhotoFoodEstimating` abstraction —
    /// a real provider can replace it behind the same protocol
    /// without changing the call site.
    @Test func mockConformsToPhotoFoodEstimating() async throws {
        let provider: any PhotoFoodEstimating = MockPhotoFoodEstimator()
        let viaProtocol = try await provider.estimate()
        let viaConcrete = try await MockPhotoFoodEstimator().estimate()
        #expect(viaProtocol == viaConcrete)
    }
}
