//
//  GeneratedPlanPreviewView.swift
//  Pulse Cue
//
//  Read-only preview of a generated workout plan. Surfaces any
//  warnings from the generator (empty machines, not enough machines
//  for the chosen body part) and offers a single「ルーティンとして
//  保存」CTA that writes the plan into the existing Routine / Step
//  store. After save, the user can launch the new routine from the
//  standard Routines list / Runner entry point — no special UI here.
//

import SwiftUI
import SwiftData

struct GeneratedPlanPreviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel: GeneratedPlanViewModel

    init(gym: Gym, bodyPart: BodyPart) {
        _viewModel = StateObject(wrappedValue: GeneratedPlanViewModel(gym: gym, bodyPart: bodyPart))
    }

    var body: some View {
        List {
            if let plan = viewModel.plan {
                if !plan.warnings.isEmpty {
                    warningsSection(warnings: plan.warnings)
                }
                if !plan.isEmpty {
                    exercisesSection(plan: plan)
                    saveSection
                }
            }
            if case .error(let message) = viewModel.state {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            if case .saved = viewModel.state {
                Section {
                    Label("ルーティンとして保存しました。ルーティン一覧から開始できます。", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle("\(viewModel.bodyPart.displayName)の日")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .saved = viewModel.state {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") { dismiss() }
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.regenerate()
                    } label: {
                        Label("再生成", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .task { viewModel.configure(modelContext: modelContext) }
    }

    private func warningsSection(warnings: [String]) -> some View {
        Section("メモ") {
            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "info.circle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func exercisesSection(plan: GeneratedPlan) -> some View {
        Section("種目") {
            ForEach(Array(plan.exercises.enumerated()), id: \.offset) { _, exercise in
                exerciseRow(exercise)
            }
        }
    }

    private func exerciseRow(_ exercise: GeneratedExercise) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(exercise.exerciseName)
                .font(.body.weight(.semibold))
            Text("\(exercise.sets) セット × \(exercise.reps) 回 / 休憩 \(exercise.restSeconds) 秒")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !exercise.cue.isEmpty {
                Text(exercise.cue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var saveSection: some View {
        Section {
            Button {
                viewModel.saveAsRoutine()
            } label: {
                if viewModel.state == .saving {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("ルーティンとして保存", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(viewModel.state == .saving || isSaved)
            .buttonStyle(.borderedProminent)
        }
    }

    private var isSaved: Bool {
        if case .saved = viewModel.state { return true }
        return false
    }
}
