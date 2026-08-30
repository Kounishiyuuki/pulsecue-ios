//
//  RunnerActionBar.swift
//  Pulse Cue
//
//  The three controls that drive a workout: back, complete, skip.
//
//  It sits in a `safeAreaInset` and is the only thing on the Runner that must
//  be reachable one-handed without looking, which is what the sizing is about
//  — 52pt minimum, capsules that widen for a two-word label rather than
//  clipping it, and a stacked layout at accessibility sizes so the primary
//  action keeps a full-width target.
//
//  Two invariants live here rather than in the view model:
//
//  **Complete is guarded against a double tap.** `handle(action: .complete)`
//  advances the set, and two taps landing inside one animation would advance
//  twice. The 300 ms latch is a UI concern — the model is not the place to
//  defend against a finger.
//
//  **Complete is disabled without a context.** `completeContext` is nil when
//  there is nothing to complete; a button that looks live and does nothing is
//  worse than one that is visibly unavailable.
//
//  Nothing else here decides anything: back and skip forward straight to the
//  model, which owns what those mean.
//

import SwiftUI

struct RunnerActionBar: View {
    let phase: RunnerPhase
    /// Nil when there is nothing to complete right now.
    let completeContext: RunnerViewModel.CompleteContext?

    let onBack: () -> Void
    let onSkip: () -> Void
    let onComplete: (RunnerViewModel.CompleteContext) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Latched while a completion is in flight; see the note above.
    @State private var isCompletePending = false

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 10) {
                completeButton
                HStack(spacing: 10) {
                    backButton
                    skipButton
                }
                .frame(maxWidth: .infinity)
            }
            .padding(12)
            .background(barBackground(cornerRadius: 28))
        } else {
            HStack(spacing: 10) {
                backButton
                completeButton
                skipButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(barBackground(cornerRadius: 40))
        }
    }

    // MARK: - Buttons

    private var backButton: some View {
        iconButton(label: "戻る", systemImage: "arrow.uturn.backward", a11y: "1 セット戻る", action: onBack)
    }

    /// Skip advances past the *whole* current exercise (remaining sets
    /// included) — it has never skipped a single set. The label says so.
    private var skipButton: some View {
        iconButton(
            label: "種目をスキップ",
            systemImage: "forward.end.fill",
            a11y: "この種目をスキップして次の種目へ",
            action: onSkip
        )
    }

    private var completeButton: some View {
        Button {
            guard !isCompletePending, let completeContext else { return }
            isCompletePending = true
            onComplete(completeContext)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                isCompletePending = false
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
        .disabled(isCompletePending || completeContext == nil)
        .accessibilityLabel(completeAccessibility)
    }

    private var completeTitle: String {
        phase == .rest ? "休憩終了" : "完了"
    }

    private var completeAccessibility: String {
        phase == .rest ? "休憩を終了して次のセットへ" : "このセットを完了して休憩へ"
    }

    // MARK: - Chrome

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
            // A capsule, not a circle: a two-word label ("種目をスキップ")
            // widens the button instead of being clipped, and a short label
            // ("戻る") still renders as the original 52pt circle.
            .padding(.horizontal, 12)
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
            Capsule().fill(AppTheme.accentFilled)
        } else if isAccent && isDisabled {
            Capsule().fill(reduceTransparency ? AnyShapeStyle(AppTheme.surfaceCard) : AnyShapeStyle(.ultraThinMaterial))
        } else {
            Capsule()
                .fill(reduceTransparency ? AnyShapeStyle(AppTheme.surfaceCard) : AnyShapeStyle(.ultraThinMaterial))
                .overlay(
                    Capsule().strokeBorder(.white.opacity(0.20), lineWidth: 0.7)
                )
        }
    }

    private func barBackground(cornerRadius: CGFloat) -> some View {
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
}
