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

    /// A value that changes whenever the latest weigh-in does.
    ///
    /// `onChange(of: someDayLogArray)` compares `@Model` elements by identity,
    /// so editing `weightKg` in place leaves the array "equal" and the
    /// observer may never fire — the screen keeps a weight that is no longer
    /// on disk. Reading the date and the value here gives SwiftUI something
    /// that genuinely differs, and reading those properties is also what makes
    /// the view re-evaluate when they change.
    ///
    /// A signature rather than the weight itself because "which row is latest"
    /// can change without the number changing, and that still needs a refresh.
    static func changeSignature(for logs: [DayLog]) -> String {
        guard let latest = logs
            .filter({ $0.weightKg != nil })
            .max(by: { $0.date < $1.date })
        else { return "none" }
        return "\(latest.date.timeIntervalSince1970):\(latest.weightKg ?? 0)"
    }
}
