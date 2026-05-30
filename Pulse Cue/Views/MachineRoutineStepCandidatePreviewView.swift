//
//  MachineRoutineStepCandidatePreviewView.swift
//  Pulse Cue
//
//  Review-and-save sheet for a `RoutineStepCandidate` built from a
//  machine catalog entry. This is the "review → confirm → save" step of
//  the candidate flow: the candidate stays inert until the user taps
//  「ルーティンとして保存」. On confirm it builds a normal one-step
//  `Routine` via `RoutineFactory` and inserts it into the SwiftData
//  context — the same pure-build-then-insert boundary used by the
//  generated-plan preview. No networking, no AI, no schema change, and
//  the existing generated-plan save path is left untouched.
//

import SwiftUI
import SwiftData

struct MachineRoutineStepCandidatePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext

    let candidate: RoutineStepCandidate

    @State private var routineTitle: String
    @State private var saveState: SaveState = .idle

    private enum SaveState: Equatable {
        case idle
        case saved
        case error(String)
    }

    init(candidate: RoutineStepCandidate) {
        self.candidate = candidate
        _routineTitle = State(initialValue: candidate.exerciseName)
    }

    private var isSaved: Bool { saveState == .saved }

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundLayer.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        headerCard
                        menuCard
                        if let notes = candidate.notes {
                            notesCard(notes)
                        }
                        if isSaved {
                            successCard
                        } else {
                            saveCard
                            if case .error(let message) = saveState {
                                errorCard(message)
                            }
                        }
                        Color.clear.frame(height: 8)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("種目候補")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaved ? "完了" : "閉じる") { dismiss() }
                }
            }
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text(candidate.sourceLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(candidate.exerciseName)
                    .font(.system(size: 22, weight: .bold))
                if !candidate.bodyParts.isEmpty {
                    chipRow(candidate.bodyParts.map(\.displayName))
                }
            }
        }
    }

    // MARK: - Sets / reps / rest (catalog guidance)

    private var menuCard: some View {
        cardSection(title: "セット・回数の目安") {
            VStack(alignment: .leading, spacing: 8) {
                if candidate.hasMenuDefaults {
                    if let setsReps = candidate.setsAndRepsText {
                        menuLine(icon: "repeat", text: setsReps)
                    }
                    if let rest = candidate.restText {
                        menuLine(icon: "timer", text: rest)
                    }
                    Text("※ あくまで目安です。体調や経験に合わせて調整してください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                } else {
                    Text(MachineExerciseTemplate.fallbackMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Notes

    private func notesCard(_ notes: String) -> some View {
        cardSection(title: "メモ") {
            Text(notes)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Save (review → confirm)

    private var saveCard: some View {
        cardSection(title: "ルーティンとして保存") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ルーティン名")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("ルーティン名", text: $routineTitle)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.done)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("保存される内容")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    savedRow(
                        icon: "repeat",
                        text: "\(candidate.resolvedSets)セット × 目標\(candidate.resolvedRepsTarget)レップ"
                    )
                    savedRow(
                        icon: "timer",
                        text: "セット間 \(MachineExerciseTemplate.humanizedDuration(seconds: candidate.resolvedRestSeconds))"
                    )
                    if let notes = candidate.notes {
                        savedRow(icon: "note.text", text: notes)
                    }
                }

                Text("確定するとルーティン一覧に1種目のルーティンが追加されます。保存後はルーティン編集から自由に調整できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    save()
                } label: {
                    Label("ルーティンとして保存", systemImage: "tray.and.arrow.down.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var successCard: some View {
        cardSection(title: "保存しました") {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "「\(savedRoutineName)」をルーティンとして保存しました。",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
                Text("ルーティン一覧から開始したり、内容を編集できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.red.opacity(0.12))
            )
    }

    // MARK: - Save action

    private var savedRoutineName: String {
        let trimmed = routineTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? candidate.exerciseName : trimmed
    }

    /// Builds the routine purely, then inserts it on explicit user
    /// action. SwiftUI's `modelContext` autosaves, matching the existing
    /// generated-plan save path. Guarded against double-saves by the
    /// `isSaved` UI swap.
    private func save() {
        let output = RoutineFactory.makeRoutine(from: candidate, title: routineTitle)
        modelContext.insert(output.routine)
        for step in output.steps {
            modelContext.insert(step)
        }
        saveState = .saved
    }

    // MARK: - Reusable building blocks

    private func savedRow(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cardSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 4)
            card { content() }
        }
    }

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

    private func chipRow(_ items: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    .foregroundStyle(Color.accentColor)
            }
            Spacer(minLength: 0)
        }
    }

    private func menuLine(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            Text(text)
                .font(.subheadline.weight(.semibold))
        }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        let colors: [Color] = colorScheme == .dark
            ? [Color(red: 0.05, green: 0.07, blue: 0.12),
               Color(red: 0.07, green: 0.06, blue: 0.13)]
            : [Color(red: 0.93, green: 0.96, blue: 1.00),
               Color(red: 0.99, green: 0.96, blue: 1.00)]
        return LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

#Preview("With defaults") {
    MachineRoutineStepCandidatePreviewView(
        candidate: RoutineStepCandidate(
            entry: MachineCatalogEntry(
                id: "bench_press",
                displayName: "ベンチプレス",
                bodyParts: [.chest, .arms],
                secondaryMuscles: [.shoulders],
                setupNotes: "ベンチに仰向けになり、肩甲骨を寄せて胸を張ります。",
                defaultSets: 3,
                defaultReps: 8...12,
                defaultRestSeconds: 90
            )
        )
    )
    .modelContainer(for: [Routine.self, Step.self], inMemory: true)
}

#Preview("No defaults") {
    MachineRoutineStepCandidatePreviewView(
        candidate: RoutineStepCandidate(
            entry: MachineCatalogEntry(
                id: "pec_deck",
                displayName: "ペックデック",
                bodyParts: [.chest]
            )
        )
    )
    .modelContainer(for: [Routine.self, Step.self], inMemory: true)
}
