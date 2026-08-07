//
//  QuickPlanRequest.swift
//  Pulse Cue
//
//  The three minimal conditions a Quick Plan is built from — target body
//  parts, a duration bucket, and an intensity. These are small, pure value
//  types with no I/O; `WorkoutPlanGenerator.generate(request:…)` turns a
//  request plus the active gym's available equipment into the existing
//  `GeneratedPlan`, so Quick Plan reuses the whole generate → preview →
//  RoutineFactory → Runner path rather than adding a parallel generator.
//

import Foundation

/// How long today's session should be. Drives how many exercises the plan
/// contains; deliberately a coarse bucket, not a precise time calculation.
enum QuickPlanDuration: Int, CaseIterable, Codable, Identifiable {
    case compact = 30
    case standard = 45
    case standardPlus = 60
    case extended = 90

    var id: Int { rawValue }

    var minutes: Int { rawValue }

    var displayName: String { "\(rawValue)分" }

    /// Target number of exercises across all selected body parts. Kept small
    /// so the preview stays scannable; the generator still caps at whatever
    /// the available equipment can actually fill.
    var targetExerciseCount: Int {
        switch self {
        case .compact: return 3
        case .standard: return 4
        case .standardPlus: return 5
        case .extended: return 7
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

    /// Body parts with duplicates removed, first-seen order preserved.
    var normalizedBodyParts: [BodyPart] {
        var seen = Set<BodyPart>()
        return bodyParts.filter { seen.insert($0).inserted }
    }
}
