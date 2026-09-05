//
//  RoutineLibraryPlaceholderTests.swift
//  Pulse CueTests
//
//  The two placeholder states are not one state.
//
//  Both make `filteredRoutines.isEmpty` true, and deciding the action's weight
//  from that single fact demoted the search action along with the create
//  action — 「検索をクリア」 lost its fill for no reason anyone asked for. The
//  distinguishing fact is whether the library holds anything at all.
//
//  `RoutineLibrarySection` calls exactly these functions to pick its card and
//  its button style, so this is the production decision rather than a
//  description of it.
//

import Foundation
import Testing
@testable import Pulse_Cue

struct RoutineLibraryPlaceholderTests {

    // MARK: - Which placeholder

    @Test func anEmptyLibraryShowsTheCreatePlaceholder() {
        #expect(
            RoutineLibraryPlaceholder.shown(hasSavedRoutines: false, hasVisibleRoutines: false)
                == .noRoutines
        )
    }

    @Test func aSearchThatMatchesNothingShowsTheSearchPlaceholder() {
        // The library is not empty — a filter is hiding it.
        #expect(
            RoutineLibraryPlaceholder.shown(hasSavedRoutines: true, hasVisibleRoutines: false)
                == .noSearchMatches
        )
    }

    @Test func routinesOnScreenShowNoPlaceholderAtAll() {
        #expect(
            RoutineLibraryPlaceholder.shown(hasSavedRoutines: true, hasVisibleRoutines: true)
                == nil
        )
    }

    // MARK: - How loud its action is

    @Test func theEmptyLibrarysCreateIsSecondary() {
        // Today's filled 「メニューを作る」 is the screen's primary action, and
        // offering the same decision twice at the same weight is the problem
        // this demotion exists for.
        #expect(RoutineLibraryPlaceholder.noRoutines.actionProminence == .secondary)
    }

    @Test func theSearchClearActionStaysPrimary() {
        // The regression this file pins: nothing else on screen offers a way
        // out of an empty search, so it is the loudest thing there and always
        // was.
        #expect(RoutineLibraryPlaceholder.noSearchMatches.actionProminence == .primary)
    }

    @Test func theTwoPlaceholdersDoNotShareAProminence() {
        #expect(
            RoutineLibraryPlaceholder.noRoutines.actionProminence
                != RoutineLibraryPlaceholder.noSearchMatches.actionProminence
        )
    }

    // MARK: - The state that separates them

    @Test func onlyTheSavedLibraryDecidesWhichPlaceholderItIs() {
        // Both states have nothing visible. If the decision ever starts
        // reading only that, these two collapse into one again.
        let empty = RoutineLibraryPlaceholder.shown(
            hasSavedRoutines: false, hasVisibleRoutines: false
        )
        let filtered = RoutineLibraryPlaceholder.shown(
            hasSavedRoutines: true, hasVisibleRoutines: false
        )
        #expect(empty != filtered)
    }
}
