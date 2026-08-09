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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // Provided app-wide (above the TabView); needed only by the Quick Plan
    // "この内容で開始" action, which reuses the shared Runner-start path.
    @EnvironmentObject private var runnerViewModel: RunnerViewModel
    @EnvironmentObject private var settings: SettingsStore

    @StateObject private var viewModel: GeneratedPlanViewModel
    /// Stateless UserDefaults accessor, same as `WorkoutView`.
    @State private var restStore = RoutineRestPreferenceStore()
    @State private var showMachineReview = false
    /// Non-nil while the text Form Guide sheet is presented. Purely local
    /// UI state — opening it reads static content and persists nothing.
    @State private var guideExerciseId: ExerciseID?
    /// Non-nil while the exercise-replacement sheet is presented.
    @State private var replacementTarget: ReplacementTarget?

    init(gym: Gym, bodyPart: BodyPart) {
        _viewModel = StateObject(wrappedValue: GeneratedPlanViewModel(gym: gym, bodyPart: bodyPart))
    }

    /// Quick Plan entry: builds the same preview from a multi-part request
    /// (body parts + duration + intensity). Reuses the whole screen.
    init(gym: Gym, request: QuickPlanRequest) {
        _viewModel = StateObject(wrappedValue: GeneratedPlanViewModel(gym: gym, request: request))
    }

    var body: some View {
        ZStack {
            PulseAtmosphericBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let plan = viewModel.plan {
                        heroSummary(plan)
                        if !plan.warnings.isEmpty {
                            warningBanner(plan.warnings)
                        }
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
                    if dynamicTypeSize.isAccessibilitySize {
                        ctaStack
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }

        }
        .safeAreaInset(edge: .bottom) {
            if !dynamicTypeSize.isAccessibilitySize {
                ctaStack
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
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
        .sheet(isPresented: $showMachineReview) {
            NavigationStack {
                ManualMachineSelectionView(gym: viewModel.gym)
            }
        }
        .sheet(item: $guideExerciseId) { id in
            ExerciseGuideView(exerciseId: id)
        }
        .sheet(item: $replacementTarget) { target in
            ExerciseReplacementSheet(
                originalName: target.name,
                originalMachineId: target.machineId,
                candidates: target.candidates,
                onSelect: { candidate in
                    viewModel.replaceExercise(at: target.index, with: candidate)
                }
            )
        }
        .task { viewModel.configure(modelContext: modelContext) }
    }

    // MARK: - Header

    private func heroSummary(_ plan: GeneratedPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("これから行うメニュー")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
            Text("\(plan.bodyParts.map(\.displayName).joined(separator: "・")) — \(viewModel.gym.name)")
                .font(.title.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits {
                HStack(spacing: 16) {
                    summaryItem("\(plan.exercises.count) 種目", icon: "list.number")
                    summaryItem("\(estimatedMinutes(plan)) 分", icon: "clock")
                }
                VStack(alignment: .leading, spacing: 8) {
                    summaryItem("\(plan.exercises.count) 種目", icon: "list.number")
                    summaryItem("\(estimatedMinutes(plan)) 分", icon: "clock")
                }
            }
        }
        .pulseGlass(level: .hero, cornerRadius: AppTheme.heroRadius, padding: 20)
    }

    private func summaryItem(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
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
                        .foregroundStyle(.primary)
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
                    .foregroundStyle(.primary)
            }
            VStack(spacing: 12) {
                ForEach(Array(plan.exercises.enumerated()), id: \.offset) { index, exercise in
                    exerciseCard(exercise, index: index, number: index + 1)
                }
            }
        }
    }

    private func exerciseCard(_ exercise: GeneratedExercise, index: Int, number: Int) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(AppTheme.accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(AppTheme.accentSoft))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(exercise.exerciseName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("マシン")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(AppTheme.accentSoft))
                    Spacer()
                }
                if let body = bodyPartLine(for: exercise) {
                    Text(body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !exercise.cue.isEmpty {
                    Text("“\(exercise.cue)”")
                        .font(.caption)
                        .italic()
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    metricBlock(value: "\(exercise.sets)", label: "セット")
                    metricBlock(value: "\(exercise.reps)", label: "レップ")
                    metricBlock(value: "\(exercise.restSeconds)", label: "休憩(秒)")
                }
                .padding(.top, 2)

                if let guideId = exercise.exerciseId, FormGuideLibrary.hasGuide(for: guideId) {
                    formGuideButton(exerciseName: exercise.exerciseName, exerciseId: guideId)
                        .padding(.top, 2)
                }

                changeExerciseButton(exercise, index: index)
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .background(PulseGlassPlate(level: .subtle, cornerRadius: 20))
    }

    /// Opens the shared replacement sheet for this exercise. Candidates are
    /// ranked on demand from the gym's available equipment, excluding the
    /// other exercises already in the plan.
    private func changeExerciseButton(_ exercise: GeneratedExercise, index: Int) -> some View {
        Button {
            replacementTarget = ReplacementTarget(
                index: index,
                name: exercise.exerciseName,
                machineId: exercise.machineId,
                candidates: viewModel.replacementCandidates(forExerciseAt: index)
            )
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("種目を変更")
                Spacer(minLength: 0)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.accent)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.accentSoft)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(exercise.exerciseName) を別の種目に変更")
    }

    /// Opens the text Form Guide for a supported standard exercise. Custom
    /// fallback exercises (`exerciseId == nil`) never reach here, so the
    /// action can never show a misleading guide. Tapping persists nothing.
    private func formGuideButton(exerciseName: String, exerciseId: ExerciseID) -> some View {
        Button {
            guideExerciseId = exerciseId
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "figure.strengthtraining.traditional")
                Text("フォームを見る")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.accent)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.accentSoft)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(exerciseName) のフォームを見る")
    }

    private func metricBlock(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Loading / error / success

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(AppTheme.accent)
            Text("メニューを組み立てています…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
        .background(
            PulseGlassPlate(level: .subtle, cornerRadius: 14)
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
                // Quick Plan leads with "この内容で開始" (start now, reusing the
                // shared Runner path) and keeps save as a secondary action.
                // The original single-part flow keeps save as its primary.
                if isQuickPlan {
                    startButton
                    saveButton(isPrimary: false)
                } else {
                    saveButton(isPrimary: true)
                }

                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 8) {
                            changeBodyPartButton
                            reviewMachinesButton
                        }
                    } else {
                        HStack(spacing: 8) {
                            changeBodyPartButton
                            reviewMachinesButton
                        }
                    }
                }
            }
            .padding(10)
            .background(
                PulseGlassPlate(
                    level: .functional,
                    cornerRadius: 18
                )
            )
        }
    }

    /// The plan was built from a Quick Plan request (multi-part + duration +
    /// intensity), so it offers "この内容で開始"; the single-part flow does not.
    private var isQuickPlan: Bool { viewModel.request != nil }

    private var startButton: some View {
        Button {
            // Materialize once (shared with save) and start through the same
            // path the routine list uses; the Runner cover then presents
            // itself from the app root via `RunnerViewModel.isRunning`.
            viewModel.startWorkout(
                restStore: restStore,
                appDefaultRestSeconds: settings.defaultRestSeconds,
                runner: runnerViewModel
            )
        } label: {
            Label("この内容で開始", systemImage: "play.fill")
        }
        .buttonStyle(MyGymPrimaryButtonStyle(isEnabled: canStart))
        .disabled(!canStart)
    }

    @ViewBuilder
    private func saveButton(isPrimary: Bool) -> some View {
        let button = Button {
            viewModel.saveAsRoutine()
        } label: {
            if viewModel.state == .saving {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                Label(isPrimary ? "ルーティンとして保存" : "保存", systemImage: "tray.and.arrow.down.fill")
                    .frame(maxWidth: .infinity)
            }
        }
        .disabled(!canSave)

        if isPrimary {
            button.buttonStyle(MyGymPrimaryButtonStyle(isEnabled: canSave))
        } else {
            button
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(AppTheme.accent)
        }
    }

    private var changeBodyPartButton: some View {
        secondaryButton(label: "部位を変更", systemImage: "arrow.left.arrow.right") {
            dismiss()
        }
    }

    private var reviewMachinesButton: some View {
        secondaryButton(label: "マシン選択を見直す", systemImage: "pencil") {
            showMachineReview = true
        }
    }

    private func secondaryButton(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.accentSoft)
            )
        }
        .buttonStyle(.plain)
    }

    private var stickyBackground: some View {
        PulseGlassPlate(level: .functional, cornerRadius: 16)
            .padding(-6)
    }

    // MARK: - Helpers

    private var canSave: Bool {
        guard let plan = viewModel.plan, !plan.isEmpty else { return false }
        return viewModel.state != .saving
    }

    /// Same gate as `canSave`: a non-empty, not-currently-saving plan.
    private var canStart: Bool { canSave }

    private var isSaved: Bool {
        if case .saved = viewModel.state { return true }
        return false
    }

    /// Shared with the routine cards via `WorkoutDurationEstimator`, so the
    /// same prescription never shows two different times.
    private func estimatedMinutes(_ plan: GeneratedPlan) -> Int {
        WorkoutDurationEstimator.minutes(forPlan: plan.exercises)
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

/// Identifies which exercise the replacement sheet is acting on, carrying the
/// candidates ranked when the sheet was opened.
private struct ReplacementTarget: Identifiable {
    let id = UUID()
    let index: Int
    let name: String
    let machineId: String
    let candidates: [GeneratedExercise]
}
