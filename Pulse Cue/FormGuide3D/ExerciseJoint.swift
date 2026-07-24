//
//  ExerciseJoint.swift
//  Pulse Cue
//
//  Pure, RealityKit-independent joint vocabulary shared by the procedural
//  mannequin and the motion engine. Keeping the joint names and the pose
//  math here (with no `import RealityKit`) lets the motion math be unit
//  tested without a renderer, and gives a clean seam so a future rigged
//  USDZ model can be driven by the same `ExercisePose` values.
//
//  Angles are in radians. Rotations are local to each joint's parent, so
//  limbs bend around anatomically useful pivots rather than moving in
//  world space.
//

import Foundation
import simd

/// Named articulated joints of the reusable mannequin. `root`/`pelvis` sit
/// at the base; limbs hang off `chest` and `pelvis`. Every joint a motion
/// profile may drive must exist here.
enum ExerciseJoint: String, CaseIterable, Hashable, Sendable {
    case root
    case pelvis
    case torso        // lower spine
    case chest        // upper spine (arms attach here)
    case neck
    case head

    case leftShoulder
    case leftUpperArm
    case leftForearm
    case leftHand

    case rightShoulder
    case rightUpperArm
    case rightForearm
    case rightHand

    case leftHip
    case leftThigh
    case leftShin
    case leftFoot

    case rightHip
    case rightThigh
    case rightShin
    case rightFoot

    /// Joints an articulated mannequin is required to expose. Used by tests
    /// to assert the hierarchy is complete.
    static var required: [ExerciseJoint] { allCases }
}

/// A single joint's local rotation as Euler angles (radians) applied in
/// X→Y→Z order. Euler is used (not quaternions) because the authored
/// profiles read far more clearly as "bend the elbow 90°" and the engine
/// converts to a quaternion deterministically.
struct JointRotation: Equatable, Sendable {
    var x: Float
    var y: Float
    var z: Float

    init(x: Float = 0, y: Float = 0, z: Float = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    static let identity = JointRotation()

    /// All-finite guard used by tests (no NaN / infinity leaks into a pose).
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }

    /// Component-wise linear interpolation.
    static func lerp(_ a: JointRotation, _ b: JointRotation, _ t: Float) -> JointRotation {
        JointRotation(
            x: a.x + (b.x - a.x) * t,
            y: a.y + (b.y - a.y) * t,
            z: a.z + (b.z - a.z) * t
        )
    }

    /// Deterministic quaternion for the renderer. X→Y→Z intrinsic order.
    var quaternion: simd_quatf {
        let qx = simd_quatf(angle: x, axis: SIMD3<Float>(1, 0, 0))
        let qy = simd_quatf(angle: y, axis: SIMD3<Float>(0, 1, 0))
        let qz = simd_quatf(angle: z, axis: SIMD3<Float>(0, 0, 1))
        return qx * qy * qz
    }
}

/// A complete mannequin pose: the local rotation for every driven joint at
/// one instant. Joints absent from `rotations` render at their rest pose.
struct ExercisePose: Equatable, Sendable {
    var rotations: [ExerciseJoint: JointRotation]

    init(_ rotations: [ExerciseJoint: JointRotation] = [:]) {
        self.rotations = rotations
    }

    subscript(_ joint: ExerciseJoint) -> JointRotation {
        rotations[joint] ?? .identity
    }

    /// True when every rotation is finite. Tests assert this for every
    /// sampled pose across the whole cycle.
    var isFinite: Bool { rotations.values.allSatisfy(\.isFinite) }

    /// Per-joint interpolation between two poses. Joints present in either
    /// side interpolate from/to identity as needed, so keyframes need only
    /// list the joints they actually move.
    static func lerp(_ a: ExercisePose, _ b: ExercisePose, _ t: Float) -> ExercisePose {
        var keys = Set(a.rotations.keys)
        keys.formUnion(b.rotations.keys)
        var result: [ExerciseJoint: JointRotation] = [:]
        for joint in keys {
            result[joint] = JointRotation.lerp(a[joint], b[joint], t)
        }
        return ExercisePose(result)
    }
}
