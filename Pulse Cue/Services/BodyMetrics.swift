//
//  BodyMetrics.swift
//  Pulse Cue
//
//  The body figures every screen derives from one weigh-in.
//
//  These were computed inline in the Body / Goals screen from a weight it
//  read out of its own fourteen-day query — the one it renders history from.
//  A presentation window has no business deciding domain truth, and this is
//  what it cost: someone who last weighed in three weeks ago had their BMR,
//  TDEE and calorie target computed as though no weight existed, while Home
//  and Me displayed the figure perfectly well.
//
//  Putting the resolution and the three derived numbers together means the
//  screen has nothing left to get wrong: it asks for the metrics rather than
//  assembling them, and a test can drive exactly what the screen drives. A
//  decision left inline in a view is a decision nothing can hold — that lesson
//  is already written into `HomeIntakeTile` for the same reason.
//
//  Nothing here is new arithmetic. `UserProfile` still owns every formula.
//

import Foundation
import SwiftData

struct BodyMetrics: Equatable {
    /// The most recent recorded weight, whenever it was recorded.
    let currentWeightKg: Double?
    let bmr: Int?
    let tdee: Int?
    /// The profile-derived intake target, before any manual override.
    let targetIntakeKcal: Int?

    /// Resolves the weight through the shared resolver and derives the rest.
    ///
    /// The resolver is the single source: Home, Nutrition, Me and this screen
    /// all go through it, so they cannot disagree about which weigh-in is
    /// current.
    @MainActor
    static func resolve(
        modelContext: ModelContext,
        profile: UserProfile?
    ) -> BodyMetrics {
        let weight = LatestBodyWeightResolver.latestWeightKg(
            modelContext: modelContext
        )
        return BodyMetrics(
            currentWeightKg: weight,
            bmr: profile?.bmr(currentWeightKg: weight),
            tdee: profile?.tdee(currentWeightKg: weight),
            targetIntakeKcal: profile?.targetIntake(currentWeightKg: weight)
        )
    }
}
