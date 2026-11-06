//
//  MannequinFactory.swift
//  Pulse Cue
//
//  Builds the reusable procedural training mannequin from the shared
//  `MannequinSkeleton`. One articulated `Entity` per joint (the pivot),
//  nested so a parent rotation carries its children. Each bone gets a
//  rounded box "limb" visual parented to its PARENT joint (so it rotates
//  with the parent), plus a sphere at each joint for a smooth, recognizable
//  stylized human — not a debug stick figure.
//
//  Uses only RealityKit mesh generators available at the iOS 17 deployment
//  target (box with cornerRadius, sphere) — no iOS 18 cylinder/cone/capsule.
//  A single hierarchy is reused for every exercise; motion is applied by
//  setting each joint entity's `orientation` (see Exercise3DSceneController).
//

import Foundation
import RealityKit
import UIKit
import simd

@MainActor
enum MannequinFactory {

    /// End-effector volumes are shared with contact regression tests. Every
    /// equipment binding targets the joint pivot, so that pivot (and the
    /// small plate/roller Z nudge) must remain inside the visible volume.
    enum ContactGeometry {
        static let handSize = SIMD3<Float>(0.085, 0.13, 0.07)
        static let handOffset = SIMD3<Float>(0, -0.035, 0.018)
        static let footSize = SIMD3<Float>(0.11, 0.09, 0.24)
        static let footOffset = SIMD3<Float>(0, -0.025, 0.075)

        static func contains(_ point: SIMD3<Float>, size: SIMD3<Float>, offset: SIMD3<Float>) -> Bool {
            let delta = point - offset
            let half = size * 0.5
            return abs(delta.x) <= half.x && abs(delta.y) <= half.y && abs(delta.z) <= half.z
        }
    }

    struct Mannequin {
        let root: Entity
        let joints: [ExerciseJoint: Entity]
    }

    private enum Style {
        static let sphereMesh = MeshResource.generateSphere(radius: 0.5)
        static let bodyMaterial = SimpleMaterial(
            color: UIColor(red: 0.76, green: 0.91, blue: 1.0, alpha: 1),
            roughness: 0.32,
            isMetallic: false
        )
        static let coreMaterial = SimpleMaterial(
            color: UIColor(red: 0.49, green: 0.63, blue: 0.79, alpha: 1),
            roughness: 0.4,
            isMetallic: false
        )
        static let contactMaterial = SimpleMaterial(
            color: UIColor(red: 0.32, green: 0.51, blue: 0.70, alpha: 1),
            roughness: 0.36,
            isMetallic: false
        )
    }

    /// Segment diameter in meters. Proximal limbs are deliberately fuller
    /// than distal limbs so the silhouette reads as a human at phone scale.
    private static func diameter(for joint: ExerciseJoint) -> Float {
        switch joint {
        case .leftForearm, .rightForearm: return 0.085
        case .leftHand, .rightHand: return 0.068
        case .leftShin, .rightShin: return 0.125
        case .leftFoot, .rightFoot: return 0.09
        default: return 0.06
        }
    }

    private static func ellipsoid(
        size: SIMD3<Float>,
        position: SIMD3<Float> = .zero,
        orientation: simd_quatf = simd_quatf()
    ) -> ModelEntity {
        let entity = ModelEntity(mesh: Style.sphereMesh, materials: [Style.bodyMaterial])
        entity.scale = size
        entity.position = position
        entity.orientation = orientation
        return entity
    }

    private static func addMass(
        to joint: ExerciseJoint,
        joints: [ExerciseJoint: Entity],
        size: SIMD3<Float>,
        position: SIMD3<Float> = .zero
    ) {
        joints[joint]?.addChild(ellipsoid(size: size, position: position))
    }

