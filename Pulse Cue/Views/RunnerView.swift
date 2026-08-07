//
//  RunnerView.swift
//  Pulse Cue
//
//  Created by Codex.
//
//  Focused dark Runner. The active value is always the visual anchor:
//  current reps with ±1 controls during exercise, and remaining rest time
//  with ±10-second controls during rest. Existing navigation, form guide,
//  next-step information, Complete/Skip/Back actions, and session lifecycle
//  stay in place around that phase-specific focus card.
//

import SwiftUI
import UIKit

struct RunnerView: View {
    @EnvironmentObject var runnerViewModel: RunnerViewModel
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ScaledMetric(relativeTo: .largeTitle) private var repNumberSize: CGFloat = 96
    @ScaledMetric(relativeTo: .largeTitle) private var restNumberSize: CGFloat = 48
    @ScaledMetric(relativeTo: .largeTitle) private var restDialSize: CGFloat = 132

    @State private var showRoutinePicker = false
    @State private var routinePendingStartAfterPickerDismissal: Routine?
    @State private var showEndAlert = false
    @State private var isCompleteActionPending = false
    /// Non-nil while the Form Guide sheet is shown for the current step.
    /// Resolved ONLY from the persisted `Step.exerciseId` (never from title
    /// or equipment). Presenting it is observational — no workout state,
    /// timer, set/rep progress, or StepResult is changed.
    @State private var guideExerciseId: ExerciseID?
    /// Non-nil while the exercise-replacement sheet is presented.
    @State private var replacementTarget: RunnerReplacementTarget?

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
                        phaseSignature
                        formGuideButton
                        replaceCurrentExerciseButton
                        nextUpCard
                        replaceNextExerciseButton
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
        .sheet(isPresented: $showRoutinePicker, onDismiss: startPendingRoutine) {
            RoutinePickerSheet(onSelect: { routinePendingStartAfterPickerDismissal = $0 })
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
                    runnerViewModel.replaceExercise(target.step, with: candidate)
                }
            )
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
        .onChange(of: runnerViewModel.phase) { _, newPhase in
            UIAccessibility.post(
                notification: .announcement,
                argument: phaseAnnouncement(for: newPhase)
            )
        }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        LinearGradient(
            colors: [AppTheme.deepSpace.opacity(0.82), Color.black],
            startPoint: .top,
            endPoint: .bottom
        )
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

    @ViewBuilder
    private var statusChips: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                chip(label: "今", value: nowChipValue, accessibilityText: "現在の状態、\(nowChipValue)", isActive: true)
                chip(label: "残り", value: remainingChipValue, accessibilityText: remainingChipAccessibility)
                chip(label: "次", value: nextChipValue, accessibilityText: nextChipAccessibility)
            }
        } else {
            HStack(spacing: 10) {
                chip(label: "今", value: nowChipValue, accessibilityText: "現在の状態、\(nowChipValue)", isActive: true)
                chip(label: "残り", value: remainingChipValue, accessibilityText: remainingChipAccessibility)
                chip(label: "次", value: nextChipValue, accessibilityText: nextChipAccessibility)
            }
        }
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

    private var remainingChipAccessibility: String {
        guard runnerViewModel.currentStep != nil else { return "残りセット、未設定" }
        return "残り \(remainingChipValue) セット"
    }

    private var nextChipAccessibility: String {
        if runnerViewModel.nextStep != nil { return "次の種目、\(nextChipValue)" }
        return runnerViewModel.isRunning ? "次の種目、なし" : "次の種目、未設定"
    }

    private func chip(
        label: String,
        value: String,
        accessibilityText: String,
        isActive: Bool = false
    ) -> some View {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
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

    // MARK: - Phase signature

    @ViewBuilder
    private var phaseSignature: some View {
        if runnerViewModel.phase == .rest {
            restTimerCard
        } else {
            activeExerciseCard
        }
    }

    private var activeExerciseCard: some View {
        VStack(spacing: 18) {
            VStack(spacing: 5) {
                Text(runnerViewModel.isRunning ? "現在の回数" : "準備")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(runnerViewModel.currentStep?.title ?? "ルーティンを選択")
                    .font(.headline.weight(.semibold))
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                adjustmentButton(
                    label: "1 回減らす",
                    systemImage: "minus",
                    disabled: !runnerViewModel.isRunning || runnerViewModel.currentReps == 0
                ) {
                    runnerViewModel.adjustCurrentReps(by: -1)
                }

                VStack(spacing: 0) {
                    Text(runnerViewModel.isRunning ? "\(runnerViewModel.currentReps)" : "—")
                        .font(.system(size: repNumberSize, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.55)
                        .lineLimit(1)
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.accent)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                    Text("回")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("現在 \(runnerViewModel.currentReps) 回")

                adjustmentButton(
                    label: "1 回増やす",
                    systemImage: "plus",
                    disabled: !runnerViewModel.isRunning
                ) {
                    runnerViewModel.adjustCurrentReps(by: 1)
                }
            }

            if let step = runnerViewModel.currentStep {
                Text("セット \(runnerViewModel.currentSetIndex + 1) / \(step.sets)   •   目標 \(step.repsTarget) 回")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 16 : 22)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(focusCardBackground)
        .overlay(focusCardStroke)
    }

    // MARK: - Rest timer card

    private var restTimerCard: some View {
        VStack(spacing: 18) {
            VStack(spacing: 5) {
                Text("残り休憩時間")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(runnerViewModel.currentStep?.title ?? "休憩")
                    .font(.headline.weight(.semibold))
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    shortenRestButton
                    restTimerDial
                    extendRestButton
                }

                VStack(spacing: 16) {
                    restTimerDial
                    HStack(spacing: 24) {
                        shortenRestButton
                        extendRestButton
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 24)
        .background(focusCardBackground)
        .overlay(focusCardStroke)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(runnerViewModel.needsAttention ? Color.orange : Color.clear, lineWidth: 3)
        )
    }

    private var restTimerDial: some View {
        let dialSize = min(restDialSize, 220)
        return ZStack {
            Circle()
                .fill(Color.white.opacity(0.025))
            Circle()
                .stroke(AppTheme.separator.opacity(0.35), lineWidth: 3)
            Circle()
                .stroke(AppTheme.accent.opacity(0.68), lineWidth: 2)
                .padding(7)
            Text(timerText)
                .font(.system(size: restNumberSize, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.65)
                .lineLimit(1)
                .monospacedDigit()
                .foregroundStyle(AppTheme.accent)
                .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
        }
        .frame(width: dialSize, height: dialSize)
        .accessibilityLabel("残り \(runnerViewModel.remainingSeconds) 秒")
    }

    private var shortenRestButton: some View {
        adjustmentButton(label: "休憩を 10 秒短縮", systemImage: "minus") {
            runnerViewModel.shortenRest()
        }
    }

    private var extendRestButton: some View {
        adjustmentButton(label: "休憩を 10 秒延長", systemImage: "plus") {
            runnerViewModel.handle(action: .extend)
        }
    }

    private func adjustmentButton(
        label: String,
        systemImage: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 52, height: 52)
                .foregroundStyle(disabled ? Color.secondary.opacity(0.35) : AppTheme.accent)
                .background(Circle().fill(Color.white.opacity(0.055)))
                .overlay(Circle().strokeBorder(AppTheme.separator.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private var timerText: String {
        DateUtils.formatDuration(seconds: runnerViewModel.remainingSeconds)
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

    // MARK: - Exercise replacement entries

    /// "種目を変更" for the current exercise — only while it is still unstarted
    /// (no set completed). A completed / in-progress exercise cannot be swapped.
    @ViewBuilder
    private var replaceCurrentExerciseButton: some View {
        if runnerViewModel.canReplaceCurrentExercise, let step = runnerViewModel.currentStep {
            replaceButton(for: step, label: "種目を変更")
        }
    }

    /// "次の種目を変更" for the upcoming (always unstarted) exercise.
    @ViewBuilder
    private var replaceNextExerciseButton: some View {
        if runnerViewModel.canReplaceNextExercise, let step = runnerViewModel.nextStep {
            replaceButton(for: step, label: "次の種目を変更")
        }
    }

    private func replaceButton(for step: Step, label: String) -> some View {
        Button {
            replacementTarget = RunnerReplacementTarget(
                step: step,
                name: step.title,
                machineId: runnerViewModel.exerciseMachineId(for: step),
                candidates: runnerViewModel.replacementCandidates(for: step)
            )
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text(label)
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
        .accessibilityLabel("\(step.title) を別の種目に変更")
    }

    // MARK: - Next up card

    @ViewBuilder
    private var nextUpCard: some View {
        if dynamicTypeSize.isAccessibilitySize {
            HStack(alignment: .center, spacing: 12) {
                nextUpIdentity
                Spacer(minLength: 8)
                if let step = runnerViewModel.nextStep {
                    Text("\(step.sets) セット × \(step.repsTarget) 回")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(glassBackground)
            .overlay(glassStroke)
        } else {
            HStack(spacing: 12) {
                nextUpIdentity
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
    }

    private var nextUpIdentity: some View {
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
                Text("次の種目")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.accent)
                Text(nextStepTitle)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                        color: AppTheme.deepGlass.opacity(0.38),
                        radius: 12, x: 0, y: 7
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("ルーティンを開始")
    }

    private func startPendingRoutine() {
        guard let routine = routinePendingStartAfterPickerDismissal else { return }
        routinePendingStartAfterPickerDismissal = nil
        runnerViewModel.start(routine: routine)
    }

    private var endSessionButton: some View {
        HStack {
            Spacer()
            Button {
                showEndAlert = true
            } label: {
                Text("セッション終了")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color(red: 1.0, green: 0.48, blue: 0.48))
                    .padding(.horizontal, 18)
                    .frame(minHeight: 48)
                    .background(
                        Capsule().fill(reduceTransparency ? AnyShapeStyle(AppTheme.surfaceCard) : AnyShapeStyle(.regularMaterial))
                    )
                    .overlay(
                        Capsule().strokeBorder(AppTheme.separator, lineWidth: 0.8)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("セッションを中断して終了")
            Spacer()
        }
    }

    // MARK: - Action bar

    @ViewBuilder
    private var actionBar: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 10) {
                primaryCompleteButton
                HStack(spacing: 10) {
                    backButton
                    skipButton
                }
                .frame(maxWidth: .infinity)
            }
            .padding(12)
            .background(actionBarBackground(cornerRadius: 28))
        } else {
            HStack(spacing: 10) {
                backButton
                primaryCompleteButton
                skipButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(actionBarBackground(cornerRadius: 40))
        }
    }

    private var backButton: some View {
        iconButton(label: "戻る", systemImage: "arrow.uturn.backward",
                   a11y: "1 セット戻る") {
            runnerViewModel.handle(action: .back)
        }
    }

    private var skipButton: some View {
        iconButton(label: "スキップ", systemImage: "forward.end.fill",
                   a11y: "このステップをスキップ") {
            runnerViewModel.handle(action: .skip)
        }
    }

    private func actionBarBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(reduceTransparency ? AnyShapeStyle(AppTheme.surfaceCard) : AnyShapeStyle(.thinMaterial))
            .overlay(
                LinearGradient(
                    colors: [
                        .white.opacity(reduceTransparency ? 0 : 0.05),
                        .clear,
                        AppTheme.deepGlass.opacity(reduceTransparency ? 0 : 0.10)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(
                    AppTheme.separator.opacity(0.85),
                    lineWidth: 0.8
                )
            )
            .shadow(color: AppTheme.shadow, radius: 14, x: 0, y: 8)
    }

    private var primaryCompleteButton: some View {
        let context = runnerViewModel.completeContext
        return Button {
            guard !isCompleteActionPending, let context else { return }
            isCompleteActionPending = true
            runnerViewModel.handle(action: .complete, context: context)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                isCompleteActionPending = false
            }
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
        .disabled(isCompleteActionPending || context == nil)
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
            }
            .frame(minWidth: 52, minHeight: 52)
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
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
            Circle().fill(reduceTransparency ? AnyShapeStyle(AppTheme.surfaceCard) : AnyShapeStyle(.ultraThinMaterial))
        } else {
            Circle()
                .fill(reduceTransparency ? AnyShapeStyle(AppTheme.surfaceCard) : AnyShapeStyle(.ultraThinMaterial))
                .overlay(
                    Circle().strokeBorder(.white.opacity(0.20), lineWidth: 0.7)
                )
        }
    }

    // MARK: - Glass surfaces

    private var glassBackground: some View {
        PulseGlassPlate(level: .functional, focused: true, cornerRadius: 22)
    }

    private var focusCardBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.black.opacity(0.34))
    }

    private var focusCardStroke: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(AppTheme.separator.opacity(0.42), lineWidth: 1)
    }

    private var glassStroke: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.clear, lineWidth: 0)
    }

    private func phaseAnnouncement(for phase: RunnerPhase) -> String {
        switch phase {
        case .exercise:
            return "エクササイズ。現在 \(runnerViewModel.currentReps) 回"
        case .rest:
            return "休憩。残り \(runnerViewModel.remainingSeconds) 秒"
        case .done:
            return "ワークアウト完了"
        }
    }
}

/// Identifies which live step the replacement sheet is acting on, carrying the
/// candidates ranked when the sheet was opened. A stable per-presentation id
/// keeps the sheet identity independent of the underlying `Step`.
private struct RunnerReplacementTarget: Identifiable {
    let id = UUID()
    let step: Step
    let name: String
    let machineId: String
    let candidates: [GeneratedExercise]
}
