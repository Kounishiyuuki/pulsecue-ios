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

    struct Mannequin {
        let root: Entity
        let joints: [ExerciseJoint: Entity]
    }

    /// Approximate limb thickness per joint segment (meters), for coherent
    /// proportions. Falls back to a default.
    private static func thickness(for joint: ExerciseJoint) -> Float {
        switch joint {
        case .torso, .chest, .pelvis: return 0.16
        case .neck: return 0.07
        case .head: return 0.11
        case .leftUpperArm, .rightUpperArm, .leftForearm, .rightForearm: return 0.065
        case .leftThigh, .rightThigh: return 0.11
        case .leftShin, .rightShin: return 0.09
        case .leftHand, .rightHand, .leftFoot, .rightFoot: return 0.07
        default: return 0.06
        }
    }

    static func makeMannequin() -> Mannequin {
        let bodyMaterial = SimpleMaterial(color: UIColor(white: 0.72, alpha: 1.0), roughness: 0.9, isMetallic: false)
        let jointMaterial = SimpleMaterial(color: UIColor(red: 0.42, green: 0.52, blue: 0.85, alpha: 1.0), roughness: 0.6, isMetallic: false)

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

        // 3) Add a rounded joint sphere at every pivot.
        for bone in MannequinSkeleton.bones {
            guard let entity = joints[bone.joint] else { continue }
            let radius = max(0.03, thickness(for: bone.joint) * 0.55)
            let sphere = ModelEntity(
                mesh: .generateSphere(radius: radius),
                materials: [bone.joint == .head ? bodyMaterial : jointMaterial]
            )
            entity.addChild(sphere)
        }

        // 4) Add a limb box for every non-root bone, parented to the PARENT
        //    joint so it rotates with the parent and spans toward this joint.
        for bone in MannequinSkeleton.bones {
            guard let parent = bone.parent, let parentEntity = joints[parent] else { continue }
            let offset = bone.restOffset
            let length = simd_length(offset)
            guard length > 0.001 else { continue }
            let t = thickness(for: bone.joint)
            let box = ModelEntity(
                mesh: .generateBox(size: SIMD3(t, length, t), cornerRadius: t * 0.5),
                materials: [bodyMaterial]
            )
            // Place at the midpoint and rotate its +Y to point along `offset`.
            box.position = offset * 0.5
            box.orientation = simd_quatf(from: SIMD3(0, 1, 0), to: simd_normalize(offset))
            parentEntity.addChild(box)
        }

        let root = joints[.root] ?? Entity()
        return Mannequin(root: root, joints: joints)
    }
}
