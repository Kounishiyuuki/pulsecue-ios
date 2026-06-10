//
//  AIPlanGenerationStateTests.swift
//  Pulse CueTests
//
//  Pure tests for the AI plan generation phase machine and the user-facing
//  error mapping. No network, no provider, no token, no server — just the
//  value types that drive loading / failure / retry / cancel UX.
//

import Foundation
import Testing
@testable import Pulse_Cue

@Suite
struct AIPlanGenerationStateTests {

    // MARK: - Phase representability & derived affordances

    @Test
    func idleAllowsStartAndNothingElse() {
        let phase = AIPlanGenerationPhase.idle
        #expect(phase.isGenerating == false)
        #expect(phase.canStartGeneration == true)
        #expect(phase.canRetry == false)
        #expect(phase.showsCancel == false)
        #expect(phase.failureError == nil)
    }

    @Test
    func generatingBlocksDuplicateStartsAndShowsCancel() {
        let phase = AIPlanGenerationPhase.generating
        #expect(phase.isGenerating == true)
        // Duplicate generation is blocked while a request is in flight.
        #expect(phase.canStartGeneration == false)
        #expect(phase.canRetry == false)
        #expect(phase.showsCancel == true)
    }

    @Test
    func successAllowsStartButNoRetryOrCancel() {
        let phase = AIPlanGenerationPhase.success
        #expect(phase.isGenerating == false)
        #expect(phase.canStartGeneration == true)
        #expect(phase.canRetry == false)
        #expect(phase.showsCancel == false)
        #expect(phase.failureError == nil)
    }

    @Test
    func failureOffersRetryAndCarriesError() {
        let phase = AIPlanGenerationPhase.failure(.timeout)
        #expect(phase.isGenerating == false)
        #expect(phase.canStartGeneration == true)
        // Retry is available only after failure, and only on explicit tap.
        #expect(phase.canRetry == true)
        #expect(phase.showsCancel == false)
        #expect(phase.failureError == .timeout)
    }

    @Test
    func cancelledReturnsToANonGeneratingNonFailureState() {
        let phase = AIPlanGenerationPhase.cancelled
        #expect(phase.isGenerating == false)
        #expect(phase.canStartGeneration == true)
        // Cancellation is not a failure — no retry affordance, no error.
        #expect(phase.canRetry == false)
        #expect(phase.showsCancel == false)
        #expect(phase.failureError == nil)
    }

    // MARK: - Endpoint error mapping

    @Test
    func endpointErrorsMapToExpectedCategories() {
        #expect(AIPlanGenerationError.from(AITrainingPlanEndpointError.timeout) == .timeout)
        #expect(AIPlanGenerationError.from(AITrainingPlanEndpointError.unauthorized) == .unauthorized)
        #expect(AIPlanGenerationError.from(AITrainingPlanEndpointError.tokenExpired) == .tokenExpired)
        #expect(AIPlanGenerationError.from(AITrainingPlanEndpointError.invalidScope) == .invalidScope)
        #expect(AIPlanGenerationError.from(AITrainingPlanEndpointError.rateLimited) == .rateLimited)
        #expect(AIPlanGenerationError.from(AITrainingPlanEndpointError.providerUnavailable) == .providerUnavailable)
        #expect(AIPlanGenerationError.from(AITrainingPlanEndpointError.transportFailed) == .providerUnavailable)
        #expect(AIPlanGenerationError.from(AITrainingPlanEndpointError.invalidRequest) == .invalidResponse)
        #expect(AIPlanGenerationError.from(AITrainingPlanEndpointError.invalidProviderResponse) == .invalidResponse)
        #expect(AIPlanGenerationError.from(AITrainingPlanEndpointError.invalidResponse) == .invalidResponse)
        #expect(AIPlanGenerationError.from(AITrainingPlanEndpointError.invalidConfiguration) == .unknown)
        #expect(AIPlanGenerationError.from(AITrainingPlanEndpointError.encodingFailed) == .unknown)
        #expect(AIPlanGenerationError.from(AITrainingPlanEndpointError.unknown) == .unknown)
    }

    @Test
    func nonEndpointErrorsCollapseToUnknown() {
        struct SomeOtherError: Error {}
        #expect(AIPlanGenerationError.from(SomeOtherError()) == .unknown)
        #expect(AIPlanGenerationError.from(CancellationError()) == .unknown)
    }

    // MARK: - Copy safety

    @Test
    func everyCategoryHasNonEmptyJapaneseCopy() {
        let categories: [AIPlanGenerationError] = [
            .timeout, .unauthorized, .tokenExpired, .invalidScope, .rateLimited,
            .providerUnavailable, .invalidResponse, .unknown,
        ]
        for category in categories {
            #expect(!category.message.isEmpty)
        }
        // Spot-check the exact copy for a couple of categories.
        #expect(AIPlanGenerationError.timeout.message == "通信に時間がかかっています。もう一度お試しください。")
        #expect(AIPlanGenerationError.unauthorized.message == "認証情報を確認してください。")
        #expect(AIPlanGenerationError.tokenExpired.message == "認証の有効期限が切れています。再度お試しください。")
        #expect(AIPlanGenerationError.invalidScope.message == "この操作に必要な権限を確認してください。")
    }

    @Test
    func copyNeverLeaksRawErrorDetail() {
        // Mapped copy must not echo enum case names or raw provider detail.
        for category in [AIPlanGenerationError.timeout, .unauthorized, .tokenExpired,
                         .invalidScope, .rateLimited, .providerUnavailable,
                         .invalidResponse, .unknown] {
            #expect(!category.message.contains("Error"))
            #expect(!category.message.contains("AITrainingPlanEndpointError"))
        }
    }
}
