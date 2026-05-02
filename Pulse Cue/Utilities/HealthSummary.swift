//
//  HealthSummary.swift
//  Pulse Cue
//
//  Created by Codex.
//

import Foundation

enum WeightTrend {
    case rising, flat, falling

    var label: String {
        switch self {
        case .rising: return "上昇傾向"
        case .flat: return "横ばい"
        case .falling: return "下降傾向"
        }
    }

    var systemImage: String {
        switch self {
        case .rising: return "arrow.up.right"
        case .flat: return "arrow.right"
        case .falling: return "arrow.down.right"
        }
    }
}

/// Computed view over recent DayLog records.
/// All numbers are simple, locally calculated estimates and should be
/// presented as such (`〜目安`).
///
/// `logs` must be sorted by `date` descending (most recent first).
struct HealthSummary {
    let logs: [DayLog]
    let today: Date
    let windowDays: Int
    let minCount: Int

    init(logs: [DayLog], now: Date = Date(), windowDays: Int = 7, minCount: Int = 3) {
        self.logs = logs
        self.today = DateUtils.startOfDay(now)
        self.windowDays = max(1, windowDays)
        self.minCount = max(1, minCount)
    }

    var todayLog: DayLog? {
        logs.first(where: { DateUtils.startOfDay($0.date) == today })
    }

    var todayBalance: Int? {
        guard let log = todayLog else { return nil }
        let intake = log.intakeCalories
        let exercise = log.exerciseCalories
        if intake == nil && exercise == nil { return nil }
        return (intake ?? 0) - (exercise ?? 0)
    }

    var todayIntake: Int? { todayLog?.intakeCalories }
    var todayExercise: Int? { todayLog?.exerciseCalories }
    var todaySleepMinutes: Int? { todayLog?.sleepMinutes }
    var todayWeight: Double? { todayLog?.weightKg }

    var weeklyIntakeAverage: Int? { averageInt(\.intakeCalories) }
    var weeklyExerciseAverage: Int? { averageInt(\.exerciseCalories) }
    var weeklySleepAverage: Int? { averageInt(\.sleepMinutes) }

    var weeklyBalanceAverage: Int? {
        let pairs: [Int] = windowLogs.compactMap { log in
            let intake = log.intakeCalories
            let exercise = log.exerciseCalories
            if intake == nil && exercise == nil { return nil }
            return (intake ?? 0) - (exercise ?? 0)
        }
        guard pairs.count >= minCount else { return nil }
        return pairs.reduce(0, +) / pairs.count
    }

    var latestWeight: Double? {
        logs.first(where: { $0.weightKg != nil })?.weightKg
    }

    /// 7-day moving average of weight, requires `minCount` weighed days inside the window.
    var weightMovingAverage: Double? {
        let weights = windowLogs.compactMap { $0.weightKg }
        guard weights.count >= minCount else { return nil }
        return weights.reduce(0, +) / Double(weights.count)
    }

    var weightTrend: WeightTrend? {
        let weights = windowLogs.compactMap { $0.weightKg }
        guard weights.count >= 4 else { return nil }
        // logs are descending: prefix is newer, suffix is older.
        let half = weights.count / 2
        let newer = Array(weights.prefix(half))
        let older = Array(weights.suffix(half))
        guard !newer.isEmpty, !older.isEmpty else { return nil }
        let avgNewer = newer.reduce(0, +) / Double(newer.count)
        let avgOlder = older.reduce(0, +) / Double(older.count)
        let delta = avgNewer - avgOlder
        if abs(delta) < 0.2 { return .flat }
        return delta > 0 ? .rising : .falling
    }

    /// Number of days with any input inside the window.
    var filledDayCount: Int {
        windowLogs.reduce(0) { acc, log in
            let any = log.intakeCalories != nil
                || log.exerciseCalories != nil
                || log.sleepMinutes != nil
                || log.weightKg != nil
            return acc + (any ? 1 : 0)
        }
    }

    /// Logs that fall inside the rolling window ending at `today`.
    var windowLogs: [DayLog] {
        guard let start = Calendar.current.date(byAdding: .day, value: -(windowDays - 1), to: today) else {
            return logs
        }
        return logs.filter { log in
            let day = DateUtils.startOfDay(log.date)
            return day >= start && day <= today
        }
    }

    private func averageInt(_ keyPath: KeyPath<DayLog, Int?>) -> Int? {
        let values = windowLogs.compactMap { $0[keyPath: keyPath] }
        guard values.count >= minCount else { return nil }
        return values.reduce(0, +) / values.count
    }
}
