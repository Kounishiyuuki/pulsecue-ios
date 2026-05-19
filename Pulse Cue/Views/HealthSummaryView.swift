//
//  HealthSummaryView.swift
//  Pulse Cue
//
//  Created by Codex.
//

import SwiftUI
import SwiftData

struct HealthSummaryView: View {
    @Query private var recentLogs: [DayLog]
    @Query(sort: [SortDescriptor(\UserProfile.updatedAt, order: .reverse)])
    private var profiles: [UserProfile]
    @StateObject private var targetStore = HealthTargetStore()

    init() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -29, to: today) ?? today
        self._recentLogs = Query(
            filter: #Predicate<DayLog> { $0.date >= start },
            sort: [SortDescriptor(\DayLog.date, order: .reverse)]
        )
    }

    private var summary: HealthSummary {
        HealthSummary(logs: recentLogs)
    }

    /// Average resolved target for each metric over the same 7-day
    /// window HealthSummary uses for its weekly averages. Nil entries
    /// mean the user has no configured target for the metric anywhere
    /// in the window — the UI then preserves the prior "no target"
    /// display for that row.
    private func weeklyAverageTarget(for metric: HealthTargetMetric) -> Int? {
        HealthTargetWeeklyAverage.averageTarget(
            metric: metric,
            endingAt: Date(),
            settings: targetStore.settings
        )
    }

    var body: some View {
        List {
            todaySection
            weeklySection
            weightSection
            nutritionSection
            aiCoachSection
            footerSection
        }
        .navigationTitle("健康サマリー")
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .listStyle(.insetGrouped)
    }

    private var todaySection: some View {
        Section("今日") {
            row(label: "摂取カロリー", value: summary.todayIntake.map { "\($0) kcal" })
            row(label: "運動消費", value: summary.todayExercise.map { "\($0) kcal" })
            row(label: "バランス", value: summary.todayBalance.map { "\($0) kcal" })
            row(label: "睡眠", value: summary.todaySleepMinutes.map { formatSleep(minutes: $0) })
            row(label: "体重", value: summary.todayWeight.map { "\(formatWeight($0)) kg" })
        }
    }

    private var weeklySection: some View {
        Section {
            weeklyRow(
                label: "摂取カロリー",
                actual: summary.weeklyIntakeAverage,
                target: weeklyAverageTarget(for: .intakeCalories),
                style: .kcal
            )
            weeklyRow(
                label: "運動消費",
                actual: summary.weeklyExerciseAverage,
                target: weeklyAverageTarget(for: .exerciseCalories),
                style: .kcal
            )
            weeklyRow(
                label: "バランス",
                actual: summary.weeklyBalanceAverage,
                target: weeklyAverageTarget(for: .balanceCalories),
                style: .kcal
            )
            weeklyRow(
                label: "睡眠",
                actual: summary.weeklySleepAverage,
                target: weeklyAverageTarget(for: .sleepMinutes),
                style: .sleep
            )
        } header: {
            Text("過去 7 日の平均（目安）")
        } footer: {
            Text("目標は曜日・日付の上書きを含む 7 日間の平均と比較しています。3 日以上の入力が必要です。")
        }
    }

    private enum WeeklyRowStyle { case kcal, sleep }

    private func weeklyDifference(actual: Int?, target: Int?, style: WeeklyRowStyle) -> HealthTargetDifference.Result? {
        switch style {
        case .kcal: return HealthTargetDifference.formatKcal(current: actual, target: target)
        case .sleep: return HealthTargetDifference.formatSleepMinutes(current: actual, target: target)
        }
    }

    /// Single row in the weekly section. When both an actual average
    /// and a target average are available, surfaces a second line
    /// with target + signed difference. Falls back to the legacy
    /// "average value only" row when targets aren't configured for the
    /// metric anywhere in the 7-day window.
    private func weeklyRow(
        label: String,
        actual: Int?,
        target: Int?,
        style: WeeklyRowStyle
    ) -> some View {
        let actualText = actual.map { formatActual($0, style: style) }
        let diff = weeklyDifference(actual: actual, target: target, style: style)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(actualText ?? "—")
                    .foregroundStyle(actualText == nil ? Color.secondary.opacity(0.6) : .secondary)
            }
            if let target, let diff {
                HStack(spacing: 6) {
                    Image(systemName: targetIcon(diff.direction))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(targetColor(diff.direction))
                    Text("目標 \(formatActual(target, style: style))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(diff.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(targetColor(diff.direction))
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(label) 目標 \(formatActual(target, style: style))、\(diff.label)")
            }
        }
    }

    private func formatActual(_ value: Int, style: WeeklyRowStyle) -> String {
        switch style {
        case .kcal: return "\(value) kcal/日"
        case .sleep: return formatSleep(minutes: value)
        }
    }

    private func targetColor(_ direction: HealthTargetDifference.Direction) -> Color {
        switch direction {
        case .onTarget: return .green
        case .over: return .orange
        case .under: return Color(red: 0.27, green: 0.62, blue: 0.95)
        }
    }

    private func targetIcon(_ direction: HealthTargetDifference.Direction) -> String {
        switch direction {
        case .onTarget: return "checkmark.circle.fill"
        case .over: return "arrow.up.circle.fill"
        case .under: return "arrow.down.circle.fill"
        }
    }

    private var weightSection: some View {
        Section {
            row(label: "最新", value: summary.latestWeight.map { "\(formatWeight($0)) kg" })
            row(label: "7日移動平均", value: summary.weightMovingAverage.map { "\(formatWeight($0)) kg" })
            if let trend = summary.weightTrend {
                HStack {
                    Text("トレンド")
                    Spacer()
                    Label(trend.label, systemImage: trend.systemImage)
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                }
            } else {
                row(label: "トレンド", value: nil)
            }

            if let goalRow = weightGoalRow() {
                goalRow
            }
            if let changeRow = weightPreviousChangeRow() {
                changeRow
            }
        } header: {
            Text("体重（目安）")
        } footer: {
            Text("傾向は直近 7 日のうち 4 日以上の入力で計算されます。前回比は直近 2 回の体重入力から算出します。")
        }
    }

    /// "目標 65.0 kg" + 「目標まで あと X kg」 row. Hidden when no
    /// latest weight or no goal weight is set, preserving the prior
    /// "no target" display rule.
    private func weightGoalRow() -> AnyView? {
        guard let current = summary.latestWeight,
              let profile = profiles.first,
              let diff = WeightTargetDifference.goalDifference(
                current: current,
                goal: profile.goalWeightKg
              ) else {
            return nil
        }
        let view = HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("目標体重")
                Text("目標 \(formatWeight(profile.goalWeightKg)) kg")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(diff.label, systemImage: trendIcon(diff.direction))
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(trendColor(diff.direction))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("目標体重 \(formatWeight(profile.goalWeightKg)) kg、\(diff.label)")
        return AnyView(view)
    }

    /// "前回比 ±X kg" row. Hidden when fewer than 2 weight entries
    /// are available, so the trend doesn't surface for a brand-new
    /// user with a single weigh-in.
    private func weightPreviousChangeRow() -> AnyView? {
        guard let diff = WeightTargetDifference.previousChange(
            latest: summary.latestWeight,
            previous: summary.previousLoggedWeight
        ) else { return nil }
        let view = HStack {
            Text("前回比")
            Spacer()
            Label(diff.label, systemImage: trendIcon(diff.direction))
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(trendColor(diff.direction))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(diff.label)
        return AnyView(view)
    }

    private func trendIcon(_ direction: HealthTargetDifference.Direction) -> String {
        // Weight wording is neutral (cut vs bulk both legitimate), so
        // we reuse the same arrow icons as the rest of the app but
        // never tint "down = good".
        switch direction {
        case .onTarget: return "equal.circle.fill"
        case .over: return "arrow.up.circle.fill"
        case .under: return "arrow.down.circle.fill"
        }
    }

    private func trendColor(_ direction: HealthTargetDifference.Direction) -> Color {
        switch direction {
        case .onTarget: return .green
        case .over, .under: return .secondary
        }
    }

    private var nutritionSection: some View {
        Section {
            NavigationLink {
                NutritionView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "fork.knife")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("食事ログを開く")
                            .font(.subheadline.weight(.semibold))
                        Text("朝昼夕間食の記録と AI 推定の確認待ち。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .accessibilityLabel("食事ログを開く")
        } header: {
            Text("栄養 / 食事ログ")
        } footer: {
            Text("確定した食事だけが今日の摂取カロリーに加算されます。")
        }
    }

    private var aiCoachSection: some View {
        Section {
            NavigationLink {
                AICoachView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI コーチを開く")
                            .font(.subheadline.weight(.semibold))
                        Text("オンデバイスの目安提案。AI 機能は現在オフ。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .accessibilityLabel("AI コーチを開く")
        } header: {
            Text("AI コーチ（プレビュー）")
        } footer: {
            Text("ローカルで生成された提案目安です。医学的な助言ではありません。")
        }
    }

    private var footerSection: some View {
        Section {
            HStack {
                Text("入力済みの日数")
                Spacer()
                Text("\(summary.filledDayCount) / 7 日")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("これらの値はオフラインで端末内のみで計算された目安です。HealthKit や同期は P0 範囲外です。")
        }
    }

    private func row(label: String, value: String?) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value ?? "—")
                .foregroundStyle(value == nil ? Color.secondary.opacity(0.6) : .secondary)
        }
    }

    private func formatSleep(minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 && m > 0 { return "\(h)時間\(m)分" }
        if h > 0 { return "\(h)時間" }
        return "\(m)分"
    }

    private func formatWeight(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }
}
