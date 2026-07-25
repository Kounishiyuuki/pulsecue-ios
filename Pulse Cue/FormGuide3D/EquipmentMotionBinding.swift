//
//  EquipmentMotionBinding.swift
//  Pulse Cue
//
//  Drives dynamic contact equipment (handles / bars / footplate / rollers)
//  from the SAME normalized `ExercisePose` the mannequin uses, so a grip
//  follows the hands and a roller follows the ankle throughout the cycle.
//  Positions come from `MannequinSkeleton` forward kinematics (model space),
//  which matches the mannequin entity hierarchy because the equipment root
//  and the mannequin root share the anchor origin.
//
//  There is NO per-component timer or extra update subscription: the scene
//  controller calls `update(_:pose:)` once per frame from the single
//  `SceneEvents.Update` clock, right after it poses the mannequin.
//

import Foundation
import RealityKit
import simd

@MainActor
enum EquipmentMotionBinding {

    /// Base (unscaled) length of every two-hand bar mesh along its local X
    /// axis. The bar is scaled at runtime — no mesh is regenerated.
    static let barCanonicalLength: Float = 1.0
    /// Bar extends this far beyond each hand center for a coherent grip.
    static let barGripMargin: Float = 0.05

    /// Target world length for a bar spanning `handSeparation` (clamped).
    static func barLength(handSeparation: Float) -> Float {
        let target = handSeparation + 2 * barGripMargin
        return min(max(target, 0.1), 1.2)
    }

    static func update(_ contacts: [EquipmentContact], pose: ExercisePose) {
        for contact in contacts {
            switch contact.kind {
            case .barBetweenHands:
                let l = MannequinSkeleton.worldPosition(of: .leftHand, pose: pose)
                let r = MannequinSkeleton.worldPosition(of: .rightHand, pose: pose)
                contact.entity.position = (l + r) * 0.5
                let axis = l - r
                let separation = simd_length(axis)
                if separation > 0.0001 {
                    // Bar's long (X) axis aligns with the hand-to-hand line.
                    contact.entity.orientation = simd_quatf(from: SIMD3(1, 0, 0), to: simd_normalize(axis))
                }
                // Follow the actual hand span by scaling the base mesh's X
                // axis (transform-only; no per-frame mesh/material creation).
                let scaleX = max(barLength(handSeparation: separation) / barCanonicalLength, 0.001)
                contact.entity.scale = SIMD3(scaleX, 1, 1)

            case .gripAtHand(let joint):
                contact.entity.position = MannequinSkeleton.worldPosition(of: joint, pose: pose)

            case .footPlate:
                let l = MannequinSkeleton.worldPosition(of: .leftFoot, pose: pose)
                let r = MannequinSkeleton.worldPosition(of: .rightFoot, pose: pose)
                contact.entity.position = (l + r) * 0.5 + SIMD3(0, 0, 0.03)

            case .ankleRoller(let dz):
                let l = MannequinSkeleton.worldPosition(of: .leftFoot, pose: pose)
                let r = MannequinSkeleton.worldPosition(of: .rightFoot, pose: pose)
                contact.entity.position = (l + r) * 0.5 + SIMD3(0, 0, dz)
            }
        }
    }
}
