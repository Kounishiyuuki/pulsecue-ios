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

    @State private var dayLog: DayLog?
    @State private var activeField: DayLogField?
    @State private var showRoutinePicker = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                workoutCard
                nutritionCard
                sleepCard
                weightCard
                balanceCard
            }
            .padding()
        }
        .navigationTitle("今日")
        .sheet(item: $activeField) { field in
            if let dayLog {
                DayLogQuickInputSheet(field: field, dayLog: dayLog)
            }
        }
        .sheet(isPresented: $showRoutinePicker) {
            RoutinePickerSheet()
        }
        .onAppear {
            loadDayLog()
        }
    }

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
        InfoCard(
            title: "栄養",
            subtitle: dayLog?.intakeCalories == nil ? "未入力" : "\(dayLog?.intakeCalories ?? 0) kcal",
            isMissing: dayLog?.intakeCalories == nil,
            actionTitle: "入力"
        ) {
            activeField = .nutrition
        } content: {
            Text("摂取カロリーをすばやく入力")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var sleepCard: some View {
        InfoCard(
            title: "睡眠",
            subtitle: dayLog?.sleepMinutes == nil ? "未入力" : "\(dayLog?.sleepMinutes ?? 0) 分",
            isMissing: dayLog?.sleepMinutes == nil,
            actionTitle: "入力"
        ) {
            activeField = .sleep
        } content: {
            Text("睡眠時間を記録")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var weightCard: some View {
        InfoCard(
            title: "体重",
            subtitle: dayLog?.weightKg == nil ? "未入力" : "\(formattedWeight) kg",
            isMissing: dayLog?.weightKg == nil,
            actionTitle: "入力"
        ) {
            activeField = .weight
        } content: {
            Text("今日の体重")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var balanceCard: some View {
        let intake = dayLog?.intakeCalories ?? 0
        let exercise = dayLog?.exerciseCalories ?? 0
        let balance = intake - exercise
        return InfoCard(
            title: "バランス",
            subtitle: "\(balance) kcal",
            isMissing: dayLog?.intakeCalories == nil && dayLog?.exerciseCalories == nil,
            actionTitle: "入力"
        ) {
            activeField = .workout
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                Text("摂取 \(intake) kcal")
                Text("消費 \(exercise) kcal")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var formattedWeight: String {
        guard let weight = dayLog?.weightKg else { return "0" }
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: weight)) ?? String(format: "%.1f", weight)
    }

    private func loadDayLog() {
        let today = DateUtils.startOfDay(Date())
        let descriptor = FetchDescriptor<DayLog>(predicate: #Predicate<DayLog> { $0.date == today })
        if let existing = try? modelContext.fetch(descriptor).first {
            dayLog = existing
        } else {
            let newLog = DayLog(date: today)
            modelContext.insert(newLog)
            dayLog = newLog
        }
    }
}
