//
//  MannequinSkeleton.swift
//  Pulse Cue
//
//  Pure (RealityKit-independent) definition of the reusable mannequin's
//  rest skeleton: each joint's parent and its local rest offset from that
//  parent, in meters. Both the procedural RealityKit mannequin and the
//  unit-testable forward-kinematics helper read these SAME offsets, so a
//  motion profile authored against joint rotations produces a consistent
//  result in the renderer and in tests.
//
//  Convention: character faces +Z (front camera looks down -Z toward it),
//  up is +Y. The character's LEFT is +X and its RIGHT is -X. Arms hang
//  down at rest (forearm/hand offsets point -Y), so a neutral pose is a
//  standing figure with arms at the sides.
//

import Foundation
import simd

enum MannequinSkeleton {

    /// Local rest offset of a joint from its parent (meters). `root` has no
    /// parent (nil).
    struct Bone {
        let joint: ExerciseJoint
        let parent: ExerciseJoint?
        let restOffset: SIMD3<Float>
    }

    /// Ordered so every parent precedes its children (root first). Roughly
    /// human proportions for a ~1.7 m figure.
    static let bones: [Bone] = [
        Bone(joint: .root,  parent: nil,      restOffset: SIMD3(0, 0, 0)),
        Bone(joint: .pelvis, parent: .root,   restOffset: SIMD3(0, 0.95, 0)),
        Bone(joint: .torso,  parent: .pelvis, restOffset: SIMD3(0, 0.12, 0)),
        Bone(joint: .chest,  parent: .torso,  restOffset: SIMD3(0, 0.18, 0)),
        Bone(joint: .neck,   parent: .chest,  restOffset: SIMD3(0, 0.16, 0)),
        Bone(joint: .head,   parent: .neck,   restOffset: SIMD3(0, 0.12, 0)),

        // Character right side (-X)
        Bone(joint: .rightShoulder, parent: .chest,         restOffset: SIMD3(-0.17, 0.10, 0)),
        Bone(joint: .rightUpperArm, parent: .rightShoulder, restOffset: SIMD3(-0.05, 0, 0)),
        Bone(joint: .rightForearm,  parent: .rightUpperArm, restOffset: SIMD3(0, -0.28, 0)),
        Bone(joint: .rightHand,     parent: .rightForearm,  restOffset: SIMD3(0, -0.25, 0)),

        // Character left side (+X)
        Bone(joint: .leftShoulder, parent: .chest,        restOffset: SIMD3(0.17, 0.10, 0)),
        Bone(joint: .leftUpperArm, parent: .leftShoulder, restOffset: SIMD3(0.05, 0, 0)),
        Bone(joint: .leftForearm,  parent: .leftUpperArm, restOffset: SIMD3(0, -0.28, 0)),
        Bone(joint: .leftHand,     parent: .leftForearm,  restOffset: SIMD3(0, -0.25, 0)),

        Bone(joint: .rightHip,   parent: .pelvis,     restOffset: SIMD3(-0.10, 0, 0)),
        Bone(joint: .rightThigh, parent: .rightHip,   restOffset: SIMD3(0, -0.02, 0)),
        Bone(joint: .rightShin,  parent: .rightThigh, restOffset: SIMD3(0, -0.45, 0)),
        Bone(joint: .rightFoot,  parent: .rightShin,  restOffset: SIMD3(0, -0.42, 0)),

        Bone(joint: .leftHip,   parent: .pelvis,    restOffset: SIMD3(0.10, 0, 0)),
        Bone(joint: .leftThigh, parent: .leftHip,   restOffset: SIMD3(0, -0.02, 0)),
        Bone(joint: .leftShin,  parent: .leftThigh, restOffset: SIMD3(0, -0.45, 0)),
        Bone(joint: .leftFoot,  parent: .leftShin,  restOffset: SIMD3(0, -0.42, 0)),
    ]

    static let boneByJoint: [ExerciseJoint: Bone] = {
        Dictionary(uniqueKeysWithValues: bones.map { ($0.joint, $0) })
    }()

    static func parent(of joint: ExerciseJoint) -> ExerciseJoint? {
        boneByJoint[joint]?.parent
    }

    static func restOffset(of joint: ExerciseJoint) -> SIMD3<Float> {
        boneByJoint[joint]?.restOffset ?? .zero
    }

    // MARK: - Pure forward kinematics (for tests + camera framing)

    /// World-space transform of a joint under `pose`, walking the parent
    /// chain. Each joint contributes `translate(restOffset) * rotate(pose)`.
    /// Pure — no RealityKit — so motion semantics are unit testable.
    static func worldTransform(of joint: ExerciseJoint, pose: ExercisePose) -> simd_float4x4 {
        var chain: [ExerciseJoint] = []
        var current: ExerciseJoint? = joint
        while let j = current {
            chain.append(j)
            current = parent(of: j)
        }
        var transform = matrix_identity_float4x4
        for j in chain.reversed() {
            let t = translation(restOffset(of: j))
            let r = simd_float4x4(pose[j].quaternion)
            transform = transform * t * r
        }
        return transform
    }

    /// World-space position of a joint under `pose`.
    static func worldPosition(of joint: ExerciseJoint, pose: ExercisePose) -> SIMD3<Float> {
        let m = worldTransform(of: joint, pose: pose)
        return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    private static func translation(_ v: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(v.x, v.y, v.z, 1)
        return m
    }
}
