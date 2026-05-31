//
//  WeeklyTrainingPlanCandidateReviewView.swift
//  Pulse Cue
//
//  Local UI for generating, reviewing, and (on explicit confirmation)
//  saving a rule-based weekly training plan candidate (see
//  `RuleBasedWeeklyPlanGenerator`, PR #69). Mirrors the machine-catalog
//  candidate flow's boundary:
//
//   - no networking, no AI, no external data,
//   - the generated plan stays INERT — nothing is persisted on open,
//     input change, generation, viewing, or back-out,
//   - only an explicit tap on「週次プランを保存」builds normal `Routine` /
//     `Step` records (one routine per session) via `RoutineFactory` and
//     inserts them into the SwiftData context. No schema change.
//
//  The generator and the factory are both pure; this view only holds the
//  request inputs and the generated candidate in `@State` and performs
//  the insert on confirmation.
//

import SwiftUI
import SwiftData

struct WeeklyTrainingPlanCandidateReviewView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext

    // Request inputs (mirror TrainingPlanGenerationRequest's main fields).
    @State private var goal: TrainingGoal = .consistency
    @State private var experience: ExperienceLevel = .beginner
    @State private var split: TrainingSplit = .fullBody
    @State private var daysPerWeek: Int = 3
    @State private var selectedBodyParts: Set<BodyPart> = []

    @State private var candidate: WeeklyTrainingPlanCandidate?
    @State private var saveState: SaveState = .idle

    /// Tracks the save lifecycle so the candidate stays inert until the
    /// user confirms, and so regenerating clears any prior result.
    private enum SaveState: Equatable {
        case idle
        case saved(Int)
    }

    // Body-part filter order matches the catalog screen (胸/背中/肩/腕/脚/体幹/有酸素).
    private let bodyPartChoices: [BodyPart] = [
        .chest, .back, .shoulders, .arms, .legs, .core, .fullBody
    ]

    private var request: TrainingPlanGenerationRequest {
        TrainingPlanGenerationRequest(
            goal: goal,
            daysPerWeek: daysPerWeek,
            targetBodyParts: bodyPartChoices.filter { selectedBodyParts.contains($0) },
            experienceLevel: experience,
            preferredSplit: split
        )
    }

    /// Number of routines a save would create — one per non-empty session.
    /// Derived purely from the candidate; it does NOT build any
    /// `Routine`/`Step` before the user explicitly saves.
    private var savableSessionCount: Int {
        candidate?.savableSessionCount ?? 0
    }

    private var isSaved: Bool {
        if case .saved = saveState { return true }
        return false
    }

    var body: some View {
        ZStack {
            backgroundLayer.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerBlock
                    controlsCard
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
        .navigationTitle("プラン候補")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("週次プラン候補")
                .font(.system(size: 28, weight: .bold))
            Text("ローカルのマシンカタログをもとに、ルールベースで週次プラン候補を作成します。外部APIは使用していません。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Controls

    private var controlsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
                pickerRow(title: "目標", selection: $goal)
                pickerRow(title: "経験レベル", selection: $experience)
                pickerRow(title: "分割法", selection: $split)

                VStack(alignment: .leading, spacing: 6) {
                    Text("週あたりの日数")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Stepper(value: $daysPerWeek, in: 1...6) {
                        Text("週 \(daysPerWeek) 日")
                            .font(.subheadline.weight(.semibold))
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("対象部位（任意）")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    bodyPartChips
                    Text("未選択の場合はバランス重視の全身プランになります。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func pickerRow<T>(title: String, selection: Binding<T>) -> some View
    where T: CaseIterable & Hashable & RawRepresentable, T.AllCases: RandomAccessCollection {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(Array(T.allCases), id: \.self) { option in
                    Text(displayName(of: option)).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    /// Pulls the localized label off our request enums without forcing a
    /// shared protocol on them.
    private func displayName<T: Hashable>(of option: T) -> String {
        switch option {
        case let g as TrainingGoal: return g.displayName
        case let e as ExperienceLevel: return e.displayName
        case let s as TrainingSplit: return s.displayName
        default: return "\(option)"
        }
    }

    private var bodyPartChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(bodyPartChoices, id: \.self) { part in
                    chip(for: part)
                }
                if !selectedBodyParts.isEmpty {
                    Button {
                        selectedBodyParts.removeAll()
                    } label: {
                        Text("クリア")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func chip(for part: BodyPart) -> some View {
        let isOn = selectedBodyParts.contains(part)
        return Button {
            if isOn { selectedBodyParts.remove(part) } else { selectedBodyParts.insert(part) }
        } label: {
            Text(chipLabel(for: part))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(isOn ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                )
                .foregroundStyle(isOn ? Color.accentColor : .primary)
                .overlay(
                    Capsule().strokeBorder(
                        isOn ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func chipLabel(for part: BodyPart) -> String {
        part == .fullBody ? "有酸素" : part.displayName
    }

    // MARK: - Generate

    private var generateButton: some View {
        Button {
            candidate = RuleBasedWeeklyPlanGenerator.generate(request: request)
            // Regenerating clears any prior save so the new candidate is
            // inert again until the user confirms.
            saveState = .idle
        } label: {
            Label("候補を生成", systemImage: "wand.and.stars")
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
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
                if session.exercises.isEmpty {
                    Text("このセッションに合うマシンが見つかりませんでした。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(Array(session.exercises.enumerated()), id: \.offset) { _, ex in
                            exerciseRow(ex)
                        }
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
                Text("生成された候補は保存前に確認してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if count == 0 {
                    Text("保存できるセッションがありません。対象部位や日数を変えて再生成してください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    save(candidate)
                } label: {
                    Label("週次プランを保存", systemImage: "tray.and.arrow.down.fill")
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
                Label("週次プランを保存しました", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                Text("\(count) 件のルーティンを追加しました。ルーティン一覧から開始したり、内容を編集できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Builds routines purely via `RoutineFactory`, then inserts them on
    /// this explicit user action only. SwiftUI's `modelContext` autosaves,
    /// matching the machine-candidate and generated-plan save paths.
    private func save(_ candidate: WeeklyTrainingPlanCandidate) {
        let outputs = RoutineFactory.makeRoutines(from: candidate)
        guard !outputs.isEmpty else { return }
        for output in outputs {
            modelContext.insert(output.routine)
            for step in output.steps {
                modelContext.insert(step)
            }
        }
        saveState = .saved(outputs.count)
    }

    // MARK: - Footer

    private var footerNote: some View {
        Text("保存すると各セッションが通常のルーティンとして追加されます。マシンカタログにセット数等が未登録の種目は目安値で保存されます。")
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
        WeeklyTrainingPlanCandidateReviewView()
    }
    .modelContainer(for: [Routine.self, Step.self], inMemory: true)
}
