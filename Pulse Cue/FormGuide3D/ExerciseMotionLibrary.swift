//
//  ExerciseMotionLibrary.swift
//  Pulse Cue
//
//  The 10 MVP movement profiles, one per existing text-guided exercise.
//  Each is a looping start→peak→start cycle authored as joint rotations
//  (radians) against the shared `MannequinSkeleton` convention. Values are
//  conservative and intended as a *movement reference*, not a biomechanical
//  claim. Keyed by the real stable `ExerciseID`s already in
//  `ExerciseLibrary`; exercises outside these 10 simply have no profile and
//  fall back to the text-only guide.
//

import Foundation

enum ExerciseMotionLibrary {

    // MARK: - Pose authoring helpers

    private typealias R = JointRotation

    /// Merge partial joint dictionaries into one pose.
    private static func pose(_ parts: [ExerciseJoint: JointRotation]...) -> ExercisePose {
        var merged: [ExerciseJoint: JointRotation] = [:]
        for part in parts { merged.merge(part) { _, new in new } }
        return ExercisePose(merged)
    }

    /// Seated lower body: hips flexed forward, knees bent so shins drop.
    private static func seatedLegs(thigh: Float = -1.35, shin: Float = 1.35) -> [ExerciseJoint: JointRotation] {
        [.leftThigh: R(x: thigh), .rightThigh: R(x: thigh),
         .leftShin: R(x: shin), .rightShin: R(x: shin)]
    }

    /// Symmetric arms: same X for both, mirrored Z (abduction) — right arm
    /// takes -z, left arm +z.
    private static func arms(upperX: Float = 0, upperZ: Float = 0, foreX: Float = 0) -> [ExerciseJoint: JointRotation] {
        [.rightUpperArm: R(x: upperX, z: -upperZ), .leftUpperArm: R(x: upperX, z: upperZ),
         .rightForearm: R(x: foreX), .leftForearm: R(x: foreX)]
    }

    // MARK: - Library

    static let all: [ExerciseMotionProfile] = [
        chestPress, latPulldown, seatedRow, shoulderPress, legPress,
        legExtension, legCurl, armCurl, tricepsPushdown, lateralRaise,
    ]

