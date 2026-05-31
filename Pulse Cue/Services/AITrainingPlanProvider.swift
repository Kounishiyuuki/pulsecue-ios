//
//  AITrainingPlanProvider.swift
//  Pulse Cue
//
//  Local-only boundary for a *future* AI chat planning feature. This
//  file defines the request/response value types, a provider protocol,
//  a deterministic offline mock, and a normalizer that turns provider
//  output into the existing `WeeklyTrainingPlanCandidate`. It is
//  deliberately inert:
//
//   - no networking, no URLSession/URLRequest, no API keys, no secrets,
//   - no real AI / OpenAI / provider calls — only `MockAITrainingPlanProvider`,
//   - no persistence — it produces candidate values only and never
//     creates/saves `Routine`/`Step` or touches a `ModelContext`.
//
//  The boundary mirrors `PhotoFoodEstimating` / `MockPhotoFoodEstimator`:
//  the app codes against the protocol so a real provider can be swapped
//  in later without touching call sites. AI output MUST pass through
//  `AITrainingPlanNormalizer` (which validates, drops unknown machines,
//  and attaches warnings) before any review/save step.
//

import Foundation

// MARK: - Request

/// What the (future) AI planner is asked to produce. All planning-shape
/// fields are optional so a free-form chat message can stand alone; the
/// normalizer fills safe defaults.
struct AITrainingPlanRequest: Equatable {
    var userMessage: String
    var goal: TrainingGoal?
    var daysPerWeek: Int?
    var targetBodyParts: [BodyPart]
    var experienceLevel: ExperienceLevel?
    var preferredSplit: TrainingSplit?
    /// Machine ids the user actually has access to. When empty the mock
    /// falls back to the full local catalog.
    var availableMachineIds: [String]

    init(
        userMessage: String = "",
        goal: TrainingGoal? = nil,
        daysPerWeek: Int? = nil,
        targetBodyParts: [BodyPart] = [],
        experienceLevel: ExperienceLevel? = nil,
        preferredSplit: TrainingSplit? = nil,
        availableMachineIds: [String] = []
    ) {
        self.userMessage = userMessage
        self.goal = goal
        self.daysPerWeek = daysPerWeek
        self.targetBodyParts = targetBodyParts
        self.experienceLevel = experienceLevel
        self.preferredSplit = preferredSplit
        self.availableMachineIds = availableMachineIds
    }
}

// MARK: - Response

/// One day in a raw AI plan. Exercises are referenced by catalog machine
/// id only — the normalizer resolves them and discards anything unknown.
struct AITrainingSessionResponse: Equatable {
    var title: String?
    var exerciseMachineIds: [String]
    var notes: String?

    init(title: String? = nil, exerciseMachineIds: [String] = [], notes: String? = nil) {
        self.title = title
        self.exerciseMachineIds = exerciseMachineIds
        self.notes = notes
    }
}

/// Raw, untrusted AI output. Treated as a suggestion to be validated —
/// never persisted directly.
struct AITrainingPlanResponse: Equatable {
    var title: String?
    var sessions: [AITrainingSessionResponse]
    var rationale: String?
    var warnings: [String]

    init(
        title: String? = nil,
        sessions: [AITrainingSessionResponse] = [],
        rationale: String? = nil,
        warnings: [String] = []
    ) {
        self.title = title
        self.sessions = sessions
        self.rationale = rationale
        self.warnings = warnings
    }
}

// MARK: - Provider protocol

/// Abstraction the app codes against. The only conformer in this PR is
/// `MockAITrainingPlanProvider`; a real (networked) provider is future
/// work and is out of scope here.
protocol AITrainingPlanProviding {
    func generatePlan(for request: AITrainingPlanRequest) async throws -> AITrainingPlanResponse
}

// MARK: - Mock provider

/// Deterministic, fully offline stand-in. Given the same request it
/// always returns the same response — no RNG, no clock, no I/O. It does
/// not interpret `userMessage`; it just lays the available machines out
/// across the requested number of days so the rest of the pipeline can
/// be exercised end-to-end without a real model.
struct MockAITrainingPlanProvider: AITrainingPlanProviding {
    static let minDays = 1
    static let maxDays = 6

