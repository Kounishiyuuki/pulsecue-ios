//
//  AICoachStub.swift
//  Pulse Cue
//
//  Local-only protocol surface for the future "AI Coach" feature.
//  This file intentionally does NOT call any external API and does NOT
//  carry any secrets. It exists so the rest of the app can compile
//  against a stable shape while the actual implementation (which will
//  require an API key and explicit user opt-in) is built out
//  separately.
//
//  Privacy / safety boundaries (enforced by callers, documented here):
//  1. Nothing produced by an AI service is ever written to a SwiftData
//     model without an explicit user confirmation step.
//  2. Inputs sent to a remote service must be limited to what the user
//     consented to share for that single request. Routine names and
//     DayLog values must never be uploaded silently.
//  3. The default `DisabledAICoach` returns `.disabled` from every
//     entry point and surfaces no UI.
//

import Foundation

// MARK: - Coach

/// What the user is asking the coach to do.
enum AICoachIntent: String, Codable, Equatable {
    case suggestNextRoutine
    case adjustVolume
    case explainPlateau
}

/// Structured request handed to the coach. Keep this small and
/// inspectable — it must be reviewable by the user before sending.
struct AICoachRequest: Codable, Equatable {
    let intent: AICoachIntent
    /// Last N completed sessions, summarized as plain numbers. The
    /// caller decides what to include; nothing is fetched implicitly.
    let recentSessionSummaries: [SessionSummary]
    let userNote: String?

    struct SessionSummary: Codable, Equatable {
        let dayDate: Date
        let routineName: String
        let totalSeconds: Int
        let completedSets: Int
        let skippedSets: Int
    }
}

/// One actionable suggestion. The UI layer must show these as
/// suggestions, never apply them automatically.
struct AICoachSuggestion: Codable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let detail: String
    /// Optional structured action the UI can offer ("Apply"). Nil
    /// means the suggestion is informational only.
    let proposedAction: ProposedAction?

    enum ProposedAction: Codable, Equatable {
        case adjustStepReps(stepTitle: String, newReps: Int)
        case adjustStepRest(stepTitle: String, newRestSeconds: Int)
        case addStep(title: String, sets: Int, repsTarget: Int, restSeconds: Int)
    }
}

enum AICoachResult: Equatable {
    case disabled
    case ok([AICoachSuggestion])
    case error(String)
}

protocol AICoaching {
    var isEnabled: Bool { get }
    func suggest(_ request: AICoachRequest) async -> AICoachResult
}

/// Default coach: always disabled. Replace with a real implementation
/// when the AI feature ships.
struct DisabledAICoach: AICoaching {
    var isEnabled: Bool { false }
    func suggest(_ request: AICoachRequest) async -> AICoachResult {
        .disabled
    }
}

// MARK: - Meal calorie estimator

/// Source of the meal estimate. Photo / text / barcode are the obvious
/// candidates; the protocol stays neutral.
enum MealEstimationSource: String, Codable, Equatable {
    case photo
    case text
    case barcode
}

struct MealEstimationRequest: Codable, Equatable {
    let source: MealEstimationSource
    /// For `.text`: the user's free-form description. For `.photo` /
    /// `.barcode`: a short caption or empty.
    let description: String
}

struct MealEstimate: Codable, Equatable {
    let estimatedKcal: Int
    /// 0...1 confidence the estimator reports. UI must surface this
    /// so the user can dismiss low-confidence values.
    let confidence: Double
    let breakdown: [LineItem]

    struct LineItem: Codable, Equatable {
        let name: String
        let kcal: Int
    }
}

enum MealEstimationResult: Equatable {
    case disabled
    case ok(MealEstimate)
    case error(String)
}

protocol MealCalorieEstimating {
    var isEnabled: Bool { get }
    func estimate(_ request: MealEstimationRequest) async -> MealEstimationResult
}

/// Default estimator: always disabled. Real implementation will require
/// explicit opt-in plus an API key (managed outside source control).
struct DisabledMealCalorieEstimator: MealCalorieEstimating {
    var isEnabled: Bool { false }
    func estimate(_ request: MealEstimationRequest) async -> MealEstimationResult {
        .disabled
    }
}

// MARK: - Provider

/// Single swap point for the rest of the app. Keep both providers
/// returning the disabled implementations until the AI feature is
/// gated on by a real opt-in flow.
enum AIServicesProvider {
    static var coach: AICoaching = DisabledAICoach()
    static var mealEstimator: MealCalorieEstimating = DisabledMealCalorieEstimator()
}

// MARK: - Confirmation helpers

/// Type the UI should use to wrap any AI-produced value before
/// persisting. Construct only when the user has explicitly confirmed.
struct UserConfirmed<Value> {
    let value: Value
    let confirmedAt: Date

    init(_ value: Value, at date: Date = Date()) {
        self.value = value
        self.confirmedAt = date
    }
}

/// Apply a meal estimate to a DayLog only after wrapping it in
/// `UserConfirmed`. This keeps the privacy boundary visible at every
/// call site.
func applyConfirmedMealEstimate(
    _ confirmed: UserConfirmed<MealEstimate>,
    to dayLog: DayLog,
    addToExisting: Bool = true
) {
    let kcal = confirmed.value.estimatedKcal
    if addToExisting, let current = dayLog.intakeCalories {
        dayLog.intakeCalories = current + kcal
    } else {
        dayLog.intakeCalories = kcal
    }
}
