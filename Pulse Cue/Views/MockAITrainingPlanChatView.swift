//
//  MockAITrainingPlanChatView.swift
//  Pulse Cue
//
//  Local, mock-only "AI plan consultation" screen. The user types a
//  free-form training request; the screen runs the offline
//  `MockAITrainingPlanProvider` through the `AITrainingPlanProviding`
//  boundary, normalizes the raw response with `AITrainingPlanNormalizer`,
//  and shows the resulting `WeeklyTrainingPlanCandidate`. The candidate
//  can then be saved as normal `Routine` data — but only on an explicit
//  tap, reusing the same boundary as the weekly-plan review screen.
//
//  Deliberately constrained, matching the AI planning contract (PR #74):
//   - no real AI / OpenAI, no networking, no URLSession/URLRequest,
//     no API keys — the only provider is the deterministic mock,
//   - the candidate stays inert until the user confirms: nothing is
//     persisted on open, typing, generate, or display,
//   - saving builds normal records via `RoutineFactory` and inserts them
//     into the SwiftData context. No schema change.
//

import SwiftUI
import SwiftData

struct MockAITrainingPlanChatView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext

    // The provider is referenced through the protocol so a real one can
    // be swapped in later without touching this view. It is resolved
    // through `AITrainingPlanProviderFactory`, whose default is the offline
    // deterministic mock — so the screen stays mock-only unless a caller
    // explicitly injects an endpoint-backed provider (no production wiring).
    private let provider: AITrainingPlanProviding

    init(provider: AITrainingPlanProviding = AITrainingPlanProviderFactory.makeProvider()) {
        self.provider = provider
    }

    @State private var userMessage: String = ""
    @State private var goal: TrainingGoal = .consistency
    @State private var daysPerWeek: Int = 3
    @State private var candidate: WeeklyTrainingPlanCandidate?
    @State private var isGenerating: Bool = false
    @State private var saveState: WeeklyPlanSaveState = .idle

    /// Number of routines a save would create — one per non-empty session.
    /// Derived purely from the candidate; builds no `Routine`/`Step`.
    private var savableSessionCount: Int {
        candidate?.savableSessionCount ?? 0
    }

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
                        saveSection(candidate)
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
            // A freshly generated candidate is inert again until the user
            // explicitly confirms the save.
            saveState = .idle
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

    // MARK: - Save (review → confirm → save)

    @ViewBuilder
    private func saveSection(_ candidate: WeeklyTrainingPlanCandidate) -> some View {
        if case .saved(let count) = saveState {
            successCard(count: count)
        } else {
            saveCard(candidate)
        }
    }

    private func saveCard(_ candidate: WeeklyTrainingPlanCandidate) -> some View {
        let count = savableSessionCount
        return card {
            VStack(alignment: .leading, spacing: 12) {
                Text("ルーティンとして保存")
                    .font(.headline)
                Text("保存すると、各セッションが通常のルーティンとして追加されます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if count == 0 {
                    Text("保存できるセッションがありません。相談内容や日数を変えて再生成してください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    save(candidate)
                } label: {
                    Label("この候補を保存", systemImage: "tray.and.arrow.down.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(count == 0)
            }
        }
    }

    private func successCard(count: Int) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Label("保存しました", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                Text("\(count) 件のルーティンを追加しました")
                    .font(.headline)
                Text("AIプラン相談で作成した候補を通常のルーティンとして保存しました。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("新しい相談内容で再生成すると、別の候補として保存できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Builds routines purely via `RoutineFactory`, then inserts them on
    /// this explicit user action only — the sole persistence path in this
    /// screen. Mirrors `WeeklyTrainingPlanCandidateReviewView.save(_:)`.
    private func save(_ candidate: WeeklyTrainingPlanCandidate) {
        let outputs = RoutineFactory.makeRoutines(from: candidate)
        guard !outputs.isEmpty else { return }
        for output in outputs {
            modelContext.insert(output.routine)
            for step in output.steps {
                modelContext.insert(step)
            }
        }
        saveState = .saved(routineCount: outputs.count)
    }

    // MARK: - Footer

    private var footerNote: some View {
        Text("保存すると各セッションが通常のルーティンとして追加されます。実際のAI通信は行わず、ローカルのモックで動作します。")
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
    .modelContainer(for: [Routine.self, Step.self], inMemory: true)
}
