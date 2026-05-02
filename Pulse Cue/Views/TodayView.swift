//
//  TodayView.swift
//  Pulse Cue
//
//  Created by Codex.
//

import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var runnerViewModel: RunnerViewModel
    @Binding var selectedTab: AppTab

    @Query private var recentLogs: [DayLog]

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
        ScrollView {
            VStack(spacing: 16) {
                workoutCard
                nutritionCard
                exerciseCard
                sleepCard
                weightCard
                balanceCard
                healthSummaryLink
            }
            .padding()
        }
        .navigationTitle("今日")
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
        }
    }

    // MARK: Cards

    private var workoutCard: some View {
        InfoCard(
            title: "ワークアウト",
            subtitle: runnerViewModel.isRunning ? "進行中" : "準備完了",
            isMissing: !runnerViewModel.isRunning,
            actionTitle: runnerViewModel.isRunning ? "再開" : "開始"
        ) {
            if runnerViewModel.isRunning {
                selectedTab = .runner
            } else {
                showRoutinePicker = true
            }
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                if runnerViewModel.isRunning, let step = runnerViewModel.currentStep {
                    Text("今: \(step.title)")
                        .font(.subheadline)
                    Text("セット \(runnerViewModel.currentSetIndex + 1) / \(step.sets)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("進行中のセッションはありません")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var nutritionCard: some View {
        let intake = todayLog?.intakeCalories
        return InfoCard(
            title: "栄養",
            subtitle: intake.map { "\($0) kcal" } ?? "未入力",
            isMissing: intake == nil,
            actionTitle: intake == nil ? "入力" : "編集"
        ) {
            openField(.nutrition)
        } content: {
            Text("今日の摂取カロリーをすばやく入力")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var exerciseCard: some View {
        let exercise = todayLog?.exerciseCalories
        return InfoCard(
            title: "運動消費",
            subtitle: exercise.map { "\($0) kcal" } ?? "未入力",
            isMissing: exercise == nil,
            actionTitle: exercise == nil ? "入力" : "編集"
        ) {
            openField(.workout)
        } content: {
            Text("ワークアウトや活動による消費カロリーの目安")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var sleepCard: some View {
        let sleep = todayLog?.sleepMinutes
        return InfoCard(
            title: "睡眠",
            subtitle: sleep.map { formatSleep(minutes: $0) } ?? "未入力",
            isMissing: sleep == nil,
            actionTitle: sleep == nil ? "入力" : "編集"
        ) {
            openField(.sleep)
        } content: {
            Text("昨夜の睡眠時間を記録")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var weightCard: some View {
        let weight = todayLog?.weightKg
        return InfoCard(
            title: "体重",
            subtitle: weight.map { "\(formatWeight($0)) kg" } ?? "未入力",
            isMissing: weight == nil,
            actionTitle: weight == nil ? "入力" : "編集"
        ) {
            openField(.weight)
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                if let avg = summary.weightMovingAverage {
                    Text("7日平均: \(formatWeight(avg)) kg" + trendSuffix())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("今日の体重")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var balanceCard: some View {
        let intake = todayLog?.intakeCalories ?? 0
        let exercise = todayLog?.exerciseCalories ?? 0
        let balance = intake - exercise
        let isMissing = todayLog?.intakeCalories == nil && todayLog?.exerciseCalories == nil
        return InfoCard(
            title: "バランス（目安）",
            subtitle: isMissing ? "未入力" : "\(balance) kcal",
            isMissing: isMissing,
            actionTitle: nil,
            action: nil
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text("摂取 \(intake) kcal − 消費 \(exercise) kcal")
                if let weeklyAvg = summary.weeklyBalanceAverage {
                    Text("7日平均: \(weeklyAvg) kcal/日")
                } else {
                    Text("7日平均: データ不足")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var healthSummaryLink: some View {
        NavigationLink {
            HealthSummaryView()
        } label: {
            HStack {
                Label("週間サマリー", systemImage: "chart.bar.xaxis")
                    .font(.subheadline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Helpers

    private func trendSuffix() -> String {
        guard let trend = summary.weightTrend else { return "" }
        return "（\(trend.label)）"
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
