//
//  BodyPart.swift
//  Pulse Cue
//
//  Target body part enum used by the manual gym workout plan flow.
//  String raw values are stored on `WorkoutPlan` rows / passed to the
//  generator; Japanese display labels live with the enum so views can
//  pick them up without an extra lookup table.
//

import Foundation

enum BodyPart: String, CaseIterable, Codable, Identifiable, Hashable {
    case chest
    case back
    case legs
    case shoulders
    case arms
    case core
    case fullBody

    var id: String { rawValue }

    /// User-facing Japanese label.
    var displayName: String {
        switch self {
        case .chest: return "胸"
        case .back: return "背中"
        case .legs: return "脚"
        case .shoulders: return "肩"
        case .arms: return "腕"
        case .core: return "体幹"
        case .fullBody: return "全身"
        }
    }
}