    private static let byId: [ExerciseID: ExerciseMotionProfile] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.exerciseId, $0) })
    }()

    static func profile(for id: ExerciseID) -> ExerciseMotionProfile? { byId[id] }
    static func profile(for id: ExerciseID?) -> ExerciseMotionProfile? { id.flatMap { byId[$0] } }
    static func hasProfile(for id: ExerciseID?) -> Bool { profile(for: id) != nil }

    // MARK: - Profiles (start → peak → start)

    /// Chest press: seated, elbows bent with hands back at chest, press
    /// straight forward until arms extend, controlled return.
    private static let chestPress = ExerciseMotionProfile(
        exerciseId: "machine_chest_press", duration: 2.6,
        preferredCamera: .side, equipmentScene: .chestPress,
        keyframes: loop(
            start: pose(seatedLegs(), arms(upperX: -1.4, upperZ: 0.5, foreX: 1.4)),
            peak: pose(seatedLegs(), arms(upperX: -1.5, upperZ: 0.2, foreX: 0.0))
        )
    )

    /// Lat pulldown: arms overhead and straight, pull down so elbows drive
    /// down and hands reach the upper chest, controlled overhead return.
    private static let latPulldown = ExerciseMotionProfile(
        exerciseId: "lat_pulldown", duration: 2.8,
        preferredCamera: .front, equipmentScene: .latPulldown,
        keyframes: loop(
            start: pose(seatedLegs(), arms(upperX: -2.8, upperZ: 0.3, foreX: 0.0)),
            peak: pose(seatedLegs(), arms(upperX: -0.6, upperZ: 0.4, foreX: 1.3))
        )
    )

    /// Seated row: arms forward and extended, pull elbows rearward until
    /// hands approach the torso, controlled extension.
    private static let seatedRow = ExerciseMotionProfile(
        exerciseId: "machine_seated_row", duration: 2.6,
        preferredCamera: .side, equipmentScene: .seatedRow,
        keyframes: loop(
            start: pose(seatedLegs(), arms(upperX: -1.3, upperZ: 0.2, foreX: 0.0)),
            peak: pose(seatedLegs(), arms(upperX: -0.3, upperZ: 0.2, foreX: 1.6))
        )
    )

    /// Shoulder press: elbows flexed near shoulder height, press overhead
    /// until arms extend upward, controlled return.
    private static let shoulderPress = ExerciseMotionProfile(
        exerciseId: "machine_shoulder_press", duration: 2.6,
        preferredCamera: .front, equipmentScene: .shoulderPress,
        keyframes: loop(
            start: pose(seatedLegs(), arms(upperX: -0.1, upperZ: 1.35, foreX: -1.4)),
            peak: pose(seatedLegs(), arms(upperX: -0.05, upperZ: 2.6, foreX: 0.0))
        )
    )

    /// Leg press: reclined, hips/knees deeply flexed, extend legs toward the
    /// footplate without snapping to a locked knee.
    private static let legPress = ExerciseMotionProfile(
        exerciseId: "leg_press", duration: 2.8,
        preferredCamera: .side, equipmentScene: .legPress,
        keyframes: loop(
            start: pose([.torso: R(x: -0.3)], seatedLegs(thigh: -1.6, shin: 1.7)),
            peak: pose([.torso: R(x: -0.3)], seatedLegs(thigh: -1.2, shin: 0.5))
        )
    )

    /// Leg extension: seated thigh fixed, knee extends the shin forward,
    /// controlled return.
    private static let legExtension = ExerciseMotionProfile(
        exerciseId: "leg_extension", duration: 2.4,
        preferredCamera: .side, equipmentScene: .legExtension,
        keyframes: loop(
            start: pose(seatedLegs(thigh: -1.35, shin: 1.5)),
            peak: pose(seatedLegs(thigh: -1.35, shin: 0.1))
        )
    )

    /// Leg curl: seated thigh fixed, knee flexes the shin rearward,
    /// controlled return.
    private static let legCurl = ExerciseMotionProfile(
        exerciseId: "leg_curl", duration: 2.4,
        preferredCamera: .side, equipmentScene: .legCurl,
        keyframes: loop(
            start: pose(seatedLegs(thigh: -1.35, shin: 0.3)),
            peak: pose(seatedLegs(thigh: -1.35, shin: 1.6))
        )
    )

    /// Machine arm curl: upper arms fixed on the pad, elbows flex the
    /// forearms up, controlled extension.
    private static let armCurl = ExerciseMotionProfile(
        exerciseId: "machine_arm_curl", duration: 2.4,
        preferredCamera: .threeQuarter, equipmentScene: .armCurl,
        keyframes: loop(
            start: pose(seatedLegs(), arms(upperX: -0.6, upperZ: 0.15, foreX: -0.2)),
            peak: pose(seatedLegs(), arms(upperX: -0.6, upperZ: 0.15, foreX: -1.7))
        )
    )

    /// Cable triceps pushdown: standing, upper arms close to the torso,
    /// elbows extend the forearms down, controlled flexion return.
    private static let tricepsPushdown = ExerciseMotionProfile(
        exerciseId: "cable_triceps_pushdown", duration: 2.4,
        preferredCamera: .side, equipmentScene: .tricepsPushdown,
        keyframes: loop(
            start: pose(arms(upperX: -0.15, upperZ: 0.1, foreX: -1.5)),
            peak: pose(arms(upperX: -0.15, upperZ: 0.1, foreX: -0.1))
        )
    )

    /// Lateral raise: standing, arms elevate laterally to about shoulder
    /// height (not overhead), controlled lowering.
    private static let lateralRaise = ExerciseMotionProfile(
        exerciseId: "machine_lateral_raise", duration: 2.6,
        preferredCamera: .front, equipmentScene: .lateralRaise,
        keyframes: loop(
            start: pose(arms(upperX: -0.1, upperZ: 0.05, foreX: 0.0)),
            peak: pose(arms(upperX: -0.1, upperZ: 1.5, foreX: 0.0))
        )
    )

    /// Builds a seamless 3-keyframe loop: start(0) → peak(0.5) → start(1).
    private static func loop(start: ExercisePose, peak: ExercisePose) -> [MotionKeyframe] {
        [
            MotionKeyframe(progress: 0.0, pose: start),
            MotionKeyframe(progress: 0.5, pose: peak),
            MotionKeyframe(progress: 1.0, pose: start),
        ]
    }
}
