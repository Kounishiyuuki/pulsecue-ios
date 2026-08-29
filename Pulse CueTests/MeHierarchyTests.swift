//
//  MeHierarchyTests.swift
//  Pulse CueTests
//
//  What belongs to the user and what belongs to the app.
//
//  マイページ used to offer one 「設定」 that opened everything: height and age,
//  HealthKit, the account, sign-in, notification toggles, the version string —
//  one scroll, no separation. That is not a bug in any single screen; it is
//  what happens when "your data" and "the app's configuration" share a list
//  and nothing says they are different kinds of thing.
//
//  These tests say so, and pin that the training features moved out in #178
//  have not drifted back.
//

import Foundation
import Testing
@testable import Pulse_Cue

struct MeHierarchyTests {

    // MARK: - Settings lifecycle preservation

    @Test func scopedSettingsScreensPreserveNotificationRefreshOwnership() {
        #expect(SettingsView.parentOwnsNotificationRefresh(for: .bodyAndGoals))
        #expect(SettingsView.parentOwnsNotificationRefresh(for: .health))
        #expect(SettingsView.parentOwnsNotificationRefresh(for: .account))
        #expect(SettingsView.parentOwnsNotificationRefresh(for: .app) == false)
    }

    @Test func allSectionsScreenLetsAppPreferencesOwnTheSingleRefresh() {
        #expect(SettingsView.parentOwnsNotificationRefresh(for: nil) == false)
    }

    // MARK: - The four groups

    @Test func meSeparatesPersonalDataFromAppConfiguration() {
        // The distinction the single 設定 screen could not express.
        #expect(SettingsSection.allCases.count == 4)
        #expect(SettingsSection.allCases.contains(.bodyAndGoals))
        #expect(SettingsSection.allCases.contains(.health))
        #expect(SettingsSection.allCases.contains(.account))
        #expect(SettingsSection.allCases.contains(.app))
    }

    @Test func everySectionHasADistinctTitle() {
        // Two entries with the same name on one screen is how a user learns
        // not to trust the labels.
        let titles = SettingsSection.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        for title in titles {
            #expect(title.isEmpty == false)
        }
    }

    @Test func sectionTitlesAreShortEnoughForARow() {
        for section in SettingsSection.allCases {
            #expect(section.title.count <= 8)
        }
    }

    @Test func bodyAndGoalsIsNotFiledUnderAppSettings() {
        // Height, weight and the goal are the user's data. They shared a
        // screen with notification toggles, which is what this separates.
        #expect(SettingsSection.bodyAndGoals != .app)
        #expect(SettingsSection.health != .app)
        #expect(SettingsSection.account != .app)
    }

    // MARK: - Nothing became unreachable

    @Test func accountAndItsDeletionRemainOneSectionAway() {
        // Deletion must stay findable — it is the action a user needs when
        // they have decided to leave, and burying it is a dark pattern.
        #expect(SettingsSection.allCases.contains(.account))
        #expect(SettingsSection.account.title == "アカウント")
    }

    @Test func healthIntegrationHasItsOwnSection() {
        // HealthKit is data integration, not an app preference.
        #expect(SettingsSection.allCases.contains(.health))
    }

    // MARK: - Training features stayed in Training

    @Test func trainingFeaturesAreNotOwnedByMe() {
        // #178 moved these out of Settings. Me re-listing any of them would
        // recreate the duplicate routes that reorganisation removed.
        for destination in TrainingSurface.relocatedFromSettings {
            #expect(TrainingSurface.level(of: destination) == .more)
        }
    }

    @Test func theMachineCatalogueStillBelongsToTraining() {
        #expect(TrainingSurface.relocatedFromSettings.contains(.machineCatalog))
        #expect(TrainingSurface.level(of: .machineCatalog) == .more)
    }

    @Test func gymAndFormGuideAreStillHostedByTraining() {
        #expect(PrimaryNavigation.host(of: .gym) == .training)
        #expect(PrimaryNavigation.host(of: .formGuide) == .training)
    }

    // MARK: - The tab bar is unchanged

    @Test func meIsStillOneOfFourTabs() {
        #expect(AppTab.allCases == [.home, .training, .nutrition, .me])
        #expect(PrimaryNavigation.host(of: .settings) == .me)
        #expect(PrimaryNavigation.host(of: .profile) == .me)
    }
}
