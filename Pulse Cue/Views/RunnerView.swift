//
//  RunnerView.swift
//  Pulse Cue
//
//  Created by Codex.
//
//  Premium liquid-glass Runner. Layout (top → bottom):
//    1. Brand header: PulseCue mark / centered title / bell.
//    2. Status chips: 今 (phase) / 残り (sets remaining in step) /
//       次 (next step title). The active phase chip is filled with
//       the accent gradient.
//    3. Rest timer card: a large circular gauge with a monospaced,
//       count-down digit transition. Becomes visually dominant while
//       in `.rest` and shows `--:--` otherwise.
//    4. 現在のセット / 目標 card.
//    5. NEXT UP card.
//    6. While running, a "セッション終了" tertiary button. Otherwise a
//       big "ルーティンを開始" CTA replaces the action bar.
//    7. Floating glass-capsule action bar (during running):
//       [戻る] [+10s] [完了] [スキップ]. Complete renames to
//       "休憩終了" while in `.rest`. +10s is disabled outside rest.
//
//  All RunnerViewModel public actions / state are unchanged. The view
//  only re-binds them. The "画面を常時点灯" toggle moved to Settings
//  (already present there) to keep the gym screen uncluttered.
//

import SwiftUI

struct RunnerView: View {
    @EnvironmentObject var runnerViewModel: RunnerViewModel
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var showRoutinePicker = false
    @State private var showEndAlert = false
    /// Non-nil while the Form Guide sheet is shown for the current step.
    /// Resolved ONLY from the persisted `Step.exerciseId` (never from title
    /// or equipment). Presenting it is observational — no workout state,
    /// timer, set/rep progress, or StepResult is changed.
    @State private var guideExerciseId: ExerciseID?

