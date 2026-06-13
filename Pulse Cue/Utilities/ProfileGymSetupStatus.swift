//
//  ProfileGymSetupStatus.swift
//  Pulse Cue
//
//  A small, framework-light value type summarizing how far along the user is
//  in the profile + gym setup. It is a *read-only derivation* of existing
//  sources of truth — `UserProfile.heightCm`, today's `DayLog.weightKg`, and
//  whether any `Gym` is registered — never a new source of truth. The setup
//  surface uses it purely to display completion state; editing still writes
//  through the existing stores/models.
//
//  Foundation only and auth-independent, so it is fully unit-testable without
//  any view, ModelContext, or AuthSessionStore.
//

import Foundation

struct ProfileGymSetupStatus: Equatable {
    /// A plausible positive height exists (the profile carries a seeded
    /// default, so this is typically true once a profile has been created).
    let heightSet: Bool
    /// Today's `DayLog` has a positive recorded weight.
    let weightRecorded: Bool
    /// At least one gym is registered.
    let gymRegistered: Bool

    init(heightCm: Int?, todayWeightKg: Double?, hasGym: Bool) {
        self.heightSet = (heightCm ?? 0) > 0
        self.weightRecorded = (todayWeightKg ?? 0) > 0
        self.gymRegistered = hasGym
    }

    /// All three setup items are satisfied.
    var isComplete: Bool { heightSet && weightRecorded && gymRegistered }

    /// Number of satisfied items, for an "x/3" style summary.
    var completedCount: Int {
        [heightSet, weightRecorded, gymRegistered].filter { $0 }.count
    }

    /// Total number of tracked setup items.
    var totalCount: Int { 3 }
}
