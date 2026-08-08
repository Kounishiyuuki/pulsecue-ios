//
//  WorkoutProgressView.swift
//  Pulse Cue
//
//  The "進捗" detail screen reached from Home. Read-only over History: this
//  week's volume, and per-exercise recent progress (latest vs previous reps
//  and a reps-only personal best). All figures come from the pure
//  `WorkoutProgress` derivations, recomputed on appear / History change — not
//  per body render. No chart, no invented metrics.
//

import SwiftUI
import SwiftData

struct WorkoutProgressView: View {
    @Query(sort: [SortDescriptor(\Session.startedAt, order: .reverse)])
    private var sessions: [Session]
    @Query private var stepResults: [StepResult]
    @Query private var routines: [Routine]
    @Query private var allSteps: [Step]

    @State private var summary: HomeProgressSummary = .empty
    @State private var insights: [ExerciseProgressInsight] = []

    var body: some View {
        ZStack {
            PulseAtmosphericBackground().ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if summary.hasHistory {
                        weeklyCard
                        exerciseSection
                    } else {
                        emptyCard
                    }
                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .navigationTitle("進捗")
        .navigationBarTitleDisplayMode(.inline)
        .task { recompute() }
        .onChange(of: sessions.count) { _, _ in recompute() }
        .onChange(of: stepResults.count) { _, _ in recompute() }
    }

    private func recompute() {
        summary = HomeProgressSummary.make(sessions: sessions, results: stepResults, routines: routines)
        insights = WorkoutProgressQuery.exerciseInsights(steps: allSteps, sessions: sessions, results: stepResults, limit: 8)
    }

    // MARK: - Weekly

    private var weeklyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("今週")
                .font(.title3.weight(.bold))
            HStack(spacing: 10) {
                stat("\(summary.weeklyWorkoutCount)", "回数")
                stat("\(summary.weeklyTrainingDays)", "日数")
                stat("\(summary.weeklyCompletedSets)", "セット")
                stat(DateUtils.formatDuration(seconds: max(0, summary.weeklyDurationSeconds)), "合計時間")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .pulseGlass(level: .hero, cornerRadius: AppTheme.heroRadius, padding: 0)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.title3.weight(.bold)).foregroundStyle(.primary)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Exercise progress

    private var exerciseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            PulseSectionHeader("種目の進捗", icon: "chart.line.uptrend.xyaxis")
            VStack(spacing: 12) {
                ForEach(insights) { insight in
                    exerciseRow(insight)
                }
            }
        }
    }

    private func exerciseRow(_ insight: ExerciseProgressInsight) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(insight.exerciseName)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                trendTag(insight.trend)
            }
            HStack(spacing: 8) {
                metaLabel("最新", repsText(insight.latestReps))
                if let previous = insight.previousReps {
                    metaLabel("前回", repsText(previous))
                }
                Spacer(minLength: 8)
                Text("最多 \(insight.personalBestReps) 回")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(AppTheme.accentSoft))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .pulseCard()
    }

    private func repsText(_ reps: [Int]) -> String {
        reps.map(String.init).joined(separator: " / ") + " 回"
    }

    private func metaLabel(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(value).font(.caption).foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func trendTag(_ trend: ExerciseProgressInsight.Trend) -> some View {
        switch trend {
        case .up:
            tag("上昇", "arrow.up.right", .green)
        case .down:
            tag("低下", "arrow.down.right", .orange)
        case .flat:
            tag("維持", "arrow.right", .secondary)
        case .unknown:
            EmptyView()
        }
    }

    private func tag(_ text: String, _ icon: String, _ color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
    }

    // MARK: - Empty

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("まだトレーニング記録がありません", systemImage: "sparkles")
                .font(.headline)
            Text("ワークアウトを完了すると、今週の実績や種目ごとの進捗がここに表示されます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .pulseCard()
    }
}
