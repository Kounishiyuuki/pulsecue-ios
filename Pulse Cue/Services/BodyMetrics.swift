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
//  Two different kinds of value live here, and keeping them apart is the
//  whole design:
//
//    the weight     comes from the store, so it is fetched once and cached
//    the three      are arithmetic over the *current* profile, so they are
//    derived        recomputed on every read
//
//  Caching all four together — which this type used to invite — meant editing
//  height, age, sex, activity or the goal on the Body screen left BMR, TDEE
//  and the target showing figures from before the edit, until something
//  unrelated happened to a `DayLog`. The numbers were not wrong when they were
//  computed; they simply stopped being about the profile on screen.
//
//  So `derive` takes the profile as an argument rather than a snapshot taken
//  earlier. A view calling it in `body` gets values for whatever the profile
//  holds right now, and no per-field refresh chain is needed — adding a fifth
//  input to `UserProfile` cannot reintroduce the staleness, because there is
//  no cache to forget to invalidate.
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

    /// The figures for a profile, as it stands right now.
    ///
    /// Pure: no fetch, no store, nothing retained. Callers hold the weight —
    /// which does need a fetch — and pass the live profile, so editing the
    /// profile changes the result immediately and editing it again changes it
    /// again.
    static func derive(
        profile: UserProfile?,
        currentWeightKg: Double?
    ) -> BodyMetrics {
        BodyMetrics(
            currentWeightKg: currentWeightKg,
            bmr: profile?.bmr(currentWeightKg: currentWeightKg),
            tdee: profile?.tdee(currentWeightKg: currentWeightKg),
            targetIntakeKcal: profile?.targetIntake(currentWeightKg: currentWeightKg)
        )
    }

    /// The weigh-in every screen calculates from.
    ///
    /// Separate from `derive` because it is the only part that touches the
    /// store. Home, Nutrition, Me and Body all resolve through here, so they
    /// cannot disagree about which weigh-in is current.
    @MainActor
    static func resolveCurrentWeightKg(modelContext: ModelContext) -> Double? {
        LatestBodyWeightResolver.latestWeightKg(modelContext: modelContext)
    }
}
