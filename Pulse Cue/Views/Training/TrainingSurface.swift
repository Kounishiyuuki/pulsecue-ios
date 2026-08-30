//
//  TrainingSurface.swift
//  Pulse Cue
//
//  The order of things in the Training tab.
//
//  Written down for the same reason `NutritionSurface` is: this decays by
//  agreement. Every training feature has a fair claim to be visible, and the
//  last arrangement proved it — Gym, the exercise library, the weekly plan
//  and AI planning all ended up under Settings, not because anyone decided
//  they were settings, but because that was where there was room.
//
//  Ranking them here means promoting one has to appear as a change to this
//  file rather than as a card someone adds to a screen.
//
//  Nothing here decides behaviour. `TodayTrainingCard` owns which primary
//  action is shown, and `RoutineLibrary` owns which routines can be started.
//

import Foundation

enum TrainingSurface {

    /// A destination reachable from the Training tab.
    enum Destination: Hashable, CaseIterable {
        /// Today's workout and its one action.
        case today
        /// The routine library.
        case plan
        case history
        case gym
        case exerciseLibrary
        /// The machine catalogue. Separate from the exercise library: one is
        /// exercises and their form guides, the other is the machines.
        case machineCatalog
        case progress
        case weeklyPlan
        case aiPlanning
    }

    /// How prominent a destination is allowed to be.
    enum Level: Int, Equatable {
        /// The first thing on the screen, with the primary action.
        case primary = 0
        /// Visible without a tap, below today.
        case secondary = 1
        /// Reachable, listed, and never competing with the above.
        case more = 2
    }

    static func level(of destination: Destination) -> Level {
        switch destination {
        case .today:
            return .primary
        case .plan, .history:
            return .secondary
        case .gym, .exerciseLibrary, .machineCatalog, .progress, .weeklyPlan,
             .aiPlanning:
            return .more
        }
    }

    /// One filled action on the root: start, continue, or create — whichever
    /// the day's state calls for. Never more than one at a time.
    static let primaryActions = 1

    /// Everything that used to be filed under app settings and is really a
    /// training task.
    static let relocatedFromSettings: [Destination] = [
        .gym, .exerciseLibrary, .machineCatalog, .weeklyPlan, .aiPlanning,
    ]

    /// The destinations 「その他の機能」 lists, in the order it lists them.
    ///
    /// `TrainingMoreSection` renders this — it does not merely agree with it.
    /// Until it did, the ranking above described a screen it had no hold over:
    /// the machine catalogue could lose its only entry point with every test
    /// in `TrainingHierarchyTests` still green, which is exactly what happened
    /// in #178. Deleting a case now fails to compile at the row that draws it.
    static var moreDestinations: [Destination] {
        Destination.allCases.filter { level(of: $0) == .more }
    }
}
