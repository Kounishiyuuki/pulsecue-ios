//
//  SoundHapticManager.swift
//  Pulse Cue
//
//  Created by Codex.
//

import Foundation
import AudioToolbox
import UIKit

struct SoundHapticManager {
    static func playBeep() {
        AudioServicesPlaySystemSound(1104)
    }

    static func playHaptic() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }
}
