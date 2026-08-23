//
//  PrimaryNavigation.swift
//  Pulse Cue
//
//  Which screens are primary, and where the rest live.
//
//  `AppTab` says what the four tabs are. This says the part that is easy to
//  lose: where everything that is *not* a tab went. Moving History out of the
//  tab bar is only defensible if it is still one tap from where you would look
//  for it, and that promise is the kind that decays silently — a refactor
//  removes a toolbar item, nothing fails, and a screen quietly becomes
//  unreachable in a build nobody notices for weeks.
//
//  Writing the hosts down does not by itself keep the routes alive, but it
//  makes the intent reviewable and gives the tests something concrete to hold
//  the UI to.
//
//  The labels live here rather than inline in `ContentView` so the tab bar and
//  the tests cannot disagree about what the app calls things.
//

import Foundation

/// A destination that used to be — or could plausibly have been — a tab, and
/// the module it belongs to instead.
enum SecondaryDestination: CaseIterable {
    /// Past workouts. Was a primary tab.
    case history
    /// App settings. Was a primary tab.
    case settings
    /// Profile, body metrics and My Gym.
    case profile
    /// Gym and machine management.
    case gym
    /// The 3D form guide.
    case formGuide
    /// Rest and recovery guidance.
    case recovery
}

enum PrimaryNavigation {

    /// Where the app opens.
    static let defaultTab: AppTab = .home

    /// Whether a destination is one of the four primary tabs.
    ///
    /// Always false: `SecondaryDestination` is, by definition, the set of
    /// things that are not tabs. It reads as a tautology and is worth keeping
    /// anyway — the honest way to add one of these to the tab bar is to move
    /// it out of this enum, which is a visible diff, rather than to quietly
    /// add a fifth `TabView` child.
    static func isPrimary(_ destination: SecondaryDestination) -> Bool {
        false
    }

    /// The tab a secondary destination is reached from.
    static func host(of destination: SecondaryDestination) -> AppTab? {
        switch destination {
        case .history:
            // Beside routine selection: you look at past workouts while
            // deciding what to do next.
            return .training
        case .settings, .profile:
            return .me
        case .gym, .formGuide:
            // Both are reached from the training surfaces that use them.
            return .training
        case .recovery:
            return .home
        }
    }

    /// The tab bar label. Never empty, and never icon-only.
    static func label(for tab: AppTab) -> String {
        switch tab {
        case .home: return "ホーム"
        case .training: return "トレーニング"
        case .nutrition: return "栄養"
        case .me: return "マイページ"
        }
    }

    /// The tab bar icon. Existing SF Symbols; no new visual identity here.
    static func icon(for tab: AppTab) -> String {
        switch tab {
        case .home: return "house"
        case .training: return "dumbbell"
        case .nutrition: return "fork.knife"
        case .me: return "person"
        }
    }
}
