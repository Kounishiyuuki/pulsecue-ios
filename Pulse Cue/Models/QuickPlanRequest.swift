//
//  QuickPlanRequest.swift
//  Pulse Cue
//
//  The minimal conditions a Quick Plan is built from — target body
//  parts, a duration, an intensity, and an optional exercise count. These are small, pure value
//  types with no I/O; `WorkoutPlanGenerator.generate(request:…)` turns a
//  request plus the active gym's available equipment into the existing
//  `GeneratedPlan`, so Quick Plan reuses the whole generate → preview →
//  RoutineFactory → Runner path rather than adding a parallel generator.
//

import Foundation

/// How long today's session should be. This is a *time* goal: the generator
/// sizes the plan so its estimated duration (`WorkoutDurationEstimator`) lands
/// near the chosen value, rather than emitting a fixed number of exercises.
///
/// A struct rather than an enum so the range (30…180 in 15-minute steps) is
/// data, not eleven hand-named cases. The original four buckets stay
/// reachable by name so existing call sites and tests are unchanged.
struct QuickPlanDuration: Hashable, Codable, Identifiable {
    static let minMinutes = 30
    static let maxMinutes = 180
    static let stepMinutes = 15

    static let compact = QuickPlanDuration(minutes: 30)
    static let standard = QuickPlanDuration(minutes: 45)
    static let standardPlus = QuickPlanDuration(minutes: 60)
    static let extended = QuickPlanDuration(minutes: 90)

    static let allCases: [QuickPlanDuration] = stride(
        from: minMinutes, through: maxMinutes, by: stepMinutes
    ).map { QuickPlanDuration(minutes: $0) }

    let minutes: Int

    /// Clamps to the supported range and snaps to the 15-minute grid, so a
    /// value can never fall outside what the picker offers.
    init(minutes: Int) {
        let clamped = Swift.min(Swift.max(minutes, Self.minMinutes), Self.maxMinutes)
        let steps = Int((Double(clamped - Self.minMinutes) / Double(Self.stepMinutes)).rounded())
        self.minutes = Self.minMinutes + steps * Self.stepMinutes
    }

    var id: Int { minutes }

    var rawValue: Int { minutes }

    var displayName: String { "\(minutes)分" }

    /// How far past the chosen time a plan may run. The estimate is coarse
    /// and the user picked a ceiling, so a little overshoot is fine and a lot
    /// is not.
    var upperBoundMinutes: Int { Int((Double(minutes) * 1.10).rounded(.down)) }

    /// Below this a plan is meaningfully shorter than what was asked for.
    /// Used only to decide whether to warn — the generator never pads a plan
    /// with equipment the gym does not have.
    var lowerBoundMinutes: Int { Int((Double(minutes) * 0.80).rounded(.up)) }
}

/// How many exercises the user wants. `automatic` (おまかせ) keeps the
/// time-driven sizing; a fixed count is honoured as far as the gym's
/// equipment allows, with sets adjusted toward the chosen time.
enum QuickPlanExerciseCount: Hashable, Codable, Identifiable {
    case automatic
    case fixed(Int)

    static let fixedRange = 3...10

    static let allCases: [QuickPlanExerciseCount] = [.automatic] + fixedRange.map { .fixed($0) }

    var id: Int { fixedCount ?? 0 }

    var fixedCount: Int? {
        if case .fixed(let count) = self { return count }
        return nil
    }

    var displayName: String {
        switch self {
        case .automatic: return "おまかせ"
        case .fixed(let count): return "\(count)種目"
        }
    }
}

/// How hard today's session should feel. Applied as a small, deterministic
/// nudge to each strength exercise's sets and rest — never a "smart"
/// rewrite of the authored prescription (cardio/warm-up entries with no
/// rest are left untouched).
enum QuickPlanIntensity: String, CaseIterable, Codable, Identifiable {
    case light
    case standard
    case hard

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: return "軽め"
        case .standard: return "標準"
        case .hard: return "しっかり"
        }
    }

    /// Sets added (or removed) per strength exercise. Clamped to ≥1 by the
    /// generator so a set count never drops to zero.
    var setsDelta: Int {
        switch self {
        case .light: return -1
        case .standard: return 0
        case .hard: return 1
        }
    }

    /// Rest seconds added (or removed) per strength exercise. Clamped to ≥30
    /// by the generator.
    var restDelta: Int {
        switch self {
        case .light: return -15
        case .standard: return 0
        case .hard: return 15
        }
    }
}

/// The minimal set of conditions chosen on the Quick Plan sheet.
struct QuickPlanRequest: Equatable {
    /// Ordered, may contain duplicates on the way in — the generator dedupes
    /// and preserves first-seen order.
    var bodyParts: [BodyPart]
    var duration: QuickPlanDuration
    var intensity: QuickPlanIntensity
    var exerciseCount: QuickPlanExerciseCount = .automatic

    /// Body parts with duplicates removed, first-seen order preserved.
    var normalizedBodyParts: [BodyPart] {
        var seen = Set<BodyPart>()
        return bodyParts.filter { seen.insert($0).inserted }
    }
}
