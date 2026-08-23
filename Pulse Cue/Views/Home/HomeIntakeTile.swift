//
//  HomeIntakeTile.swift
//  Pulse Cue
//
//  What Home's lower 摂取 tile shows, and what tapping it does.
//
//  Both were previously decided inline in `TodayView`, and both were wrong in
//  the same way: the tile read `DayLog.intakeCalories` directly while the card
//  above it and the Nutrition tab read the shared summary. On a day with
//  confirmed meals, Home displayed two different intake figures — and tapping
//  the tile opened a manual editor whose value no screen would ever show
//  again, because meals own the day once any confirmed meal exists.
//
//  The rules live here so they can be tested. A test cannot read rendered
//  SwiftUI text, so a decision left inline in a view is a decision nothing
//  can hold: the reviewer's exact "revert the tile to the raw value" mutation
//  passed every test in the previous round.
//

import Foundation

enum HomeIntakeTile {

    /// The figure to display. Always the shared one — the tile has no
    /// second source to fall back to.
    static func displayedKcal(for summary: DailyNutritionSummary) -> Int? {
        summary.consumedKcal
    }

    /// Whether tapping opens the Nutrition tab instead of the quick input.
    ///
    /// True exactly when meals own the day. Offering manual calorie entry
    /// there would accept a number and then ignore it everywhere, which is a
    /// worse outcome than sending the user to where the figure is made.
    static func opensNutrition(for summary: DailyNutritionSummary) -> Bool {
        !summary.acceptsManualIntakeEntry
    }

    /// VoiceOver hint matching whichever action the tap performs.
    static func accessibilityHint(for summary: DailyNutritionSummary) -> String {
        opensNutrition(for: summary) ? "栄養タブで食事を編集" : "摂取を入力"
    }
}
