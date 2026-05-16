//
//  TodayView.swift
//  Pulse Cue
//
//  Created by Codex.
//
//  Premium liquid-glass dashboard. Layout:
//  - Hero card: PulseCue mark + 今日の状態 + コンディション (derived
//    from how many of today's four DayLog fields are filled).
//  - ワークアウトを開始 / 再開: prominent gradient button, the day's
//    primary call-to-action.
//  - 2×2 frosted metric grid: 摂取 / 消費 / 睡眠 / 体重. Missing
//    fields surface as a small red dot + "入力 +" inside the card.
//  - バランスカード: today's balance (intake − exercise) + 7-day
//    average + 3-segment proportional bar (食事 / 運動 / 休息) +
//    "週間サマリーを見る →" link.
//
//  All existing functions are preserved: quick-input sheet on tap,
//  `@Query`-driven instant updates, `DayLogStore.fetchOrCreateToday`
//  guarantees one record per local date, runner resume routes to the
//  Runner tab.
//

import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var runnerViewModel: RunnerViewModel
    @EnvironmentObject var settings: SettingsStore
    @Binding var selectedTab: AppTab

    @Query private var recentLogs: [DayLog]
    @Query(sort: [SortDescriptor(\UserProfile.updatedAt, order: .reverse)])
    private var profiles: [UserProfile]

    @State private var activeField: DayLogField?
    @State private var showRoutinePicker = false

    init(selectedTab: Binding<AppTab>) {
        self._selectedTab = selectedTab
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -13, to: today) ?? today
        self._recentLogs = Query(
            filter: #Predicate<DayLog> { $0.date >= start },
            sort: [SortDescriptor(\DayLog.date, order: .reverse)]
        )
    }

    private var summary: HealthSummary {
        HealthSummary(logs: recentLogs)
    }

    private var todayLog: DayLog? { summary.todayLog }

    var body: some View {
        ZStack {
            backgroundLayer.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    heroCard
                    startWorkoutButton
                    TodayGymPlanCard()
                    metricsGrid
                    nutritionLogLink
                    balanceCard
                    Color.clear.frame(height: 12)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
        }
        .navigationTitle("今日")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activeField) { field in
            if let dayLog = todayLog {
                DayLogQuickInputSheet(field: field, dayLog: dayLog)
            }
        }
        .sheet(isPresented: $showRoutinePicker) {
            RoutinePickerSheet()
        }
        .task {
            ensureTodayLogExists()
            _ = UserProfileStore.fetchOrCreate(modelContext: modelContext)
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

    // MARK: - Hero card

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(accentGradient)
                        .frame(width: 36, height: 36)
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text("PulseCue")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "bell")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("今日の状態")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(conditionHeadline)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(accentGradient)
                    Text(conditionSubhead)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("コンディション")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text("\(filledMetricCount)")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text("/ 4")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.regularMaterial)
                )

                Spacer()

                ZStack {
                    Circle()
                        .stroke(accentGradient, lineWidth: 4)
                        .frame(width: 56, height: 56)
                    Circle()
                        .fill(accentGradient.opacity(0.12))
                        .frame(width: 48, height: 48)
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(accentGradient)
                }
                .accessibilityHidden(true)
            }
        }
        .padding(20)
        .background(glassBackground)
        .overlay(glassStroke)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("今日の状態 \(conditionHeadline). コンディション \(filledMetricCount) / 4 入力済み")
    }

    private var conditionHeadline: String {
        switch filledMetricCount {
        case 4: return "Excellent"
        case 3: return "Good"
        case 2: return "Steady"
        case 1: return "Starting"
        default: return "—"
        }
    }

    private var conditionSubhead: String {
        switch filledMetricCount {
        case 4: return "本日の記録 完了"
        case 3: return "あと 1 項目"
        case 2: return "入力中"
        case 1: return "入力を続けましょう"
        default: return "今日の記録を始めましょう"
        }
    }

    private var filledMetricCount: Int {
        guard let log = todayLog else { return 0 }
        var count = 0
        if log.intakeCalories != nil { count += 1 }
        if log.exerciseCalories != nil { count += 1 }
        if log.sleepMinutes != nil { count += 1 }
        if log.weightKg != nil { count += 1 }
        return count
    }

    // MARK: - Workout button

    private var startWorkoutButton: some View {
        Button(action: workoutAction) {
            HStack(spacing: 12) {
                Image(systemName: runnerViewModel.isRunning ? "figure.run" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                Text(workoutButtonTitle)
                    .font(.headline)
                Spacer(minLength: 0)
                if runnerViewModel.isRunning, let step = runnerViewModel.currentStep {
                    Text("\(step.title)・\(runnerViewModel.currentSetIndex + 1)/\(step.sets)")
                        .font(.caption)
                        .opacity(0.85)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
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
        .accessibilityLabel(runnerViewModel.isRunning ? "実行中のセッションを再開" : "ワークアウトを開始")
    }

    private var workoutButtonTitle: String {
        runnerViewModel.isRunning ? "ワークアウトを再開" : "ワークアウトを開始"
    }

    private func workoutAction() {
        if runnerViewModel.isRunning {
            selectedTab = .runner
        } else {
            showRoutinePicker = true
        }
    }

    // MARK: - Nutrition log shortcut

    /// Direct entry to the full Nutrition / meal-log screen.
    /// Independent from the 摂取 metric card so the existing quick
    /// calorie input (DayLogQuickInputSheet) is fully preserved.
    private var nutritionLogLink: some View {
        NavigationLink {
            NutritionView()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(accentGradient.opacity(0.16))
                        .frame(width: 38, height: 38)
                    Image(systemName: "fork.knife")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(accentGradient)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("食事ログ")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                    Text("朝昼夕・間食を記録 / AI 推定を確認")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(glassBackground)
            .overlay(glassStroke)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("食事ログを開く")
        .accessibilityHint("朝昼夕食と間食の記録、AI 推定の確認待ち画面に移動")
    }

    // MARK: - Metrics grid

    private var metricsGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
        return LazyVGrid(columns: columns, spacing: 12) {
            metricCard(
                icon: "fork.knife",
                title: "摂取",
                value: todayLog?.intakeCalories.map { formatInt($0) },
                unit: "kcal",
                accent: Color(red: 0.32, green: 0.66, blue: 0.97),
                field: .nutrition
            )
            metricCard(
                icon: "flame.fill",
                title: "消費",
                value: todayLog?.exerciseCalories.map { formatInt($0) },
                unit: "kcal",
                accent: Color(red: 0.41, green: 0.56, blue: 0.96),
                field: .workout
            )
            metricCard(
                icon: "moon.fill",
                title: "睡眠",
                value: todayLog?.sleepMinutes.map { formatSleep(minutes: $0) },
                unit: nil,
                accent: Color(red: 0.49, green: 0.45, blue: 0.97),
                field: .sleep
            )
            metricCard(
                icon: "scalemass.fill",
                title: "体重",
                value: todayLog?.weightKg.map { formatWeight($0) },
                unit: "kg",
                accent: Color(red: 0.67, green: 0.45, blue: 0.96),
                field: .weight
            )
        }
    }

    private func metricCard(
        icon: String,
        title: String,
        value: String?,
        unit: String?,
        accent: Color,
        field: DayLogField
    ) -> some View {
        let isMissing = (value == nil)
        return Button {
            openField(field)
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

                if let value = value {
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(value)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if let unit = unit {
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 110)
            .padding(14)
            .background(glassBackground)
            .overlay(glassStroke)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(metricAccessibilityLabel(title: title, value: value, unit: unit))
    }

    private func metricAccessibilityLabel(title: String, value: String?, unit: String?) -> String {
        if let value {
            return "\(title) \(value)\(unit ?? "")"
        }
        return "\(title) 未入力"
    }

    // MARK: - Balance card

    private var balanceCard: some View {
        let intake = todayLog?.intakeCalories ?? 0
        let exercise = todayLog?.exerciseCalories ?? 0
        let sleep = todayLog?.sleepMinutes ?? 0
        let balance = intake - exercise
        let isMissing = todayLog?.intakeCalories == nil && todayLog?.exerciseCalories == nil

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("バランス")
                    .font(.headline)
                Spacer()
                NavigationLink {
                    HealthSummaryView()
                } label: {
                    HStack(spacing: 4) {
                        Text("週間サマリーを見る")
                            .font(.subheadline.weight(.medium))
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(accentGradient)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("週間サマリーを見る")
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if isMissing {
                    Text("未入力")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    Text(formatInt(balance))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("kcal")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let weeklyAvg = summary.weeklyBalanceAverage {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("7日平均")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(formatInt(weeklyAvg)) kcal")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }

            if let gap = goalGap(intake: todayLog?.intakeCalories) {
                goalGapRow(gap: gap)
            }

            balanceBar(intake: intake, exercise: exercise, sleep: sleep)

            HStack(spacing: 14) {
                legend("食事", color: Color(red: 0.32, green: 0.66, blue: 0.97))
                legend("運動", color: Color(red: 0.49, green: 0.51, blue: 0.97))
                legend("休息", color: Color(red: 0.67, green: 0.45, blue: 0.96))
            }
            .font(.caption)
        }
        .padding(20)
        .background(glassBackground)
        .overlay(glassStroke)
    }

    /// Today's intake-vs-target gap derived from the canonical
    /// `UserProfile`, or nil when the user hasn't entered an intake
    /// or we can't compute a target yet (e.g. weight unknown / profile
    /// not yet created).
    private func goalGap(intake: Int?) -> Int? {
        guard let intake, let profile = profiles.first else { return nil }
        return profile.todayGoalGap(
            todayIntake: intake,
            currentWeightKg: summary.latestWeight
        )
    }

    private func goalGapRow(gap: Int) -> some View {
        let isOver = gap > 0
        let withinBand = abs(gap) <= 100
        let color: Color = withinBand
            ? .green
            : (isOver ? .orange : Color(red: 0.27, green: 0.62, blue: 0.95))
        let label: String = withinBand
            ? "目標 範囲内"
            : (isOver ? "目標から +\(formatInt(gap)) kcal" : "目標まで \(formatInt(gap)) kcal")
        let icon: String = withinBand
            ? "checkmark.circle.fill"
            : (isOver ? "arrow.up.circle.fill" : "arrow.down.circle.fill")

        return HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Spacer(minLength: 0)
            Text("目標は 設定 → 目標設定")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(0.10))
        )
        .accessibilityLabel("今日の目標差分 \(label)")
    }

    private func balanceBar(intake: Int, exercise: Int, sleep: Int) -> some View {
        // Three pillars normalized to a 0...1 score against soft daily
        // targets, then scaled to the bar width. Values are illustrative
        // — copy reads "目安" elsewhere — and are clamped to keep one
        // pillar from dominating the bar.
        let foodScore = min(1.0, Double(intake) / 2000.0)
        let exerciseScore = min(1.0, Double(exercise) / 400.0)
        let restScore = min(1.0, Double(sleep) / 480.0)
        let total = max(0.001, foodScore + exerciseScore + restScore)

        return GeometryReader { geo in
            HStack(spacing: 4) {
                segment(width: geo.size.width * (foodScore / total),
                        color: Color(red: 0.32, green: 0.66, blue: 0.97))
                segment(width: geo.size.width * (exerciseScore / total),
                        color: Color(red: 0.49, green: 0.51, blue: 0.97))
                segment(width: geo.size.width * (restScore / total),
                        color: Color(red: 0.67, green: 0.45, blue: 0.96))
            }
        }
        .frame(height: 10)
    }

    private func segment(width: CGFloat, color: Color) -> some View {
        Capsule()
            .fill(color.opacity(0.75))
            .frame(width: max(2, width))
    }

    private func legend(_ text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).foregroundStyle(.secondary)
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

    // MARK: - Helpers

    private func formatInt(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formatSleep(minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    private func formatWeight(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }

    private func ensureTodayLogExists() {
        if todayLog == nil {
            _ = DayLogStore.fetchOrCreateToday(modelContext: modelContext)
        }
    }

    private func openField(_ field: DayLogField) {
        ensureTodayLogExists()
        activeField = field
    }
}
