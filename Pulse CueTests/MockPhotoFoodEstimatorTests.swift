//
//  MockPhotoFoodEstimatorTests.swift
//  Pulse CueTests
//
//  Tests for the mock-only photo food estimator. They confirm the
//  mock is deterministic and produces a usable review candidate. No
//  real AI, no network — the estimator is a pure offline placeholder.
//

import Testing
@testable import Pulse_Cue

struct MockPhotoFoodEstimatorTests {

    @Test func estimateReturnsDeterministicValues() {
        // Every call returns an identical candidate — the flow and
        // its tests stay stable.
        let first = MockPhotoFoodEstimator.estimate()
        let second = MockPhotoFoodEstimator.estimate()
        #expect(first == second)
    }

    @Test func estimateMatchesTheFixedMockCandidate() {
        let estimate = MockPhotoFoodEstimator.estimate()
        #expect(estimate.name == "推定された食事（モック）")
        #expect(estimate.kcal == 480)
        #expect(estimate.proteinGrams == 22)
        #expect(estimate.slot == .lunch)
        #expect(estimate.note == nil)
    }

    @Test func estimateIsAUsableMealCandidate() {
        let estimate = MockPhotoFoodEstimator.estimate()
        #expect(estimate.kcal > 0)
        #expect(!estimate.name.isEmpty)
        #expect(estimate.proteinGrams != nil)
        #expect(MealSlot.allCases.contains(estimate.slot))
    }
}
