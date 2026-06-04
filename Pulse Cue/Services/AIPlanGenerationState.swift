//
//  AIPlanGenerationState.swift
//  Pulse Cue
//
//  Pure, view-agnostic state for the AI plan generation UX
//  (`MockAITrainingPlanChatView`): a phase machine for
//  loading / success / failure / cancel, and a user-facing error category
//  with safe Japanese copy. Kept free of SwiftUI / networking / persistence
//  so it can be unit-tested without a running provider.
//
//  Boundaries (locked for this PR):
//   - No raw provider error, raw response body, or `userMessage` is ever
//     represented here — only a small set of presentation categories.
//   - No networking, no `ModelContext`, no `Routine`/`Step`. This type
//     never saves anything; saving stays an explicit, user-driven action.
//

import Foundation

// MARK: - User-facing error category

/// The handful of error situations the AI plan screen distinguishes for the
/// user. Provider-internal detail is intentionally collapsed into these
/// categories so no raw error or body can leak into UI copy or logs.
nonisolated enum AIPlanGenerationError: Equatable, Sendable {
    case timeout
    case unauthorized
    case rateLimited
    case providerUnavailable
    case invalidResponse
    case unknown

    /// Non-alarming, actionable Japanese copy. Safe to show directly.
    var message: String {
        switch self {
        case .timeout:
            return "通信に時間がかかっています。もう一度お試しください。"
        case .unauthorized:
            return "認証情報を確認してください。"
        case .rateLimited:
            return "短時間にリクエストが集中しています。少し待ってから再試行してください。"
        case .providerUnavailable:
            return "プラン作成機能が一時的に利用できません。"
        case .invalidResponse:
            return "プラン候補を作成できませんでした。条件を変えて再試行してください。"
        case .unknown:
            return "プラン候補を作成できませんでした。"
        }
    }

    /// Maps any thrown error to a safe presentation category. Endpoint
    /// client errors (`AITrainingPlanEndpointError`) are translated case by
    /// case; anything else collapses to `.unknown`. Cancellation is **not**
    /// an error and must be handled by the caller before reaching here.
    static func from(_ error: Error) -> AIPlanGenerationError {
        guard let endpointError = error as? AITrainingPlanEndpointError else {
            return .unknown
        }
        switch endpointError {
        case .timeout:
            return .timeout
        case .unauthorized:
            return .unauthorized
        case .rateLimited:
            return .rateLimited
        case .providerUnavailable, .transportFailed:
            return .providerUnavailable
        case .invalidRequest, .invalidProviderResponse, .invalidResponse:
            return .invalidResponse
        case .invalidConfiguration, .encodingFailed, .unknown:
            return .unknown
        }
    }
}

// MARK: - Generation phase

/// Drives loading / success / failure / cancel handling for the AI plan
/// screen. Pure and `Equatable`; the view derives every affordance
/// (spinner, disabled button, cancel button, error card, retry) from it.
nonisolated enum AIPlanGenerationPhase: Equatable, Sendable {
    case idle
    case generating
    case success
    case failure(AIPlanGenerationError)
    case cancelled

    /// A request is in flight — show the spinner and loading copy.
    var isGenerating: Bool {
        self == .generating
    }

    /// A new generation may be started (no request currently in flight).
    var canStartGeneration: Bool {
        self != .generating
    }

    /// Retry is offered only after a failure, and only on explicit tap.
    var canRetry: Bool {
        if case .failure = self { return true }
        return false
    }

    /// The cancel affordance is shown only while generating.
    var showsCancel: Bool {
        self == .generating
    }

    /// The mapped error when in the failure phase, otherwise `nil`.
    var failureError: AIPlanGenerationError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
