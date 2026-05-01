//
//  SettingsStore.swift
//  Pulse Cue
//
//  Created by Codex.
//

import Foundation
import Combine
import UIKit

@MainActor
final class SettingsStore: ObservableObject {
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }
    @Published var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
    }
    @Published var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: Keys.hapticsEnabled) }
    }
    @Published var keepScreenOn: Bool {
        didSet {
            defaults.set(keepScreenOn, forKey: Keys.keepScreenOn)
            ScreenWakeManager.apply(keepScreenOn)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        self.soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        self.hapticsEnabled = defaults.object(forKey: Keys.hapticsEnabled) as? Bool ?? true
        self.keepScreenOn = defaults.bool(forKey: Keys.keepScreenOn)
        ScreenWakeManager.apply(keepScreenOn)
    }

    private enum Keys {
        static let notificationsEnabled = "settings.notificationsEnabled"
        static let soundEnabled = "settings.soundEnabled"
        static let hapticsEnabled = "settings.hapticsEnabled"
        static let keepScreenOn = "settings.keepScreenOn"
    }
}
