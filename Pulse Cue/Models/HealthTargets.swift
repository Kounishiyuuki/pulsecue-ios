//
//  HealthTargets.swift
//  Pulse Cue
//
//  Value types for the health-target settings foundation.
//
//  The model captures four user-tunable per-day targets:
//    - intakeCalories  (kcal/day)
//    - sleepMinutes    (minutes/day)
//    - exerciseCalories (kcal/day, energy burned via workouts)
//    - balanceCalories (kcal/day, intake - exercise)
//
//  Each field is optional so a partially configured target set is
//  representable: e.g. the user might only care about sleep + intake
//  on weekdays and let exercise stay unset.
//
//  Types intentionally do NOT touch SwiftData. They are pure Codable
//  values and live entirely behind `HealthTargetStore` (UserDefaults
//  backed) and `HealthTargetResolver` (pure resolver). This keeps the
//  PR additive and avoids a schema migration.
//

import Foundation

/// Identifier for one of the four supported target metrics. Used by
/// `HealthTargetResolver` to surface a single resolved Int value per
/// metric without forcing callers to know the underlying field names.
enum HealthTargetMetric: String, CaseIterable, Codable, Hashable, Identifiable {
    case intakeCalories
    case sleepMinutes
    case exerciseCalories
    case balanceCalories

    var id: String { rawValue }

    /// Human-readable Japanese label used by the Settings UI.
    var label: String {
        switch self {
        case .intakeCalories: return "摂取カロリー"
        case .sleepMinutes: return "睡眠"
        case .exerciseCalories: return "運動消費カロリー"
        case .balanceCalories: return "カロリーバランス"
        }
    }

    /// Unit suffix shown next to the value.
    var unit: String {
        switch self {
        case .intakeCalories, .exerciseCalories, .balanceCalories: return "kcal"
        case .sleepMinutes: return "分"
        }
    }
}

/// A bag of per-metric target values. Each field is optional so a
/// caller can set only the metrics it cares about; missing fields fall
/// through to the next layer in `HealthTargetResolver`.
struct HealthTargets: Codable, Equatable, Hashable {
    var intakeCalories: Int?
    var sleepMinutes: Int?
    var exerciseCalories: Int?
    var balanceCalories: Int?

    init(
        intakeCalories: Int? = nil,
        sleepMinutes: Int? = nil,
        exerciseCalories: Int? = nil,
        balanceCalories: Int? = nil,
    ) {
        self.intakeCalories = intakeCalories
        self.sleepMinutes = sleepMinutes
        self.exerciseCalories = exerciseCalories
        self.balanceCalories = balanceCalories
    }

    /// Returns the configured value for the given metric, or nil when
    /// the field is unset on this target set.
    func value(for metric: HealthTargetMetric) -> Int? {
        switch metric {
        case .intakeCalories: return intakeCalories
        case .sleepMinutes: return sleepMinutes
        case .exerciseCalories: return exerciseCalories
        case .balanceCalories: return balanceCalories
        }
    }

    /// Non-mutating copy with `metric` set to `value` (or cleared when
    /// `value` is nil). Used by the Settings UI which works through
    /// SwiftUI bindings against immutable view models.
    func setting(_ value: Int?, for metric: HealthTargetMetric) -> HealthTargets {
        var copy = self
        switch metric {
        case .intakeCalories: copy.intakeCalories = value
        case .sleepMinutes: copy.sleepMinutes = value
        case .exerciseCalories: copy.exerciseCalories = value
        case .balanceCalories: copy.balanceCalories = value
        }
        return copy
    }

    /// True when no metric is configured.
    var isEmpty: Bool {
        intakeCalories == nil
            && sleepMinutes == nil
            && exerciseCalories == nil
            && balanceCalories == nil
    }
}

/// Local-calendar weekday. Stored as the raw integer used by
/// `Calendar.component(.weekday, from:)` so resolver lookups don't
/// need an extra mapping step. (Apple's convention: Sunday = 1.)
enum HealthTargetWeekday: Int, CaseIterable, Codable, Hashable, Identifiable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    var id: Int { rawValue }

    /// Short Japanese label, matching the kanji used elsewhere in the
    /// app (e.g. Today / History headers).
    var shortLabel: String {
        switch self {
        case .sunday: return "日"
        case .monday: return "月"
        case .tuesday: return "火"
        case .wednesday: return "水"
        case .thursday: return "木"
        case .friday: return "金"
        case .saturday: return "土"
        }
    }

    /// Convenience constructor from a `Date` in the current calendar.
    static func from(_ date: Date, calendar: Calendar = .current) -> HealthTargetWeekday {
        let weekday = calendar.component(.weekday, from: date)
        return HealthTargetWeekday(rawValue: weekday) ?? .sunday
    }
}

/// Full target configuration: defaults plus optional weekday and
/// date-specific overrides. Resolved at read-time by
/// `HealthTargetResolver` using the documented priority chain.
struct HealthTargetSettings: Codable, Equatable {

    /// Default targets applied to any day with no override.
    var defaults: HealthTargets

    /// Per-weekday overrides. Each weekday may shadow some or all of
    /// the default fields.
    var weekdayOverrides: [HealthTargetWeekday: HealthTargets]

    /// Per-date overrides, keyed by `startOfDay`. Wins over both
    /// weekday and defaults. Values without a matching date entry
    /// fall through to weekday/default lookups.
    ///
    /// Note: stored as `[Date: HealthTargets]` so the value type stays
    /// pure Swift. Encoding/decoding goes through a wrapper in
    /// `HealthTargetStore` to keep the JSON shape stable.
    var dateOverrides: [Date: HealthTargets]

    init(
        defaults: HealthTargets = HealthTargets(),
        weekdayOverrides: [HealthTargetWeekday: HealthTargets] = [:],
        dateOverrides: [Date: HealthTargets] = [:],
    ) {
        self.defaults = defaults
        self.weekdayOverrides = weekdayOverrides
        self.dateOverrides = dateOverrides
    }

    static let empty = HealthTargetSettings()
}
