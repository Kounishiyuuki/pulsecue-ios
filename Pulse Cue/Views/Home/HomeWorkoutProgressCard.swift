//
//  HomeWorkoutProgressCard.swift
//  Pulse Cue
//
//  Home's "what you have been doing" block: the last workout, this week's
//  totals, and a way into the full progress screen.
//
//  Hidden entirely until there is history. A first-time Home leads with
//  starting something, not with four zeroes — an empty progress card is a
//  report that the user has done nothing, which is both true and useless.
//
//  Repeating a workout starts a *new* Session through `WorkoutStarter`; this
//  card only asks for it. History is never reused or mutated, and the card
//  holds no runner state, so it cannot become a second way to start a workout
//  that behaves differently from the first.
//

import SwiftUI

struct HomeWorkoutProgressCard: View {
    let summary: HomeProgressSummary
    let onRepeatLastWorkout: () -> Void

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    @ViewBuilder
    var body: some View {
        if summary.hasHistory {
            VStack(alignment: .leading, spacing: 14) {
                PulseSectionHeader("トレーニング", icon: "figure.strengthtraining.traditional")

                if let last = summary.lastWorkout {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("最後のトレーニング")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.accent)
                        HStack(spacing: 8) {
                            Text(Self.shortDateFormatter.string(from: last.date))
                                .font(.subheadline.weight(.semibold))
                            Text(last.routineName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(DateUtils.formatDuration(seconds: max(0, last.durationSeconds)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button(action: onRepeatLastWorkout) {
                            Label("前回のメニューをもう一度", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .tint(AppTheme.accent)
                    }
                }

                weeklyRow

                NavigationLink {
                    WorkoutProgressView()
                } label: {
                    HStack(spacing: 6) {
                        Text("進捗を見る")
                        Image(systemName: "chevron.right").font(.caption2)
                        Spacer(minLength: 0)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(minHeight: 44)
                }
            }
            .padding(16)
            .pulseCard()
        }
    }

    private var weeklyRow: some View {
        HStack(spacing: 10) {
            stat("\(summary.weeklyWorkoutCount)", "今週の回数")
            stat("\(summary.weeklyTrainingDays)", "日数")
            stat("\(summary.weeklyCompletedSets)", "セット")
            stat(
                DateUtils.formatDuration(seconds: max(0, summary.weeklyDurationSeconds)),
                "合計時間"
            )
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.weight(.bold)).foregroundStyle(.primary)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
