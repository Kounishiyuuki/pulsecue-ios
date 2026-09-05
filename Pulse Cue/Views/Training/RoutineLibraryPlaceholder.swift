//
//  RoutineLibraryPlaceholder.swift
//  Pulse Cue
//
//  What the routine library shows instead of routines, and how loud its
//  action is allowed to be.
//
//  The two placeholder states look alike and are not the same thing:
//
//    **No routines at all.** Creating one is the thing to do, but Training
//    already says so — the Today card's filled 「メニューを作る」 is the
//    screen's primary action. A second filled Create here would be the same
//    decision offered twice, so this one is quieter.
//
//    **No search matches.** The library is not empty; a filter is hiding it.
//    Clearing the search is the only way forward from this screen and nothing
//    above competes with it, so it stays prominent — exactly as it was.
//
//  Written down because `filteredRoutines.isEmpty` is true in both, and
//  deciding the button's weight from that one fact is what quietly demoted
//  the search action along with the create action.
//

import Foundation

/// How much visual weight a placeholder's action may take.
///
/// Two cases rather than a `Bool`: at the call site `prominence: .secondary`
/// says which of the two states is being drawn, where `isPrimary: false`
/// would only say which style to use and leave the reason nowhere.
enum ActionProminence: Equatable {
    /// The loudest action on its screen.
    case primary
    /// Available and deliberately below something else.
    case secondary
}

enum RoutineLibraryPlaceholder: Equatable {
    /// The library holds no saved routines.
    case noRoutines
    /// The library holds routines; the current search matches none of them.
    case noSearchMatches

    /// Which placeholder to show, or `nil` when there are routines to list.
    ///
    /// - Parameters:
    ///   - hasSavedRoutines: whether the library holds anything at all, before
    ///     the search is applied. This is the fact that separates the two
    ///     states, and reading it is the whole point of this type.
    ///   - hasVisibleRoutines: whether anything survives the current search.
    static func shown(
        hasSavedRoutines: Bool,
        hasVisibleRoutines: Bool
    ) -> RoutineLibraryPlaceholder? {
        guard !hasVisibleRoutines else { return nil }
        return hasSavedRoutines ? .noSearchMatches : .noRoutines
    }

    var actionProminence: ActionProminence {
        switch self {
        // Today owns the primary Create; this is the same decision, lower.
        case .noRoutines: return .secondary
        // Nothing else on screen offers a way out of an empty search.
        case .noSearchMatches: return .primary
        }
    }
}