    var body: some View {
        ZStack {
            backgroundLayer.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        Color.clear
                            .frame(height: 0)
                            .id("runner-top")
                        statusChips
                        restTimerCard
                        currentSetCard
                        formGuideButton
                        nextUpCard
                        if runnerViewModel.isRunning {
                            endSessionButton
                        } else {
                            startRoutineButton
                        }
                        Color.clear.frame(height: 8)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                }
                .onChange(of: runnerViewModel.phase) { _, _ in
                    proxy.scrollTo("runner-top", anchor: .top)
                }
            }
        }
        .navigationTitle(runnerViewModel.currentStep?.title ?? "ワークアウト")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .bottom) {
            if runnerViewModel.isRunning {
                actionBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .sheet(isPresented: $showRoutinePicker) {
            RoutinePickerSheet(onSelect: { runnerViewModel.start(routine: $0) })
        }
        .sheet(item: $guideExerciseId) { id in
            ExerciseGuideView(exerciseId: id)
        }
        .alert("セッションを終了しますか？", isPresented: $showEndAlert) {
            Button("終了", role: .destructive) {
                runnerViewModel.endSessionEarly()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このセッションは中断として保存されます。")
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                runnerViewModel.appDidBecomeActive()
            } else if newPhase == .background {
                runnerViewModel.appDidEnterBackground()
            }
        }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        PulseAtmosphericBackground(focused: true)
    }

    // MARK: - Brand header

    private var brandHeader: some View {
        HStack {
            ZStack {
                Circle().fill(AppTheme.accentFilled).frame(width: 32, height: 32)
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Spacer()
            Text("PulseCue")
                .font(.headline.weight(.semibold))
            Spacer()
            Image(systemName: "bell")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
        }
        .padding(.vertical, 4)
        .accessibilityHidden(true)
    }

    // MARK: - Status chips

    private var statusChips: some View {
        HStack(spacing: 10) {
            chip(label: "今", value: nowChipValue, isActive: true)
            chip(label: "残り", value: remainingChipValue)
            chip(label: "次", value: nextChipValue)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var nowChipValue: String {
        switch runnerViewModel.phase {
        case .rest: return "休憩"
        case .exercise: return runnerViewModel.isRunning ? "実行中" : "準備"
        case .done: return "未開始"
        }
    }

    private var remainingChipValue: String {
        guard let step = runnerViewModel.currentStep else { return "—" }
        // During .rest the just-completed set has not yet incremented
        // currentSetIndex. Treat it as one set already done so the chip
        // counts down as the user expects.
        let setsDone = runnerViewModel.phase == .rest
            ? runnerViewModel.currentSetIndex + 1
            : runnerViewModel.currentSetIndex
        return "\(max(0, step.sets - setsDone))"
    }

    private var nextChipValue: String {
        if let next = runnerViewModel.nextStep { return next.title }
        if runnerViewModel.isRunning { return "最後" }
        return "—"
    }

    private func chip(label: String, value: String, isActive: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(isActive ? Color.white : .secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isActive ? Color.white : .primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(chipBackground(isActive: isActive))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.84), AppTheme.iceLight.opacity(0.26), .white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isActive ? 0.9 : 0.7
                )
        )
    }

    @ViewBuilder
    private func chipBackground(isActive: Bool) -> some View {
        if isActive {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.accentFilled)
        } else {
            PulseGlassPlate(level: .subtle, focused: true, cornerRadius: 12)
        }
    }

    // MARK: - Rest timer card

    private var restTimerCard: some View {
        VStack(spacing: 4) {
            ZStack {
                Ellipse()
                    .fill(AppTheme.iceLight.opacity(runnerViewModel.phase == .rest ? 0.24 : 0.10))
                    .frame(width: 206, height: 86)
                    .blur(radius: 28)
                    .offset(y: 82)

                Capsule()
                    .fill(.ultraThinMaterial)
                    .frame(width: 204, height: 226)

                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        AppTheme.iceLight.opacity(0.52),
                                        AppTheme.reflectedBlue.opacity(0.34),
                                        AppTheme.deepGlass.opacity(0.18)
                                    ],
                                    startPoint: .bottom,
                                    endPoint: .top
                                )
                            )
                            .frame(height: geometry.size.height * progressFraction)
                    }
                }
                .frame(width: 204, height: 226)
                .clipShape(Capsule())

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.24),
                                Color.clear,
                                AppTheme.deepGlass.opacity(0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 204, height: 226)

                ForEach(0..<5, id: \.self) { layer in
                    Ellipse()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.72 - Double(layer) * 0.09),
                                    AppTheme.iceLight.opacity(0.34),
                                    Color.white.opacity(0.04)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: layer == 0 ? 1.4 : 0.8
                        )
                        .frame(width: CGFloat(198 - layer * 7), height: CGFloat(50 - layer * 2))
                        .offset(y: CGFloat(layer * 40 - 80))
                }

                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.86), AppTheme.iceLight.opacity(0.38), .white.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.2
                    )
                    .frame(width: 204, height: 226)

                VStack(spacing: 6) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        Text("REST TIMER")
                            .font(.caption2.weight(.semibold))
                            .tracking(1.5)
                            .foregroundStyle(.secondary)
                    }
                    Text(timerText)
                        .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 50 : 56, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .foregroundStyle(.primary)
                        .shadow(color: AppTheme.deepSpace.opacity(0.42), radius: 10, y: 4)
                        .accessibilityLabel("残り \(runnerViewModel.remainingSeconds) 秒")
                    if !dynamicTypeSize.isAccessibilitySize,
                       runnerViewModel.phase == .exercise && runnerViewModel.isRunning {
                        Text("ステップ実行中")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !dynamicTypeSize.isAccessibilitySize,
                              runnerViewModel.phase == .done {
                        Text("ルーティン未開始")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 252)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(heroGlassBackground)
        .overlay(glassStroke)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(runnerViewModel.needsAttention ? Color.orange : Color.clear, lineWidth: 3)
        )
    }

    private var progressFraction: Double {
        guard runnerViewModel.phase == .rest,
              let deadline = runnerViewModel.restDeadline,
              let step = runnerViewModel.currentStep,
              step.restSeconds > 0
        else { return 0 }
        let total = Double(step.restSeconds)
        let remaining = max(0, deadline.timeIntervalSinceNow)
        let elapsed = max(0, total - remaining)
        return min(1, elapsed / total)
    }

    private var timerText: String {
        if runnerViewModel.phase == .rest {
            return DateUtils.formatDuration(seconds: runnerViewModel.remainingSeconds)
        }
        return "--:--"
    }

    // MARK: - Current set card

    private var currentSetCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("現在のセット")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if let step = runnerViewModel.currentStep {
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text("\(runnerViewModel.currentSetIndex + 1)")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("/\(step.sets)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("—")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("目標")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if let step = runnerViewModel.currentStep {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text("\(step.repsTarget)")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("Reps")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("—")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .background(glassBackground)
        .overlay(glassStroke)
    }

    // MARK: - Form guide entry (observational)

    /// Shown only when the current step carries a persisted `exerciseId`
    /// that resolves to a bundled exercise WITH a Form Guide. Uses
    /// `Step.hasResolvableGuide` (persisted id → library), never title,
    /// equipment name, or custom-machine inference. Opening the guide does
    /// not touch the workout.
    @ViewBuilder
    private var formGuideButton: some View {
        if let step = runnerViewModel.currentStep,
           step.hasResolvableGuide,
           let id = step.typedExerciseId {
            Button {
                guideExerciseId = id
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "figure.strengthtraining.traditional")
                    Text("フォームを見る")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 48)
                .frame(maxWidth: .infinity)
                .background(glassBackground)
                .overlay(glassStroke)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.accent)
            .accessibilityLabel("\(step.title) のフォームを見る")
        }
    }

    // MARK: - Next up card

    private var nextUpCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.accent.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("NEXT UP")
                    .font(.caption2.weight(.bold))
                    .tracking(1.3)
                    .foregroundStyle(AppTheme.accent)
                Text(nextStepTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            if let step = runnerViewModel.nextStep {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(step.sets) セット")
                        .font(.subheadline.weight(.semibold))
                    Text("× \(step.repsTarget) 回")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(glassBackground)
        .overlay(glassStroke)
    }

    private var nextStepTitle: String {
        if let step = runnerViewModel.nextStep { return step.title }
        if runnerViewModel.isRunning { return "最後の種目です" }
        return "—"
    }

    // MARK: - Idle CTA / End button

    private var startRoutineButton: some View {
        Button {
            showRoutinePicker = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .bold))
                Text("ルーティンを開始")
                    .font(.headline)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.accentFilled)
                    .shadow(
                        color: Color(red: 0.27, green: 0.5, blue: 0.95).opacity(0.35),
                        radius: 18, x: 0, y: 10
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("ルーティンを開始")
    }

    private var endSessionButton: some View {
        HStack {
            Spacer()
            Button {
                showEndAlert = true
            } label: {
                Text("セッション終了")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.red.opacity(0.85))
                    .padding(.vertical, 10)
                    .padding(.horizontal, 18)
                    .background(
                        Capsule().fill(.regularMaterial)
                    )
                    .overlay(
                        Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 0.6)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("セッションを中断して終了")
            Spacer()
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            iconButton(label: "戻る", systemImage: "arrow.uturn.backward",
                       a11y: "1 セット戻る") {
                runnerViewModel.handle(action: .back)
            }
            iconButton(label: "+10s", systemImage: "plus",
                       a11y: "休憩を 10 秒延長",
                       isAccent: true,
                       isDisabled: runnerViewModel.phase != .rest) {
                runnerViewModel.handle(action: .extend)
            }
            primaryCompleteButton
            iconButton(label: "スキップ", systemImage: "forward.end.fill",
                       a11y: "このステップをスキップ") {
                runnerViewModel.handle(action: .skip)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.thinMaterial)
                .overlay(
                    LinearGradient(
                        colors: [.white.opacity(0.18), .clear, AppTheme.deepGlass.opacity(0.18)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(Capsule())
                )
                .shadow(color: AppTheme.deepGlass.opacity(0.60), radius: 24, x: 0, y: 12)
        )
        .overlay(
            Capsule().strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.72), AppTheme.iceLight.opacity(0.28), .white.opacity(0.06)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        )
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var primaryCompleteButton: some View {
        Button {
            runnerViewModel.handle(action: .complete)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                Text(completeTitle)
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .background(
                Capsule()
                    .fill(AppTheme.accentFilled)
                    .shadow(color: AppTheme.accent.opacity(0.22), radius: 10, x: 0, y: 6)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(completeAccessibility)
    }

    private var completeTitle: String {
        runnerViewModel.phase == .rest ? "休憩終了" : "完了"
    }

    private var completeAccessibility: String {
        runnerViewModel.phase == .rest
            ? "休憩を終了して次のセットへ"
            : "このセットを完了して休憩へ"
    }

    private func iconButton(
        label: String,
        systemImage: String,
        a11y: String,
        isAccent: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .bold))
            Text(label)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            }
            .frame(width: 52, height: 52)
            .foregroundStyle(iconButtonForeground(isAccent: isAccent, isDisabled: isDisabled))
            .background(iconButtonBackground(isAccent: isAccent, isDisabled: isDisabled))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(a11y)
    }

    private func iconButtonForeground(isAccent: Bool, isDisabled: Bool) -> Color {
        if isDisabled { return Color.secondary.opacity(0.4) }
        return isAccent ? Color.white : Color.primary
    }

    @ViewBuilder
    private func iconButtonBackground(isAccent: Bool, isDisabled: Bool) -> some View {
        if isAccent && !isDisabled {
            Circle().fill(AppTheme.accentFilled)
        } else if isAccent && isDisabled {
            Circle().fill(.ultraThinMaterial)
        } else {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Circle().strokeBorder(.white.opacity(0.20), lineWidth: 0.7)
                )
        }
    }

    // MARK: - Glass surfaces

    private var glassBackground: some View {
        PulseGlassPlate(level: .functional, focused: true, cornerRadius: 22)
    }

    private var heroGlassBackground: some View {
        PulseGlassPlate(level: .hero, focused: true, cornerRadius: 28)
    }

    private var glassStroke: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.clear, lineWidth: 0)
    }
}
