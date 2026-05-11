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

    var body: some View {
        List {
            todaySection
            weeklySection
            weightSection
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
            row(label: "摂取カロリー", value: summary.weeklyIntakeAverage.map { "\($0) kcal/日" })
            row(label: "運動消費", value: summary.weeklyExerciseAverage.map { "\($0) kcal/日" })
            row(label: "バランス", value: summary.weeklyBalanceAverage.map { "\($0) kcal/日" })
            row(label: "睡眠", value: summary.weeklySleepAverage.map { formatSleep(minutes: $0) })
        } header: {
            Text("過去 7 日の平均（目安）")
        } footer: {
            Text("入力日数が少ないと表示されません。3 日以上のデータが必要です。")
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
        } header: {
            Text("体重（目安）")
        } footer: {
            Text("傾向は直近 7 日のうち 4 日以上の入力で計算されます。")
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
