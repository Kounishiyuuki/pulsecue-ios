//
//  WorkoutCompletionView.swift
//  Pulse Cue
//
//  The screen a finished workout ends on. Its whole job is to say clearly
//  that the workout is over and show the numbers the user just earned,
//  so the Runner never collapses straight back onto the routine list with a
//  "このまま開始" button under the finger.
//
//  The session it describes was already finalized by
//  `RunnerViewModel.finishSession`, and the CTA only clears the transient
//  summary. The one write is optional: the Runner may pass the workout's
//  final set, whose RIR can still be set here (#258); Free Workout passes
//  none, so its screen is unchanged.
//

import SwiftUI

struct WorkoutCompletionView: View {
    let summary: WorkoutCompletionSummary
    var finalSet: RunnerViewModel.LastCompletedSet? = nil
    /// Called with the row's own set, so an action always names the set it
    /// was shown for.
    var onFinalSetRIR: (Int?, RunnerViewModel.LastCompletedSet) -> Void = { _, _ in }
    let onDone: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                headline
                metrics
                if let finalSet { finalSetRow(finalSet) }
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
            metricRow(label: "種目", value: "\(summary.completedExerciseCount)")
            divider
            metricRow(label: "セット", value: "\(summary.completedSetCount)")
            divider
            metricRow(label: "総レップ数", value: "\(summary.totalReps)", spokenValue: "\(summary.totalReps)回")
            divider
            metricRow(
                label: "総ボリューム",
                value: WorkoutCompletionSummary.volumeText(summary.totalVolumeKg),
                spokenValue: "\(SetWeight.number(summary.totalVolumeKg))キログラム"
            )
            if let kcal = summary.estimatedCalories {
                divider
                metricRow(
                    label: "推定消費カロリー",
                    value: WorkoutCalorieEstimator.text(kcal),
                    spokenValue: "\(kcal)キロカロリー",
                    hint: WorkoutCalorieEstimator.disclaimer
                )
            }
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

    /// "最後のセット" and its RIR chip, under the metrics: secondary to them,
    /// optional, and never in the way of 完了. The metrics never include RIR.
    @ViewBuilder
    private func finalSetRow(_ set: RunnerViewModel.LastCompletedSet) -> some View {
        let description = VStack(alignment: .leading, spacing: 2) {
            Text("最後のセット")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(set.title) · セット\(set.setIndex + 1) · \(set.valueText)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    description
                    SetRIRPicker(value: set.repsInReserve, onChange: { onFinalSetRIR($0, set) })
                }
            } else {
                HStack(spacing: 12) {
                    description
                    Spacer(minLength: 8)
                    SetRIRPicker(value: set.repsInReserve, onChange: { onFinalSetRIR($0, set) })
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        // One element, like the Runner's row: the RIR values are its actions.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(set.repsInReserve == nil ? set.accessibilityLabel + "、" + SetRIRPicker.spokenText(nil) : set.accessibilityLabel)
        .accessibilityActions {
            ForEach(SetRIRPicker.options, id: \.self) { value in
                Button(SetRIRPicker.spokenText(value)) { onFinalSetRIR(value, set) }
            }
        }
        .accessibilityIdentifier("workout-completion-final-set")
    }

    private var divider: some View {
        Divider().overlay(Color.white.opacity(0.08))
    }

    @ViewBuilder
    private func metricRow(label: String, value: String, spokenValue: String? = nil, hint: String? = nil) -> some View {
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
        .accessibilityLabel("\(label)、\(spokenValue ?? value)")
        .accessibilityHint(hint ?? "")
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
