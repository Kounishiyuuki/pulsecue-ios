//
//  ExerciseMotionProfileTests.swift
//  Pulse CueTests
//
//  Pure (RealityKit-free) tests for the 10 MVP 3D motion profiles and the
//  interpolation engine. Uses the shared skeleton's forward kinematics to
//  assert the *defining* joint pattern of each movement by direction
//  (never degree-perfect), plus structural integrity: finite transforms,
//  seamless loop, determinism, and 1:1 mapping to Exercise / ExerciseGuide.
//

import Foundation
import simd
import Testing
@testable import Pulse_Cue

struct ExerciseMotionProfileTests {

    private static let mvpIds: [ExerciseID] = [
        "machine_chest_press", "lat_pulldown", "machine_seated_row",
        "machine_shoulder_press", "leg_press", "leg_extension",
        "leg_curl", "machine_arm_curl", "cable_triceps_pushdown",
        "machine_lateral_raise",
    ]

    // MARK: - Structural integrity

    @Test func exactlyTenProfiles() {
        #expect(ExerciseMotionLibrary.all.count == 10)
    }

    @Test func everyProfileMapsToExerciseAndGuideAndIsUnique() {
        var seen = Set<ExerciseID>()
        for profile in ExerciseMotionLibrary.all {
            #expect(seen.insert(profile.exerciseId).inserted, "duplicate \(profile.exerciseId)")
            #expect(ExerciseLibrary.isValid(profile.exerciseId), "no exercise for \(profile.exerciseId)")
            #expect(FormGuideLibrary.guide(for: profile.exerciseId) != nil, "no guide for \(profile.exerciseId)")
        }
    }

    @Test func everyGuidedMvpExerciseHasAProfile() {
        for id in Self.mvpIds {
            #expect(ExerciseMotionLibrary.hasProfile(for: id), "missing profile \(id)")
        }
    }

    @Test func durationsPositiveAndCamerasValid() {
        for profile in ExerciseMotionLibrary.all {
            #expect(profile.duration > 0)
            #expect(Exercise3DCamera.allCases.contains(profile.preferredCamera))
        }
    }

    @Test func posesAreFiniteAcrossWholeCycle() {
        for profile in ExerciseMotionLibrary.all {
            let engine = ExerciseMotionEngine(profile: profile)
            for i in 0...20 {
                let p = Float(i) / 20
                let pose = engine.pose(atProgress: p)
                #expect(pose.isFinite, "non-finite pose in \(profile.exerciseId) at \(p)")
                for joint in ExerciseJoint.allCases {
                    let q = pose[joint].quaternion
                    #expect(q.vector.x.isFinite && q.vector.y.isFinite && q.vector.z.isFinite && q.vector.w.isFinite)
                }
            }
        }
    }

    @Test func loopIsSeamlessProgressZeroEqualsOne() {
        for profile in ExerciseMotionLibrary.all {
            let engine = ExerciseMotionEngine(profile: profile)
            let a = engine.pose(atProgress: 0)
            let b = engine.pose(atProgress: 1)
            for joint in ExerciseJoint.allCases {
                #expect(abs(a[joint].x - b[joint].x) < 0.0001, "\(profile.exerciseId) \(joint) loop x")
                #expect(abs(a[joint].y - b[joint].y) < 0.0001)
                #expect(abs(a[joint].z - b[joint].z) < 0.0001)
            }
        }
    }

    @Test func interpolationIsDeterministic() {
        let engine = ExerciseMotionEngine(profile: ExerciseMotionLibrary.profile(for: "machine_chest_press")!)
        for _ in 0..<10 {
            let a = engine.pose(atProgress: 0.37)
            let b = engine.pose(atProgress: 0.37)
            #expect(a[.rightForearm] == b[.rightForearm])
        }
    }

    @Test func requiredJointsExistInSkeleton() {
        let defined = Set(MannequinSkeleton.bones.map(\.joint))
        for joint in ExerciseJoint.required {
            #expect(defined.contains(joint), "skeleton missing \(joint)")
        }
    }

    // MARK: - Semantic direction (via forward kinematics, sign only)

    private func engine(_ id: ExerciseID) -> ExerciseMotionEngine {
        ExerciseMotionEngine(profile: ExerciseMotionLibrary.profile(for: id)!)
    }
    private func handY(_ e: ExerciseMotionEngine, _ p: Float, _ j: ExerciseJoint = .rightHand) -> Float {
        MannequinSkeleton.worldPosition(of: j, pose: e.pose(atProgress: p)).y
    }
    private func handZ(_ e: ExerciseMotionEngine, _ p: Float, _ j: ExerciseJoint = .rightHand) -> Float {
        MannequinSkeleton.worldPosition(of: j, pose: e.pose(atProgress: p)).z
    }
    private func handX(_ e: ExerciseMotionEngine, _ p: Float, _ j: ExerciseJoint = .rightHand) -> Float {
        MannequinSkeleton.worldPosition(of: j, pose: e.pose(atProgress: p)).x
    }

    @Test func chestPressHandsMoveForwardOnPress() {
        let e = engine("machine_chest_press")
        #expect(handZ(e, 0.5) > handZ(e, 0.0) + 0.05) // pressed forward (+Z)
    }

    @Test func latPulldownHandsMoveDownFromOverhead() {
        let e = engine("lat_pulldown")
        #expect(handY(e, 0.0) > handY(e, 0.5) + 0.15) // start overhead, peak low
    }

    @Test func seatedRowHandsMoveTowardBody() {
        let e = engine("machine_seated_row")
        #expect(handZ(e, 0.0) > handZ(e, 0.5) + 0.05) // start forward, peak near torso
    }

    @Test func shoulderPressHandsMoveOverhead() {
        let e = engine("machine_shoulder_press")
        #expect(handY(e, 0.5) > handY(e, 0.0) + 0.1) // pressed up
    }

    @Test func legExtensionFootMovesForwardAsKneeExtends() {
        let e = engine("leg_extension")
        let z0 = MannequinSkeleton.worldPosition(of: .rightFoot, pose: e.pose(atProgress: 0)).z
        let z1 = MannequinSkeleton.worldPosition(of: .rightFoot, pose: e.pose(atProgress: 0.5)).z
        #expect(z1 > z0 + 0.1) // shin extends forward
    }

    @Test func legCurlFootMovesRearwardAsKneeFlexes() {
        let e = engine("leg_curl")
        let z0 = MannequinSkeleton.worldPosition(of: .rightFoot, pose: e.pose(atProgress: 0)).z
        let z1 = MannequinSkeleton.worldPosition(of: .rightFoot, pose: e.pose(atProgress: 0.5)).z
        #expect(z1 < z0 - 0.05) // heel curls back
    }

    @Test func armCurlHandRisesAsElbowFlexes() {
        let e = engine("machine_arm_curl")
        #expect(handY(e, 0.5) > handY(e, 0.0) + 0.1)
    }

    @Test func tricepsPushdownHandDropsAsElbowExtends() {
        let e = engine("cable_triceps_pushdown")
        #expect(handY(e, 0.0) > handY(e, 0.5) + 0.05) // forearm extends down
    }

    @Test func lateralRaiseArmsElevateLaterally() {
        let e = engine("machine_lateral_raise")
        // Right hand goes up and further out to the character's right (-X).
        #expect(handY(e, 0.5) > handY(e, 0.0) + 0.1)
        #expect(handX(e, 0.5) < handX(e, 0.0) - 0.1)
    }
}
