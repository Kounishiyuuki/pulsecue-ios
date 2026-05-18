//
//  HealthTargetWeeklyAverage.swift
//  Pulse Cue
//
//  Pure helper that computes the average resolved health target over
//  a rolling N-day window ending at a given day.
//
//  Why a separate type:
//   - HealthSummary surfaces *weekly habits* (PR #38), so it needs to
//     compare the user's 7-day average against the *average target*
//     for those same 7 days — not just today's resolved target.
//   - Target resolution for each date walks the full priority chain
//     (date override → weekday override → default → nil), which means
//     two days in the same week can land on different target values
//     (e.g. a weekday override on Monday + a date override on
//     Saturday). Averaging the resolved targets keeps the surfaced
//     "weekly target" honest.
//   - Stays pure (no SwiftUI / SwiftData / UserDefaults) so tests can
//     pin date / settings / window-size combinations.
//
//  Rule of thumb (locked by tests):
//   - For each day in `[endDate - (windowDays-1), endDate]`:
//       - resolve the target via HealthTargetResolver.
//       - if non-nil, include in the sum.
//   - Return floor(sum / count). Nil when no day resolves to a value.
//
//  Integer arithmetic matches the rest of the app — DayLog stores
//  values as Int and HealthSummary's other averages also use integer
//  division.
//

import Foundation

enum HealthTargetWeeklyAverage {

    /// Default 7-day window matches `HealthSummary.windowDays = 7`.
    static let defaultWindowDays: Int = 7

    /// Average resolved target for `metric` across the inclusive
    /// window `[endDate - (windowDays-1), endDate]`. Returns nil when
    /// no day in the window has a configured target.
    static func averageTarget(
        metric: HealthTargetMetric,
        endingAt endDate: Date,
        windowDays: Int = defaultWindowDays,
        settings: HealthTargetSettings,
        calendar: Calendar = .current,
    ) -> Int? {
        let days = max(1, windowDays)
        let end = calendar.startOfDay(for: endDate)
        var values: [Int] = []
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: end) else { continue }
            if let target = HealthTargetResolver.resolve(
                metric: metric,
                date: day,
                settings: settings,
                calendar: calendar
            ) {
                values.append(target)
            }
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / values.count
    }
}
