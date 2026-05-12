//
//  ScreenWakeManager.swift
//  Pulse Cue
//
//  Created by Codex.
//

import UIKit

struct ScreenWakeManager {
    static func apply(_ keepOn: Bool) {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = keepOn
        }
    }
}
