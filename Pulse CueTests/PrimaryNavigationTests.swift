//
//  PrimaryNavigationTests.swift
//  Pulse CueTests
//
//  What the bottom tab bar is allowed to contain.
//
//  This is a test about product shape rather than behaviour, which is unusual
//  enough to say why it exists: the tab bar is the one piece of the app that
//  every other decision leans on, and it drifts by accretion. A tab gets added
//  because a screen felt important that week, and nobody removes one, because
//  removing one always looks like taking something away. Writing the intended
//  set down means a fifth tab has to be argued for in a diff rather than
//  appearing quietly.
//
//  The rule: primary tabs are the things someone opens the app *to do*.
//  History and Settings are places you end up because of something else, so
//  they live inside the module they belong to — and the tests below pin that
//  they are still reachable, because moving a screen out of the tab bar is
//  only acceptable if it did not become harder to find.
//

import Testing
@testable import Pulse_Cue

struct PrimaryNavigationTests {

    // MARK: - The tab set

    @Test func primaryTabsAreHomeTrainingNutritionAndMe() {
        #expect(AppTab.allCases == [.home, .training, .nutrition, .me])
    }

    @Test func thereAreExactlyFourPrimaryTabs() {
        // Four is the budget. Each extra choice slows down finding all the
        // others, and everything else has a home inside a module.
        #expect(AppTab.allCases.count == 4)
    }

    @Test func nutritionIsAPrimaryTab() {
        // The change that motivated this: Nutrition is a daily module and had
        // no tab of its own, reachable only by going through Home.
        #expect(AppTab.allCases.contains(.nutrition))
    }

    @Test func trainingIsAPrimaryTab() {
        #expect(AppTab.allCases.contains(.training))
    }

    @Test func meIsAPrimaryTab() {
        #expect(AppTab.allCases.contains(.me))
    }

    @Test func homeIsTheDefaultTab() {
        #expect(PrimaryNavigation.defaultTab == .home)
    }

    // MARK: - What is deliberately *not* a primary tab

    @Test func historyIsNotAPrimaryTab() {
        #expect(PrimaryNavigation.isPrimary(.history) == false)
    }

    @Test func settingsIsNotAPrimaryTab() {
        #expect(PrimaryNavigation.isPrimary(.settings) == false)
    }

    @Test func gymAndAIAndRecoveryAreNotPrimaryTabs() {
        // Named individually because each of these has been a plausible
        // candidate at some point, and each would cost one of the four.
        #expect(PrimaryNavigation.isPrimary(.gym) == false)
        #expect(PrimaryNavigation.isPrimary(.formGuide) == false)
        #expect(PrimaryNavigation.isPrimary(.recovery) == false)
    }

    // MARK: - Nothing became unreachable

    @Test func historyIsReachableFromTraining() {
        #expect(PrimaryNavigation.host(of: .history) == .training)
    }

    @Test func settingsIsReachableFromMe() {
        #expect(PrimaryNavigation.host(of: .settings) == .me)
    }

    @Test func profileIsReachableFromMe() {
        #expect(PrimaryNavigation.host(of: .profile) == .me)
    }

    @Test func everyRelocatedDestinationHasAHost() {
        // The failure this catches is a screen dropped from the tab bar and
        // not given anywhere else to live — reachable in no build, noticed in
        // no test, and found by a user who used to have it one tap away.
        for destination in SecondaryDestination.allCases {
            #expect(PrimaryNavigation.host(of: destination) != nil)
        }
    }

    // MARK: - Labels

    @Test func everyTabHasANonEmptyLabel() {
        // Icon-only tabs are unusable with VoiceOver and ambiguous without it.
        for tab in AppTab.allCases {
            #expect(PrimaryNavigation.label(for: tab).isEmpty == false)
        }
    }

    @Test func tabLabelsAreDistinct() {
        let labels = Set(AppTab.allCases.map(PrimaryNavigation.label(for:)))
        #expect(labels.count == AppTab.allCases.count)
    }

    @Test func tabLabelsAreShortEnoughForTheTabBar() {
        // Four Japanese labels have to fit side by side without truncating.
        for tab in AppTab.allCases {
            #expect(PrimaryNavigation.label(for: tab).count <= 6)
        }
    }

    @Test func trainingLabelNamesTheModuleNotTheWorkoutObject() {
        // 「トレーニング」 is the module; 「ワークアウト」 is one session inside
        // it. Using the second as a tab name would make the running workout
        // and the place you pick routines sound like the same thing.
        #expect(PrimaryNavigation.label(for: .training) == "トレーニング")
    }
}
