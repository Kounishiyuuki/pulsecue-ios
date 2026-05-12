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
    @Environment(\.colorScheme) private var colorScheme

    @State private var showRoutinePicker = false
    @State private var showEndAlert = false

    var body: some View {
        ZStack {
            backgroundLayer.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    brandHeader
                    statusChips
                    restTimerCard
                    currentSetCard
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
        }
        .navigationTitle("ランナー")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if runnerViewModel.isRunning {
                actionBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .sheet(isPresented: $showRoutinePicker) {
            RoutinePickerSheet()
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
        LinearGradient(colors: backgroundColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var backgroundColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.05, green: 0.07, blue: 0.12),
                Color(red: 0.07, green: 0.06, blue: 0.13),
                Color(red: 0.05, green: 0.07, blue: 0.10)
            ]
        } else {
            return [
                Color(red: 0.93, green: 0.96, blue: 1.00),
                Color(red: 0.96, green: 0.97, blue: 1.00),
                Color(red: 0.99, green: 0.96, blue: 1.00)
            ]
        }
    }

    private var accentGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.27, green: 0.62, blue: 0.95),
                Color(red: 0.49, green: 0.51, blue: 0.97),
                Color(red: 0.66, green: 0.45, blue: 0.95)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Brand header

    private var brandHeader: some View {
        HStack {
            ZStack {
                Circle().fill(accentGradient).frame(width: 32, height: 32)
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
                .foregroundStyle(isActive ? Color.white.opacity(0.85) : .secondary)
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
                .strokeBorder(.white.opacity(isActive ? 0.4 : 0.6), lineWidth: 0.6)
        )
    }

    @ViewBuilder
    private func chipBackground(isActive: Bool) -> some View {
        if isActive {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(accentGradient)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        }
    }

    // MARK: - Rest timer card

    private var restTimerCard: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color(.systemGray5), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .frame(width: 220, height: 220)

                Circle()
                    .trim(from: 0, to: progressFraction)
                    .stroke(accentGradient, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 220, height: 220)
                    .animation(.easeInOut(duration: 0.3), value: progressFraction)

                VStack(spacing: 6) {
                    Text("REST TIMER")
                        .font(.caption2.weight(.semibold))
                        .tracking(1.5)
                        .foregroundStyle(.secondary)
                    Text(timerText)
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .foregroundStyle(.primary)
                        .accessibilityLabel("残り \(runnerViewModel.remainingSeconds) 秒")
                    if runnerViewModel.phase == .exercise && runnerViewModel.isRunning {
                        Text("ステップ実行中")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if runnerViewModel.phase == .done {
                        Text("ルーティン未開始")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(glassBackground)
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

    // MARK: - Next up card

    private var nextUpCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accentGradient.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accentGradient)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("NEXT UP")
                    .font(.caption2.weight(.bold))
                    .tracking(1.3)
                    .foregroundStyle(accentGradient)
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
                    .fill(accentGradient)
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
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 8)
        )
        .overlay(
            Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 0.6)
        )
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
                    .fill(accentGradient)
                    .shadow(
                        color: Color(red: 0.27, green: 0.5, blue: 0.95).opacity(0.4),
                        radius: 14, x: 0, y: 6
                    )
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
            Circle().fill(accentGradient)
        } else if isAccent && isDisabled {
            Circle().fill(Color(.systemGray5))
        } else {
            Circle().fill(Color(.systemGray6))
        }
    }

    // MARK: - Glass surfaces

    private var glassBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.regularMaterial)
            .shadow(color: .black.opacity(0.05), radius: 14, x: 0, y: 8)
    }

    private var glassStroke: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.7), .white.opacity(0.1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.6
            )
    }
}