    func generatePlan(for request: AITrainingPlanRequest) async throws -> AITrainingPlanResponse {
        let days = min(max(request.daysPerWeek ?? 3, Self.minDays), Self.maxDays)

        // Deterministic, id-sorted machine pool.
        let pool: [String]
        if request.availableMachineIds.isEmpty {
            pool = MachineCatalog.all.map(\.id)
        } else {
            pool = request.availableMachineIds.sorted()
        }

        var sessions: [AITrainingSessionResponse] = []
        for day in 0..<days {
            // Round-robin slice so each day gets a stable subset.
            let machines = pool.enumerated()
                .filter { $0.offset % days == day }
                .map(\.element)
            sessions.append(
                AITrainingSessionResponse(
                    title: "Day \(day + 1)",
                    exerciseMachineIds: machines,
                    notes: nil
                )
            )
        }

        let goalLabel = request.goal?.displayName ?? "トレーニング"
        return AITrainingPlanResponse(
            title: "\(goalLabel)プラン（AI下書き）",
            sessions: sessions,
            rationale: "ローカルのモックプロバイダによる決定論的な下書きです。",
            warnings: []
        )
    }
}

// MARK: - Normalizer

/// Validates and converts raw `AITrainingPlanResponse` output into the
/// existing `WeeklyTrainingPlanCandidate`. Pure and total: it never
/// throws, never persists, and always returns a candidate (possibly
/// empty with warnings) so the UI has something safe to show.
enum AITrainingPlanNormalizer {
    static let maxDays = 6
    static let sourceLabel = "AI下書き"

    static func normalize(
        response: AITrainingPlanResponse,
        request: AITrainingPlanRequest,
        catalog: [MachineCatalogEntry] = MachineCatalog.all
    ) -> WeeklyTrainingPlanCandidate {
        var warnings: [String] = response.warnings
        func warn(_ message: String) {
            if !warnings.contains(message) { warnings.append(message) }
        }

        let index = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var unknownIds: [String] = []

        var sessions: [TrainingSessionCandidate] = []
        for (offset, rawSession) in response.sessions.enumerated() {
            // Resolve machine ids, preserving order, dropping unknowns.
            var entries: [MachineCatalogEntry] = []
            for id in rawSession.exerciseMachineIds {
                if let entry = index[id] {
                    entries.append(entry)
                } else if !unknownIds.contains(id) {
                    unknownIds.append(id)
                }
            }

            let title = normalizedTitle(rawSession.title, fallbackIndex: offset)

            guard !entries.isEmpty else {
                // Empty sessions never become exercises; surface as a warning.
                warn("「\(title)」に有効なマシンがないためスキップしました。")
                continue
            }

            let exercises = entries.map {
                RoutineStepCandidate(entry: $0, sourceLabel: sourceLabel)
            }
            sessions.append(
                TrainingSessionCandidate(
                    title: title,
                    focusBodyParts: focusBodyParts(for: entries),
                    exercises: exercises,
                    notes: rawSession.notes ?? ""
                )
            )
        }

        if !unknownIds.isEmpty {
            warn("カタログにないマシンを除外しました: \(unknownIds.joined(separator: ", "))")
        }
        if sessions.isEmpty {
            warn("AIからの有効なプランを取得できませんでした。条件を変えて再度お試しください。")
        }

        let goal = request.goal ?? .consistency
        let daysPerWeek = min(max(sessions.count, 0), maxDays)

        return WeeklyTrainingPlanCandidate(
            title: normalizedPlanTitle(response.title, goal: goal),
            goal: goal,
            daysPerWeek: daysPerWeek,
            sessions: sessions,
            rationale: normalizedRationale(response.rationale),
            warnings: warnings
        )
    }

    // MARK: - Helpers

    private static func normalizedTitle(_ raw: String?, fallbackIndex: Int) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Day \(fallbackIndex + 1)" : trimmed
    }

    private static func normalizedPlanTitle(_ raw: String?, goal: TrainingGoal) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "\(goal.displayName)プラン（AI下書き）" : trimmed
    }

    private static func normalizedRationale(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty
            ? "AIによる下書きプランです。保存前に内容を確認してください。"
            : trimmed
    }

    /// Union of the entries' primary body parts, in canonical order.
    private static func focusBodyParts(for entries: [MachineCatalogEntry]) -> [BodyPart] {
        var seen = Set<BodyPart>()
        for entry in entries { seen.formUnion(entry.bodyParts) }
        return BodyPart.allCases.filter { seen.contains($0) }
    }
}
