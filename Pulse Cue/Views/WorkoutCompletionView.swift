//
//  WorkoutCompletionView.swift
//  Pulse Cue
//
//  The screen a finished workout ends on. Its whole job is to say clearly
//  that the workout is over and show the three numbers the user just earned,
//  so the Runner never collapses straight back onto the routine list with a
//  "このまま開始" button under the finger.
//
//  It is presentation only: the session it describes was already finalized by
//  `RunnerViewModel.finishSession`. Nothing here writes data, and the single
//  CTA only clears the transient summary.
//

import SwiftUI

struct WorkoutCompletionView: View {
    let summary: WorkoutCompletionSummary
    let onDone: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                headline
                metrics
                // At accessibility sizes the metrics are taller than the
                // screen, so a floating CTA would sit on top of a half-cut
                // number. There it scrolls with the content instead.
                if dynamicTypeSize.isAccessibilitySize {
                    doneButton
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 40)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            if !dynamicTypeSize.isAccessibilitySize {
                doneButton
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
    }

    private var headline: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)
            Text("ワークアウト完了")
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var metrics: some View {
        VStack(spacing: 0) {
            metricRow(label: "実施時間", value: durationText)
            divider
            metricRow(label: "完了した種目", value: "\(summary.completedExerciseCount)")
            divider
            metricRow(label: "完了したセット", value: "\(summary.completedSetCount)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                .fill(Color.black.opacity(0.34))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                .strokeBorder(AppTheme.separator.opacity(0.42), lineWidth: 1)
        )
    }

    private var divider: some View {
        Divider().overlay(Color.white.opacity(0.08))
    }

    @ViewBuilder
    private func metricRow(label: String, value: String) -> some View {
        let text = Text(label)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        let number = Text(value)
            .font(.title3.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(AppTheme.accent)

        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    text
                    number
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 12) {
                    text
                    Spacer(minLength: 8)
                    number
                }
            }
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value)")
    }

    /// Whole minutes and seconds, matching the History row's duration format.
    private var durationText: String {
        DateUtils.formatDuration(seconds: Int(summary.duration.rounded()))
    }

    private var doneButton: some View {
        Button(action: onDone) {
            Text("完了")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(AppTheme.accentFilled)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workout-completion-done")
        .accessibilityLabel("ワークアウトの記録を閉じる")
    }
}

#Preview {
    ZStack {
        AppTheme.deepSpace.ignoresSafeArea()
        WorkoutCompletionView(
            summary: WorkoutCompletionSummary(
                sessionId: UUID(),
                duration: 1_845,
                completedExerciseCount: 3,
                completedSetCount: 8
            ),
            onDone: {}
        )
    }
    .preferredColorScheme(.dark)
}
