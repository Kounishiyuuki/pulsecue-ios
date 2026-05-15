//
//  GeneratedPlanPreviewView.swift
//  Pulse Cue
//
//  Preview of a generated workout plan. Surfaces any generator
//  warnings as a banner at the top, a compact stat row (ジム /
//  ターゲット / 種目数), then one card per exercise, and a primary
//  「ルーティンとして保存」CTA at the bottom that writes the plan
//  into the existing Routine / Step store via `RoutineFactory`.
//

import SwiftUI
import SwiftData

struct GeneratedPlanPreviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel: GeneratedPlanViewModel

    init(gym: Gym, bodyPart: BodyPart) {
        _viewModel = StateObject(wrappedValue: GeneratedPlanViewModel(gym: gym, bodyPart: bodyPart))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MyGymStyle.backgroundLayer(for: colorScheme)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let plan = viewModel.plan {
                        if !plan.warnings.isEmpty {
                            warningBanner(plan.warnings)
                        }
                        statRow(plan: plan)
                        if !plan.isEmpty {
                            exercisesCard(plan: plan)
                        }
                    } else {
                        loadingCard
                    }

                    if case .error(let message) = viewModel.state {
                        errorCard(message: message)
                    }
                    if case .saved = viewModel.state {
                        successCard
                    }
                    Color.clear.frame(height: 96)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }

            saveBar
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .navigationTitle("\(viewModel.bodyPart.displayName)の日")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isSaved {
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

    // MARK: - Sections

    private func warningBanner(_ warnings: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(warnings, id: \.self) { warning in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.30), lineWidth: 1)
        )
    }

    private func statRow(plan: GeneratedPlan) -> some View {
        HStack(spacing: 10) {
            statTile(label: "ジム", value: plan.gymName, systemImage: "building.2.fill")
            statTile(label: "ターゲット", value: plan.bodyPart.displayName, systemImage: "target")
            statTile(label: "種目数", value: "\(plan.exercises.count)", systemImage: "list.bullet.rectangle")
        }
    }

    private func statTile(label: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
                Text(label)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .myGymCard(padding: 12)
    }

    private func exercisesCard(plan: GeneratedPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MyGymStyle.sectionHeader(icon: "list.bullet.rectangle", title: "メニュー")
            ForEach(Array(plan.exercises.enumerated()), id: \.offset) { index, exercise in
                if index > 0 { Divider().opacity(0.35) }
                exerciseRow(exercise, index: index + 1)
            }
        }
        .myGymCard()
    }

    private func exerciseRow(_ exercise: GeneratedExercise, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(index).")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(MyGymStyle.accentGradient)
                Text(exercise.exerciseName)
                    .font(.body.weight(.semibold))
                Spacer()
            }
            HStack(spacing: 8) {
                metricChip(label: "セット", value: "\(exercise.sets)")
                metricChip(label: "回数", value: "\(exercise.reps)")
                metricChip(label: "休憩", value: "\(exercise.restSeconds)秒")
            }
            if !exercise.cue.isEmpty {
                Text(exercise.cue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func metricChip(label: String, value: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
    }

    private var loadingCard: some View {
        HStack {
            ProgressView()
            Text("メニューを組み立てています…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .myGymCard()
    }

    private func errorCard(message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .myGymCard()
    }

    private var successCard: some View {
        Label(
            "ルーティンとして保存しました。ルーティン一覧から開始できます。",
            systemImage: "checkmark.circle.fill"
        )
        .foregroundStyle(.green)
        .myGymCard()
    }

    // MARK: - Sticky CTA

    @ViewBuilder
    private var saveBar: some View {
        if isSaved {
            Button {
                dismiss()
            } label: {
                Label("完了", systemImage: "checkmark")
            }
            .buttonStyle(MyGymPrimaryButtonStyle())
            .background(stickyBackground)
        } else if let plan = viewModel.plan, !plan.isEmpty {
            Button {
                viewModel.saveAsRoutine()
            } label: {
                if viewModel.state == .saving {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("ルーティンとして保存", systemImage: "tray.and.arrow.down.fill")
                }
            }
            .buttonStyle(MyGymPrimaryButtonStyle())
            .disabled(viewModel.state == .saving)
            .background(stickyBackground)
        }
    }

    private var stickyBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.ultraThinMaterial)
            .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
            .padding(-6)
    }

    private var isSaved: Bool {
        if case .saved = viewModel.state { return true }
        return false
    }
}
