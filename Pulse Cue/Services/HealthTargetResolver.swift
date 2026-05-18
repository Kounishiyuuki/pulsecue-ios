//
//  HealthTargetResolver.swift
//  Pulse Cue
//
//  Pure resolver that returns the effective target value for a given
//  date + metric, walking the documented priority chain:
//
//      1. date-specific override   (settings.dateOverrides[startOfDay])
//      2. weekday override         (settings.weekdayOverrides[weekday])
//      3. default target           (settings.defaults)
//      4. nil                      (no target configured)
//
//  Per-field resolution: each metric is resolved independently, so a
//  weekday override that only sets `sleepMinutes` does NOT shadow the
//  defaults' `intakeCalories`. This matches the user's example —
//  "sleep longer on some days" should not require restating every
//  other target value.
//
//  The resolver is intentionally side-effect free: no SwiftData, no
//  UserDefaults, no environment access. All state is passed in
//  explicitly so the tests can pin date / settings combinations.
//

import Foundation

enum HealthTargetResolver {

    /// Resolve a single metric for `date`. Returns nil when no layer
    /// configures the metric.
    static func resolve(
        metric: HealthTargetMetric,
        date: Date,
        settings: HealthTargetSettings,
        calendar: Calendar = .current,
    ) -> Int? {
        let day = calendar.startOfDay(for: date)

        if let dateOverride = settings.dateOverrides[day],
           let value = dateOverride.value(for: metric) {
            return value
        }

        let weekday = HealthTargetWeekday.from(date, calendar: calendar)
        if let weekdayOverride = settings.weekdayOverrides[weekday],
           let value = weekdayOverride.value(for: metric) {
            return value
        }

        return settings.defaults.value(for: metric)
    }

    /// Resolve every metric at once. Equivalent to calling `resolve`
    /// four times but returns a `HealthTargets` snapshot useful for
    /// the UI's "today's targets" row.
    static func resolveAll(
        date: Date,
        settings: HealthTargetSettings,
        calendar: Calendar = .current,
    ) -> HealthTargets {
        HealthTargets(
            intakeCalories: resolve(metric: .intakeCalories, date: date, settings: settings, calendar: calendar),
            sleepMinutes: resolve(metric: .sleepMinutes, date: date, settings: settings, calendar: calendar),
            exerciseCalories: resolve(metric: .exerciseCalories, date: date, settings: settings, calendar: calendar),
            balanceCalories: resolve(metric: .balanceCalories, date: date, settings: settings, calendar: calendar),
        )
    }

    /// Which resolution layer supplied the value for `metric` on
    /// `date`. Useful for the Settings UI to indicate "今日は 月曜
    /// 上書き" or "日付指定の上書きあり" hints. Returns `.none` when
    /// no layer configures the metric.
    static func layer(
        for metric: HealthTargetMetric,
        date: Date,
        settings: HealthTargetSettings,
        calendar: Calendar = .current,
    ) -> ResolutionLayer {
        let day = calendar.startOfDay(for: date)

        if let dateOverride = settings.dateOverrides[day],
           dateOverride.value(for: metric) != nil {
            return .dateOverride
        }

        let weekday = HealthTargetWeekday.from(date, calendar: calendar)
        if let weekdayOverride = settings.weekdayOverrides[weekday],
           weekdayOverride.value(for: metric) != nil {
            return .weekdayOverride
        }

        if settings.defaults.value(for: metric) != nil {
            return .defaultTarget
        }

        return .none
    }

    enum ResolutionLayer: String, Equatable {
        case dateOverride
        case weekdayOverride
        case defaultTarget
        case none
    }
}
