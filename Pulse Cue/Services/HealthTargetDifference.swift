//
//  HealthTargetDifference.swift
//  Pulse Cue
//
//  Pure formatter that turns a current value + target value into the
//  Japanese difference text shown on Today cards.
//
//  Why a separate type:
//   - TodayView already has a lot of view-only formatting helpers; the
//     difference text needs unit-tested behavior (sleep hour/minute
//     rounding, "+" vs "あと", on-target band) so we keep it pure.
//   - Both the metric cards and the balance card consume the same
//     formatter so the wording stays consistent.
//
//  Wording conventions (matches the PR brief examples):
//   - intake / exercise / balance kcal:
//       under target  → "あと 450 kcal"
//       over target   → "+70 kcal"
//       on target     → "目標 達成" (within ±50 kcal)
//   - sleep minutes:
//       under target  → "目標まで あと 1時間10分"
//       over target   → "+30分"
//       on target     → "目標 達成"  (within ±10 minutes)
//
//  No SwiftUI / SwiftData / UserDefaults dependency: everything passes
//  through arguments so tests can pin combinations precisely.
//

import Foundation

enum HealthTargetDifference {

    /// On-target tolerance window (kcal). The Today UI also uses this
    /// to pick a positive 「達成」 indicator color.
    static let kcalToleranceBand: Int = 50

    /// On-target tolerance window (minutes) for sleep.
    static let minutesToleranceBand: Int = 10

    enum Direction: Equatable {
        case under  // current < target — user has room (negative delta)
        case over   // current > target — user exceeded target
        case onTarget
    }

    struct Result: Equatable {
        var direction: Direction
        /// Signed delta: current - target. Positive = over target,
        /// negative = under target. `nil` when target is unknown.
        var delta: Int
        /// Human-readable label suitable for the difference row.
        var label: String
    }

    // MARK: - kcal metrics (intake / exercise / balance)

    /// Format the difference for a kcal-based metric.
    /// Returns nil when either input is nil — callers should preserve
    /// the prior "no target" display in that case.
    static func formatKcal(current: Int?, target: Int?) -> Result? {
        guard let current, let target else { return nil }
        let delta = current - target
        if abs(delta) <= kcalToleranceBand {
            return Result(direction: .onTarget, delta: delta, label: "目標 達成")
        }
        if delta > 0 {
            return Result(direction: .over, delta: delta, label: "+\(formatInt(delta)) kcal")
        }
        return Result(direction: .under, delta: delta, label: "あと \(formatInt(-delta)) kcal")
    }

    /// Balance metric (kcal). Uses the same wording as `formatKcal`
    /// but exists as a separate entry point so a future tweak (e.g.
    /// distinct on-target band for cutters vs bulkers) can land
    /// without rewriting call sites.
    static func formatBalance(current: Int?, target: Int?) -> Result? {
        formatKcal(current: current, target: target)
    }

    // MARK: - Sleep minutes

    /// Format the difference for sleep (minutes). Renders hours +
    /// minutes Japanese-style when the gap crosses an hour boundary.
    static func formatSleepMinutes(current: Int?, target: Int?) -> Result? {
        guard let current, let target else { return nil }
        let delta = current - target
        if abs(delta) <= minutesToleranceBand {
            return Result(direction: .onTarget, delta: delta, label: "目標 達成")
        }
        if delta > 0 {
            return Result(direction: .over, delta: delta, label: "+\(formatHourMinute(delta))")
        }
        return Result(direction: .under, delta: delta, label: "目標まで あと \(formatHourMinute(-delta))")
    }

    // MARK: - Shared formatting

    /// Renders a positive minute count as "Xh Ym" style Japanese.
    /// Examples: 70 → "1時間10分", 60 → "1時間", 45 → "45分".
    static func formatHourMinute(_ minutes: Int) -> String {
        let positive = max(0, minutes)
        let h = positive / 60
        let m = positive % 60
        if h > 0 && m > 0 { return "\(h)時間\(m)分" }
        if h > 0 { return "\(h)時間" }
        return "\(m)分"
    }

    private static func formatInt(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
