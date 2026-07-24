//
//  ExerciseMotionProfile.swift
//  Pulse Cue
//
//  Static, non-persistent 3D movement metadata for the Form Guide viewer.
//  This is deliberately SEPARATE from `ExerciseGuide.animationAssetId`
//  (which stays nil — this MVP ships no external animation assets) and from
//  SwiftData. A profile describes only how the procedural mannequin should
//  move for one exercise: a looping start→peak→start cycle expressed as
//  joint keyframes, plus preferred camera framing and an equipment scene.
//
//  Angle conventions (see `MannequinSkeleton`): character faces +Z, up +Y,
//  character-right is -X. Arms hang down at rest. Negative X rotation of an
//  upper arm / forearm swings it forward (+Z); Z rotation abducts the arms
//  laterally (right arm negative, left arm positive). Ranges are kept
//  conservative and are a movement *reference*, not a biomechanical claim.
//

import Foundation
import simd

/// Camera framing a profile prefers when the viewer first opens.
enum Exercise3DCamera: String, Hashable, Sendable, CaseIterable {
    case front
    case side
    case threeQuarter

    var displayName: String {
        switch self {
        case .front: return "正面"
        case .side: return "側面"
        case .threeQuarter: return "斜め"
        }
    }
}

/// Which lightweight procedural equipment context to build around the
/// mannequin. Kept coarse — one case per MVP exercise family.
enum ExerciseEquipmentScene: String, Hashable, Sendable {
    case chestPress
    case latPulldown
    case seatedRow
    case shoulderPress
    case legPress
    case legExtension
    case legCurl
    case armCurl
    case tricepsPushdown
    case lateralRaise
    case none
}

/// One keyframe of the looping cycle. `progress` is normalized 0...1.
struct MotionKeyframe: Sendable {
    let progress: Float
    let pose: ExercisePose
}

/// Complete 3D movement description for one exercise.
struct ExerciseMotionProfile: Sendable {
    let exerciseId: ExerciseID
    /// Seconds for one full loop at 1.0x.
    let duration: Float
    let preferredCamera: Exercise3DCamera
    let equipmentScene: ExerciseEquipmentScene
    /// Keyframes sorted by progress; must start at 0 and end at 1 with an
    /// equal pose so the loop is seamless.
    let keyframes: [MotionKeyframe]
}

/// Pure interpolating motion engine. Given a profile and a normalized
/// cycle progress it returns the interpolated `ExercisePose`. Deterministic
/// and RealityKit-free so it is unit tested directly.
struct ExerciseMotionEngine {
    let profile: ExerciseMotionProfile
    private let frames: [MotionKeyframe]

    init(profile: ExerciseMotionProfile) {
        self.profile = profile
        self.frames = profile.keyframes.sorted { $0.progress < $1.progress }
    }

    /// Interpolated pose at `progress` (wrapped into 0...1 so it loops).
    func pose(atProgress rawProgress: Float) -> ExercisePose {
        guard !frames.isEmpty else { return ExercisePose() }
        let p = wrap(rawProgress)
        if frames.count == 1 { return frames[0].pose }

        // Find the bracketing keyframes.
        var lower = frames[0]
        var upper = frames[frames.count - 1]
        for i in 0..<(frames.count - 1) {
            if p >= frames[i].progress && p <= frames[i + 1].progress {
                lower = frames[i]
                upper = frames[i + 1]
                break
            }
        }
        let span = upper.progress - lower.progress
        let t = span > 0 ? (p - lower.progress) / span : 0
        // Smoothstep for eased, natural-looking motion with no boundary snap.
        let eased = t * t * (3 - 2 * t)
        return ExercisePose.lerp(lower.pose, upper.pose, eased)
    }

    private func wrap(_ p: Float) -> Float {
        guard p.isFinite else { return 0 }
        let m = p.truncatingRemainder(dividingBy: 1)
        return m < 0 ? m + 1 : m
    }
}
