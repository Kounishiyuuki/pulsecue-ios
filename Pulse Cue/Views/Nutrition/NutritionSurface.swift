//
//  NutritionSurface.swift
//  Pulse Cue
//
//  The order of things on the Nutrition screen.
//
//  Written down because this is the kind of decision that erodes by
//  agreement rather than by mistake. The screen had five ways to add a meal
//  on its first viewport — an AI chip, three scanner chips, and four
//  full-size empty slot cards — and not one of them was unreasonable when it
//  was added. Nobody removes a feature's entry point, so they accumulate
//  until the screen is a menu of methods instead of a place to record a meal.
//
//  Keeping the ranking here means a sixth entry point, or a macro promoted to
//  the top, has to show up as a change to this file.
//
//  Nothing here decides what is *true* — `DailyNutritionSummary` owns that.
//  This only decides what is loudest.
//

import Foundation

enum NutritionSurface {

    /// The figure the card leads with.
    enum LeadingFigure: Equatable {
        /// What is left of the target — the number the next meal is decided
        /// against.
        case remaining
        /// What has been eaten. Used when there is no target, where
        /// "remaining" has no answer.
        case consumed
    }

    static func leadingFigure(for summary: DailyNutritionSummary) -> LeadingFigure {
        summary.remainingKcal == nil ? .consumed : .remaining
    }

    /// The macros, and which of them earns space before a tap.
    enum Macro: Equatable {
        case protein
        case carbs
        case fat
    }

    /// Only protein. It is the macro people hold themselves to a target on;
    /// giving all three equal panels meant none of them read as the one to
    /// look at.
    static func isFirstLevel(_ macro: Macro) -> Bool {
        macro == .protein
    }

    /// How a meal can be entered. All of them survive; none of them is asked
    /// about before the user has said they want to record something.
    enum InputMethod: Equatable, CaseIterable {
        case manual
        case ai
        case nutritionLabel
        case barcode
        case photo
    }

    static var inputMethods: [InputMethod] { InputMethod.allCases }

    /// Input methods are never root-level actions — they are the second step.
    static func isRootPrimary(_ method: InputMethod) -> Bool { false }

    /// One filled action on the root: 食事を記録.
    static let primaryActions = 1

    /// The screen's sections, top to bottom.
    enum Section: Equatable {
        case todayIntake
        case addMeal
        case todayMeals
        case pendingEstimates
        case recentAndFavourites
        case weeklyTrend
    }

    /// Lower comes first. Today's decision outranks today's record, which
    /// outranks anything about other days.
    static func rank(_ section: Section) -> Int {
        switch section {
        case .todayIntake: return 0
        case .addMeal: return 1
        case .todayMeals: return 2
        case .pendingEstimates: return 3
        case .recentAndFavourites: return 4
        case .weeklyTrend: return 5
        }
    }
}
