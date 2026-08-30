//
//  HomeMetricsGrid.swift
//  Pulse Cue
//
//  記録を入力 — the four quick inputs, with today's targets under each.
//
//  Presentation and target arithmetic only. It is handed the day's log, the
//  resolved targets and the shared nutrition summary; it holds no query and
//  writes nothing, so the grid cannot become a second opinion about what today
//  looks like.
//
//  The 摂取 card is the one to be careful with. It shows
//  `HomeIntakeTile.displayedKcal`, not `DayLog.intakeCalories`: on a day with
//  confirmed meals the stored field and the meal total are the same number
//  only while the ledger says so, and reading the field directly once left
//  Home showing two different intakes on one screen — with a tap that opened
//  an editor whose value nothing would display. Where manual entry would not
//  survive, the tile routes to Nutrition instead of offering the field.
//

import SwiftUI

struct HomeMetricsGrid: View {
    let todayLog: DayLog?
    let targets: HealthTargets
    let nutritionSummary: DailyNutritionSummary
    /// The long-running weight goal, from the profile. Weight is the one
    /// metric here without a *daily* target: `HealthTargets` has no entry for
    /// it, and inventing one would put two weight goals in the app.
    let goalWeightKg: Double?

    let onOpenNutrition: () -> Void
    let onOpenField: (DayLogField) -> Void

    var body: some View {
        let columns = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
        return LazyVGrid(columns: columns, spacing: 12) {
            metricCard(
                icon: "fork.knife",
                title: "摂取",
                value: HomeIntakeTile.displayedKcal(for: nutritionSummary)
                    .map { NumberFormat.int($0) },
                unit: "kcal",
                accent: Color(red: 0.32, green: 0.66, blue: 0.97),
                field: .nutrition,
                targetSubtitle: kcalSubtitle(
                    current: HomeIntakeTile.displayedKcal(for: nutritionSummary),
                    target: nutritionSummary.targetKcal
                ),
                action: HomeIntakeTile.opensNutrition(for: nutritionSummary)
                    ? onOpenNutrition
                    : nil,
                actionHint: HomeIntakeTile.accessibilityHint(for: nutritionSummary)
            )
            metricCard(
                icon: "flame.fill",
                title: "消費",
                value: todayLog?.exerciseCalories.map { NumberFormat.int($0) },
                unit: "kcal",
                accent: Color(red: 0.41, green: 0.56, blue: 0.96),
                field: .workout,
                targetSubtitle: kcalSubtitle(
                    current: todayLog?.exerciseCalories,
                    target: targets.exerciseCalories
                )
            )
            metricCard(
                icon: "moon.fill",
                title: "睡眠",
                value: todayLog?.sleepMinutes.map { NumberFormat.sleepDuration(minutes: $0) },
                unit: nil,
                accent: Color(red: 0.49, green: 0.45, blue: 0.97),
                field: .sleep,
                targetSubtitle: sleepSubtitle(
                    current: todayLog?.sleepMinutes,
                    target: targets.sleepMinutes
                )
            )
            metricCard(
                icon: "scalemass.fill",
                title: "体重",
                value: todayLog?.weightKg.map { NumberFormat.weight($0) },
                unit: "kg",
                accent: Color(red: 0.67, green: 0.45, blue: 0.96),
                field: .weight,
                targetSubtitle: weightGoalSubtitle
            )
        }
    }

    // MARK: - Subtitles

    /// "目標 X kcal · あと Y kcal". Nil when no target is configured or nothing
    /// is logged yet — the caller then shows no subtitle rather than a
    /// placeholder, because an unset target is not a target of zero.
    private func kcalSubtitle(current: Int?, target: Int?) -> TargetSubtitle? {
        guard let target,
              let diff = HealthTargetDifference.formatKcal(current: current, target: target)
        else { return nil }
        return TargetSubtitle(
            targetText: "目標 \(NumberFormat.int(target)) kcal",
            differenceText: diff.label,
            direction: diff.direction
        )
    }

    private func sleepSubtitle(current: Int?, target: Int?) -> TargetSubtitle? {
        guard let target,
              let diff = HealthTargetDifference.formatSleepMinutes(current: current, target: target)
        else { return nil }
        return TargetSubtitle(
            targetText: "目標 \(NumberFormat.sleepDuration(minutes: target))",
            differenceText: diff.label,
            direction: diff.direction
        )
    }

    private var weightGoalSubtitle: TargetSubtitle? {
        guard let current = todayLog?.weightKg,
              let goal = goalWeightKg,
              let diff = WeightTargetDifference.goalDifference(current: current, goal: goal)
        else { return nil }
        return TargetSubtitle(
            targetText: "目標 \(NumberFormat.weight(goal)) kg",
            differenceText: diff.label,
            direction: diff.direction
        )
    }

    /// Compact value object, so each card's call site does not repeat the
    /// optional handling.
    private struct TargetSubtitle {
        let targetText: String
        let differenceText: String
        let direction: HealthTargetDifference.Direction
    }

    // MARK: - Card

    private func metricCard(
        icon: String,
        title: String,
        value: String?,
        unit: String?,
        accent: Color,
        field: DayLogField,
        targetSubtitle: TargetSubtitle?,
        /// Overrides the default quick-input action. Used where manual entry
        /// would not be honoured.
        action: (() -> Void)? = nil,
        actionHint: String? = nil
    ) -> some View {
        let isMissing = (value == nil)
        return Button {
            if let action {
                action()
            } else {
                onOpenField(field)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    ZStack {
                        Circle()
                            .fill(accent.opacity(0.16))
                            .frame(width: 30, height: 30)
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(accent)
                    }
                    Spacer()
                    if isMissing {
                        Circle()
                            .fill(Color.red.opacity(0.75))
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                    }
                }

                Spacer(minLength: 8)

                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let value {
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(value)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if let unit {
                            Text(unit)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    HStack(spacing: 4) {
                        Text("入力")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(accent)
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                }

                if let targetSubtitle {
                    subtitleRow(targetSubtitle)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 110)
            .padding(14)
            .frostedCard()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            accessibilityLabel(title: title, value: value, unit: unit, subtitle: targetSubtitle)
        )
        .accessibilityHint(actionHint ?? "\(title)を入力")
    }

    @ViewBuilder
    private func subtitleRow(_ subtitle: TargetSubtitle) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(subtitle.targetText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 3) {
                Image(systemName: icon(subtitle.direction))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color(subtitle.direction))
                Text(subtitle.differenceText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color(subtitle.direction))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    private func color(_ direction: HealthTargetDifference.Direction) -> Color {
        switch direction {
        case .onTarget: return .green
        case .over: return .orange
        case .under: return Color(red: 0.27, green: 0.62, blue: 0.95)
        }
    }

    private func icon(_ direction: HealthTargetDifference.Direction) -> String {
        switch direction {
        case .onTarget: return "checkmark.circle.fill"
        case .over: return "arrow.up.circle.fill"
        case .under: return "arrow.down.circle.fill"
        }
    }

    private func accessibilityLabel(
        title: String,
        value: String?,
        unit: String?,
        subtitle: TargetSubtitle?
    ) -> String {
        let base: String
        if let value {
            base = "\(title) \(value)\(unit ?? "")"
        } else {
            base = "\(title) 未入力"
        }
        if let subtitle {
            return "\(base)、\(subtitle.targetText)、\(subtitle.differenceText)"
        }
        return base
    }
}
