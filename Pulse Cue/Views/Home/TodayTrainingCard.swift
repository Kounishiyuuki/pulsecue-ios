//
//  TodayTrainingCard.swift
//  Pulse Cue
//
//  Everything about today's training, in one place, with one obvious action.
//
//  Home used to spread this across four competing surfaces: a filled 開始
//  button, a Gym/Quick Plan card with three CTAs of its own, a progress card
//  with a "repeat last workout" button, and a weekly stats row. All of them
//  looked equally important, so opening Home meant choosing a *feature*
//  rather than doing the thing you came to do.
//
//  The rule here is one primary action at a time, decided by state rather
//  than offered as a menu:
//
//    a workout is running  →  続ける
//    routines exist        →  ワークアウトを開始
//    nothing yet           →  メニューを作る
//
//  Plan creation is real and stays reachable, but it is secondary: it sits
//  behind a disclosure that reveals the existing `TodayGymPlanCard`
//  unchanged — same states, same Quick Plan flow, same gym switching. Nothing
//  about how a plan is generated was touched; it simply stopped competing
//  with starting one.
//

import SwiftUI

/// What Home needs to know about today's training. Pure presentation: every
/// value is derived from state the app already owns.
struct HomeTrainingSummary: Equatable {
    /// A workout is in progress right now.
    let isRunning: Bool
    /// Current exercise, when running. Shown as progress, not as an action.
    let currentStepTitle: String?
    let currentSet: Int?
    let totalSets: Int?
    /// Whether the user has any routine to start at all.
    let hasRoutines: Bool
    /// Name of the most recently completed workout, if any.
    let lastWorkoutName: String?
}

struct TodayTrainingCard: View {
    let summary: HomeTrainingSummary
    /// Start or resume. Owned by `TodayView`; this view never touches the
    /// Runner or creates a Session.
    let onPrimaryAction: () -> Void

    @State private var showsPlanOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            statusLine

            Button(action: onPrimaryAction) {
                HStack(spacing: 10) {
                    Image(systemName: summary.isRunning ? "figure.run" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                    Text(primaryTitle)
                        .font(.headline)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .opacity(0.85)
                }
                .foregroundStyle(.white)
                .padding(.vertical, 15)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AppTheme.accentFilled)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(primaryAccessibilityLabel)

            planOptions
        }
        .padding(16)
        .pulseCard()
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
            Text("今日のトレーニング")
                .font(.headline)
            Spacer(minLength: 0)
        }
    }

    /// One line of context, never more. During a workout it is the exercise
    /// you are on; otherwise it is what you last did, or nothing at all.
    @ViewBuilder
    private var statusLine: some View {
        if summary.isRunning, let title = summary.currentStepTitle {
            let setText = setProgressText
            Text(setText.map { "\(title)・\($0)" } ?? title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(
                    setText.map { "実行中 \(title) \($0)" } ?? "実行中 \(title)"
                )
        } else if !summary.hasRoutines {
            Text("まだメニューがありません")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if let last = summary.lastWorkoutName {
            Text("前回: \(last)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var setProgressText: String? {
        guard let set = summary.currentSet, let total = summary.totalSets, total > 0 else {
            return nil
        }
        return "\(set)/\(total) セット"
    }

    /// Plan creation, deliberately behind one tap.
    ///
    /// `TodayGymPlanCard` is reused as-is rather than reimplemented: it holds
    /// the gym state machine, the Quick Plan entry and the body-part flow, and
    /// none of that changed. It simply no longer sits at the same level as
    /// starting a workout.
    private var planOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showsPlanOptions.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption.weight(.semibold))
                    Text("メニューを作る")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: showsPlanOptions ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(AppTheme.accent)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("メニューを作る")
            .accessibilityHint(showsPlanOptions ? "閉じる" : "作成方法を表示")

            if showsPlanOptions {
                TodayGymPlanCard()
            }
        }
    }

    private var primaryTitle: String {
        if summary.isRunning { return "続ける" }
        return summary.hasRoutines ? "ワークアウトを開始" : "メニューを作る"
    }

    private var primaryAccessibilityLabel: String {
        if summary.isRunning { return "実行中のワークアウトを続ける" }
        return summary.hasRoutines ? "ワークアウトを開始" : "メニューを作る"
    }
}
