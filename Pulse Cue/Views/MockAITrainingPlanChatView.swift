//
//  MockAITrainingPlanChatView.swift
//  Pulse Cue
//
//  Local, mock-only "AI plan consultation" screen. The user types a
//  free-form training request; the screen runs the offline
//  `MockAITrainingPlanProvider` through the `AITrainingPlanProviding`
//  boundary, normalizes the raw response with `AITrainingPlanNormalizer`,
//  and shows the resulting read-only `WeeklyTrainingPlanCandidate`.
//
//  Deliberately inert, matching the AI planning contract (PR #74):
//   - no real AI / OpenAI, no networking, no URLSession/URLRequest,
//     no API keys — the only provider is the deterministic mock,
//   - no persistence — the result is a candidate value only; it never
//     creates/saves `Routine`/`Step` and never touches a `ModelContext`.
//     Saving from this screen is intentionally out of scope.
//

import SwiftUI

struct MockAITrainingPlanChatView: View {
    @Environment(\.colorScheme) private var colorScheme

    // The provider is referenced through the protocol so a real one can
    // be swapped in later without touching this view. Today it is always
    // the offline deterministic mock.
    private let provider: AITrainingPlanProviding = MockAITrainingPlanProvider()

    @State private var userMessage: String = ""
    @State private var goal: TrainingGoal = .consistency
    @State private var daysPerWeek: Int = 3
    @State private var candidate: WeeklyTrainingPlanCandidate?
    @State private var isGenerating: Bool = false

    var body: some View {
        ZStack {
            backgroundLayer.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerBlock
                    mockNotice
                    inputCard
                    generateButton
                    if let candidate {
                        summaryCard(candidate)
                        if !candidate.warnings.isEmpty {
                            warningsCard(candidate.warnings)
                        }
                        ForEach(Array(candidate.sessions.enumerated()), id: \.offset) { _, session in
                            sessionCard(session)
                        }
                    }
                    footerNote
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .navigationTitle("AIプラン相談")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AIプラン相談")
                .font(.system(size: 28, weight: .bold))
            Text("入力内容をもとに、ローカルのモックプロバイダーでプラン候補を作成します。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var mockNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("これはモックAI相談です。実際のAI通信は行っていません。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    // MARK: - Input

    private var inputCard: some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("相談内容")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("例: 週3回で胸と肩を中心に鍛えたい", text: $userMessage, axis: .vertical)
                        .lineLimit(3...6)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("目標")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("目標", selection: $goal) {
                        ForEach(Array(TrainingGoal.allCases), id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("週あたりの日数")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Stepper(value: $daysPerWeek, in: 1...6) {
                        Text("週 \(daysPerWeek) 日")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
    }

    // MARK: - Generate

    private var generateButton: some View {
        Button {
            generate()
        } label: {
            HStack(spacing: 8) {
                if isGenerating {
                    ProgressView()
                } else {
                    Image(systemName: "wand.and.stars")
                }
                Text("プラン候補を作成")
                    .font(.subheadline.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isGenerating)
    }

    /// Runs the mock provider then the normalizer. The provider is
    /// `async` only to satisfy the protocol; the mock does no real work
    /// and never throws, but we still handle failure defensively by
    /// normalizing an empty response into a warning candidate.
    private func generate() {
        isGenerating = true
        let request = AITrainingPlanRequest(
            userMessage: userMessage,
            goal: goal,
            daysPerWeek: daysPerWeek
        )
        Task { @MainActor in
            let response: AITrainingPlanResponse
            do {
                response = try await provider.generatePlan(for: request)
            } catch {
                response = AITrainingPlanResponse(
                    warnings: ["プラン候補を作成できませんでした。もう一度お試しください。"]
                )
            }
            candidate = AITrainingPlanNormalizer.normalize(response: response, request: request)
            isGenerating = false
        }
    }

    // MARK: - Summary

    private func summaryCard(_ candidate: WeeklyTrainingPlanCandidate) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text(candidate.title)
                    .font(.headline)
                HStack(spacing: 6) {
                    metaPill(text: candidate.goal.displayName)
                    metaPill(text: "週 \(candidate.daysPerWeek) 日")
                    metaPill(text: "\(candidate.sessions.count) セッション")
                }
                if !candidate.rationale.isEmpty {
                    Text(candidate.rationale)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func warningsCard(_ warnings: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(warnings, id: \.self) { warning in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Session

    private func sessionCard(_ session: TrainingSessionCandidate) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text(session.title)
                    .font(.subheadline.weight(.bold))
                if !session.focusBodyParts.isEmpty {
                    chipRow(session.focusBodyParts.map(\.displayName))
                }
                VStack(spacing: 8) {
                    ForEach(Array(session.exercises.enumerated()), id: \.offset) { _, ex in
                        exerciseRow(ex)
                    }
                }
                if !session.notes.isEmpty {
                    Text(session.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func exerciseRow(_ ex: RoutineStepCandidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ex.exerciseName)
                .font(.subheadline.weight(.semibold))
            if !ex.bodyParts.isEmpty {
                Text(ex.bodyParts.map(\.displayName).joined(separator: " / "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if let setsReps = ex.setsAndRepsText {
                    metricChip(icon: "repeat", text: setsReps)
                }
                if let rest = ex.restText {
                    metricChip(icon: "timer", text: rest)
                }
                if !ex.hasMenuDefaults {
                    metricChip(icon: "questionmark.circle", text: "目安なし")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    // MARK: - Footer

    private var footerNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("この候補はまだ保存されません。")
            Text("実AI・通信・保存はまだ行われません。")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    // MARK: - Reusable building blocks

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }

    private func metaPill(text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            .foregroundStyle(Color.accentColor)
    }

    private func metricChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .foregroundStyle(.secondary)
    }

    private func chipRow(_ items: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    .foregroundStyle(Color.accentColor)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        let colors: [Color] = colorScheme == .dark
            ? [Color(red: 0.05, green: 0.07, blue: 0.12),
               Color(red: 0.07, green: 0.06, blue: 0.13)]
            : [Color(red: 0.93, green: 0.96, blue: 1.00),
               Color(red: 0.99, green: 0.96, blue: 1.00)]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

#Preview {
    NavigationStack {
        MockAITrainingPlanChatView()
    }
}