    static func makeMannequin() -> Mannequin {
        var joints: [ExerciseJoint: Entity] = [:]

        // 1) Create a pivot entity per joint at its rest offset from parent.
        for bone in MannequinSkeleton.bones {
            let entity = Entity()
            entity.name = bone.joint.rawValue
            entity.position = bone.restOffset
            joints[bone.joint] = entity
        }
        // 2) Parent them into the hierarchy.
        for bone in MannequinSkeleton.bones {
            guard let entity = joints[bone.joint] else { continue }
            if let parent = bone.parent, let parentEntity = joints[parent] {
                parentEntity.addChild(entity)
            }
        }

        // 3) Soft anatomical masses. They overlap slightly at rest to avoid
        // background gaps while preserving every original animation pivot.
        addMass(to: .pelvis, joints: joints, size: SIMD3(0.25, 0.17, 0.17))
        addMass(to: .torso, joints: joints, size: SIMD3(0.34, 0.40, 0.20), position: SIMD3(0, 0.07, 0))
        addMass(to: .chest, joints: joints, size: SIMD3(0.38, 0.14, 0.17), position: SIMD3(0, 0.045, 0))
        addMass(to: .neck, joints: joints, size: SIMD3(0.085, 0.15, 0.08), position: SIMD3(0, 0.045, 0))
        addMass(to: .head, joints: joints, size: SIMD3(0.18, 0.23, 0.17), position: SIMD3(0, 0.055, 0.015))

        // Rounded shoulder and hip transitions are body-colored and mostly
        // buried inside adjacent masses, eliminating the old blue bead look.
        for joint in [ExerciseJoint.leftShoulder, .rightShoulder] {
            addMass(to: joint, joints: joints, size: SIMD3(0.09, 0.09, 0.09))
        }

        // 4) Organic limb ellipsoids span each animated segment. Torso,
        // shoulder and hip connector bones are represented by the masses
        // above, not by visible debug rods.
        let hiddenConnectors: Set<ExerciseJoint> = [
            .pelvis, .torso, .chest, .neck, .head,
            .leftShoulder, .rightShoulder, .leftUpperArm, .rightUpperArm,
            .leftHip, .rightHip, .leftThigh, .rightThigh,
        ]
        for bone in MannequinSkeleton.bones {
            guard !hiddenConnectors.contains(bone.joint) else { continue }
            guard let parent = bone.parent, let parentEntity = joints[parent] else { continue }
            let offset = bone.restOffset
            let length = simd_length(offset)
            guard length > 0.001 else { continue }
            let d = diameter(for: bone.joint)
            let segment = ellipsoid(
                size: SIMD3(d, length + d * 0.55, d),
                position: offset * 0.5,
                orientation: simd_quatf(from: SIMD3(0, 1, 0), to: simd_normalize(offset))
            )
            parentEntity.addChild(segment)
        }

        // 5) Subtle joint cores support readable bending without becoming
        // exposed beads. Hands and feet get directional end forms.
        for joint in [ExerciseJoint.leftForearm, .rightForearm, .leftShin, .rightShin] {
            guard let pivot = joints[joint] else { continue }
            let core = ModelEntity(mesh: Style.sphereMesh, materials: [Style.coreMaterial])
            core.scale = SIMD3(repeating: joint == .leftShin || joint == .rightShin ? 0.09 : 0.064)
            pivot.addChild(core)
        }
        for joint in [ExerciseJoint.leftHand, .rightHand] {
            guard let pivot = joints[joint] else { continue }
            let hand = ModelEntity(
                mesh: .generateBox(size: ContactGeometry.handSize, cornerRadius: 0.032),
                materials: [Style.contactMaterial]
            )
            hand.position = ContactGeometry.handOffset
            pivot.addChild(hand)
        }
        for joint in [ExerciseJoint.leftFoot, .rightFoot] {
            guard let pivot = joints[joint] else { continue }
            let foot = ModelEntity(
                mesh: .generateBox(size: ContactGeometry.footSize, cornerRadius: 0.038),
                materials: [Style.contactMaterial]
            )
            foot.position = ContactGeometry.footOffset
            pivot.addChild(foot)
        }

        let root = joints[.root] ?? Entity()
        return Mannequin(root: root, joints: joints)
    }
}
