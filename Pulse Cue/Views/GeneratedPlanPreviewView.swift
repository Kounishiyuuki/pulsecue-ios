//
//  GeneratedPlanPreviewView.swift
//  Pulse Cue
//
//  Focused "workout preview" screen. Mirrors the user-supplied design
//  direction: dark surface for momentary review, warning banner,
//  compact 2×2 stat grid, exercise cards with a colored stripe + body
//  parts line + cue + three metric blocks, and a sticky CTA stack.
//
//  Dark scheme is scoped to this view only via
//  `.preferredColorScheme(.dark)`; popping back returns the rest of
//  the My Gym flow to the user's system scheme.
//
//  No logic changes: `WorkoutPlanGenerator` and `RoutineFactory` are
//  untouched. The view-level `estimatedMinutes` helper is a pure
//  derivation of fields already on `GeneratedPlan`.
//

import SwiftUI
import SwiftData

struct GeneratedPlanPreviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel: GeneratedPlanViewModel
    @State private var showMachineReview = false

    init(gym: Gym, bodyPart: BodyPart) {
        _viewModel = StateObject(wrappedValue: GeneratedPlanViewModel(gym: gym, bodyPart: bodyPart))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MyGymStyle.backgroundLayer(for: .dark)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    headerBlock
                    if let plan = viewModel.plan {
                        if !plan.warnings.isEmpty {
                            warningBanner(plan.warnings)
                        }
                        statGrid(plan: plan)
                        if !plan.isEmpty {
                            exercisesSection(plan: plan)
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
                    Color.clear.frame(height: 220)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }

            ctaStack
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
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
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showMachineReview) {
            NavigationStack {
                ManualMachineSelectionView(gym: viewModel.gym)
            }
        }
        .task { viewModel.configure(modelContext: modelContext) }
    }

    // MARK: - Header

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(viewModel.bodyPart.displayName) — \(viewModel.gym.name)")
                .font(.largeTitle.weight(.bold))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.white)
            Text("ワークアウトプランのプレビュー")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: - Warning banner

    private func warningBanner(_ warnings: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(warnings, id: \.self) { warning in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.orange.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
        )
    }

    // MARK: - Stat grid

    private func statGrid(plan: GeneratedPlan) -> some View {
        let columns = [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
        ]
        return LazyVGrid(columns: columns, spacing: 10) {
            statTile(label: "ジム", value: plan.gymName, systemImage: "building.2.fill")
            statTile(label: "ターゲット", value: plan.bodyPart.displayName, systemImage: "target")
            statTile(label: "推定時間", value: "\(estimatedMinutes(plan)) 分", systemImage: "clock.fill")
            statTile(label: "種目数", value: "\(plan.exercises.count) 種目", systemImage: "list.bullet.rectangle.fill")
        }
    }

    private func statTile(label: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption2)
                Text(label)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white.opacity(0.55))
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Exercises

    private func exercisesSection(plan: GeneratedPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(MyGymStyle.accentGradient)
                    .frame(width: 4, height: 16)
                    .cornerRadius(2)
                Text("メニュー")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            VStack(spacing: 12) {
                ForEach(Array(plan.exercises.enumerated()), id: \.offset) { index, exercise in
                    exerciseCard(exercise, accentHue: hue(forIndex: index))
                }
            }
        }
    }

    private func exerciseCard(_ exercise: GeneratedExercise, accentHue: Color) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(accentHue)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(exercise.exerciseName)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("マシン")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                    Spacer()
                }
                if let body = bodyPartLine(for: exercise) {
                    Text(body)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
                if !exercise.cue.isEmpty {
                    Text("“\(exercise.cue)”")
                        .font(.caption)
                        .italic()
                        .foregroundStyle(.white.opacity(0.7))
                }
                HStack(spacing: 8) {
                    metricBlock(value: "\(exercise.sets)", label: "セット")
                    metricBlock(value: "\(exercise.reps)", label: "レップ")
                    metricBlock(value: "\(exercise.restSeconds)", label: "休憩(秒)")
                }
                .padding(.top, 2)
            }
            .padding(14)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    private func metricBlock(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.weight(.heavy))
                .foregroundStyle(.white)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    // MARK: - Loading / error / success

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(.white)
            Text("メニューを組み立てています…")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private func errorCard(message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.red.opacity(0.15))
            )
    }

    private var successCard: some View {
        Label(
            "ルーティンとして保存しました。ルーティン一覧から開始できます。",
            systemImage: "checkmark.circle.fill"
        )
        .foregroundStyle(.green)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.green.opacity(0.15))
        )
    }

    // MARK: - Sticky CTA stack

    @ViewBuilder
    private var ctaStack: some View {
        if isSaved {
            Button {
                dismiss()
            } label: {
                Label("完了", systemImage: "checkmark")
            }
            .buttonStyle(MyGymPrimaryButtonStyle())
            .background(stickyBackground)
        } else {
            VStack(spacing: 8) {
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
                .buttonStyle(MyGymPrimaryButtonStyle(
                    isEnabled: canSave
                ))
                .disabled(!canSave)

                HStack(spacing: 8) {
                    secondaryButton(label: "部位を変更", systemImage: "arrow.left.arrow.right") {
                        dismiss()
                    }
                    secondaryButton(label: "マシン選択を見直す", systemImage: "pencil") {
                        showMachineReview = true
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
            )
        }
    }

    private func secondaryButton(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    private var stickyBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.black.opacity(0.55))
            .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
            .padding(-6)
    }

    // MARK: - Helpers

    private var canSave: Bool {
        guard let plan = viewModel.plan, !plan.isEmpty else { return false }
        return viewModel.state != .saving
    }

    private var isSaved: Bool {
        if case .saved = viewModel.state { return true }
        return false
    }

    /// Pure view-level estimate. Assumes ~4 seconds per rep + the
    /// prescribed rest after each set. Rounded up to whole minutes.
    private func estimatedMinutes(_ plan: GeneratedPlan) -> Int {
        let totalSeconds = plan.exercises.reduce(0) { acc, e in
            acc + e.sets * (e.reps * 4 + e.restSeconds)
        }
        return max(1, Int(ceil(Double(totalSeconds) / 60.0)))
    }

    /// Body-part list rendered under the exercise title. Uses the
    /// same `MachineCatalog` already exposed to the manual selection
    /// view — no schema or model change.
    private func bodyPartLine(for exercise: GeneratedExercise) -> String? {
        guard let entry = MachineCatalog.entry(for: exercise.machineId) else { return nil }
        let parts = BodyPart.allCases
            .filter { entry.bodyParts.contains($0) }
            .map(\.displayName)
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    private func hue(forIndex index: Int) -> Color {
        let palette: [Color] = [
            Color(red: 0.49, green: 0.62, blue: 0.95),
            Color(red: 0.66, green: 0.45, blue: 0.95),
            Color(red: 0.95, green: 0.55, blue: 0.62),
            Color(red: 0.45, green: 0.85, blue: 0.62),
            Color(red: 0.97, green: 0.72, blue: 0.38),
            Color(red: 0.36, green: 0.78, blue: 0.86),
        ]
        return palette[index % palette.count]
    }
}
