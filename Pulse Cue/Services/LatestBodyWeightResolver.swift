//
//  LatestBodyWeightResolver.swift
//  Pulse Cue
//
//  The body weight the calorie target is calculated from.
//
//  Home and the Nutrition tab both feed a weight into
//  `UserProfile.targetIntake`, and they were finding it differently: Home
//  looked only inside the fourteen days it had already loaded for its
//  dashboard, Nutrition looked at every log. Someone who last weighed in
//  three weeks ago therefore got a target computed from their weight on one
//  screen and from the goal-weight fallback on the other — different targets,
//  different remaining figures, same day.
//
//  The cause is worth naming because it is easy to repeat: fourteen days is a
//  *presentation* window. It exists because the dashboard shows a fortnight
//  of history. Letting it reach into a calculation made the arithmetic depend
//  on how much history a screen happened to render.
//
//  So the lookup lives here, asks for exactly one row, and both screens use
//  it. No view loads its whole history to take a maximum.
//

import Foundation
import SwiftData

enum LatestBodyWeightResolver {

    /// The most recently recorded body weight, or `nil` if none was ever
    /// logged — in which case `UserProfile.targetIntake` falls back to the
    /// goal weight, exactly as before.
    ///
    /// Fetches a single row: newest first, weight present. What counts as a
    /// usable weight is unchanged — a non-nil `weightKg` — because inventing
    /// a validity rule here would quietly change targets for existing users.
    @MainActor
    static func latestWeightKg(modelContext: ModelContext) -> Double? {
        var descriptor = FetchDescriptor<DayLog>(
            predicate: #Predicate<DayLog> { $0.weightKg != nil },
            sortBy: [SortDescriptor(\DayLog.date, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first?.weightKg
    }
}
