//
//  WeightTargetDifference.swift
//  Pulse Cue
//
//  Pure formatter for weight target / trend text. Parallel to
//  `HealthTargetDifference` (kcal / sleep minutes) but operates on
//  Double-valued weight in kg and reads its target from
//  `UserProfile.goalWeightKg` rather than from `HealthTargetSettings`.
//
//  Two display paths:
//   - `goalDifference(current:goal:)`: today's / latest weight vs the
//     user's goal — "目標まで あと 3.2 kg" / "目標より +1.4 kg" /
//     "目標 達成" (±0.5 kg band).
//   - `previousChange(latest:previous:)`: change since the previous
//     weighed entry — "前回比 +0.3 kg" / "前回比 -0.5 kg" /
//     "前回比 ±0 kg" (sub-0.05 kg rounds to ±0 to avoid +0.0
//     artifacts).
//
//  Reuses `HealthTargetDifference.Direction` for visual styling
//  consistency with the existing Today / HealthSummary rows. The
//  weight semantics intentionally keep wording neutral — neither
//  "gain" nor "loss" is treated as inherently positive, because the
//  user may be cutting or bulking.
//
//  No SwiftUI / SwiftData / UserDefaults dependency. All inputs pass
//  through arguments so tests can pin combinations exactly.
//

import Foundation

enum WeightTargetDifference {

    /// On-target tolerance for the goal-difference row (kg).
    static let kgToleranceBand: Double = 0.5

    /// Rounding floor for the previous-change row. Anything smaller
    /// rounds to ±0 to avoid surfacing "+0.0 kg" / "-0.0 kg" text
    /// after the standard 1-decimal-place display rounding.
    static let kgChangeRoundingFloor: Double = 0.05

    struct Result: Equatable {
        var direction: HealthTargetDifference.Direction
        /// Signed delta in kg. For goal diff: current - goal. For
        /// previous-change: latest - previous.
        var deltaKg: Double
        /// Human-readable Japanese label.
        var label: String
    }

    // MARK: - Goal difference

    /// Difference between the latest weight and the user's
    /// `goalWeightKg`. Returns nil when either side is missing.
    static func goalDifference(current: Double?, goal: Double?) -> Result? {
        guard let current, let goal, goal > 0 else { return nil }
        let delta = current - goal
        if abs(delta) <= kgToleranceBand {
            return Result(direction: .onTarget, deltaKg: delta, label: "目標 達成")
        }
        if delta > 0 {
            return Result(
                direction: .over,
                deltaKg: delta,
                label: "目標より +\(formatKg(delta)) kg"
            )
        }
        return Result(
            direction: .under,
            deltaKg: delta,
            label: "目標まで あと \(formatKg(-delta)) kg"
        )
    }

    // MARK: - Previous-entry change

    /// Change between the latest weighed entry and the immediately
    /// preceding one. Returns nil when either side is missing.
    /// Sub-`kgChangeRoundingFloor` magnitudes collapse to ±0 so the
    /// row doesn't flash "+0.0 kg" for tiny session-to-session noise.
    static func previousChange(latest: Double?, previous: Double?) -> Result? {
        guard let latest, let previous else { return nil }
        let delta = latest - previous
        if abs(delta) < kgChangeRoundingFloor {
            return Result(direction: .onTarget, deltaKg: 0, label: "前回比 ±0 kg")
        }
        if delta > 0 {
            return Result(
                direction: .over,
                deltaKg: delta,
                label: "前回比 +\(formatKg(delta)) kg"
            )
        }
        return Result(
            direction: .under,
            deltaKg: delta,
            label: "前回比 -\(formatKg(-delta)) kg"
        )
    }

    // MARK: - Shared formatting

    /// Renders a non-negative kg magnitude to one decimal place.
    /// Callers prepend the sign; this never emits a leading "+" or "-".
    static func formatKg(_ value: Double) -> String {
        let positive = max(0, value)
        return String(format: "%.1f", positive)
    }
}
