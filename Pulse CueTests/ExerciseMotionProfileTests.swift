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

    @Test func skeletonHierarchyAndSymmetryStayCoherent() {
        let bones = MannequinSkeleton.bones
        #expect(bones.count == ExerciseJoint.allCases.count)
        #expect(Set(bones.map(\.joint)).count == bones.count)
        #expect(bones.filter { $0.parent == nil }.map(\.joint) == [.root])

        var preceding = Set<ExerciseJoint>()
        for bone in bones {
            if let parent = bone.parent {
                #expect(preceding.contains(parent), "\(bone.joint) parent must precede child")
            }
            #expect(bone.restOffset.x.isFinite && bone.restOffset.y.isFinite && bone.restOffset.z.isFinite)
            preceding.insert(bone.joint)
        }

        let p = MannequinSkeleton.Proportions.self
        #expect(p.shoulderHalfWidth > p.hipHalfWidth)
        #expect(p.upperArmLength > 0 && p.forearmLength > 0)
        #expect(p.thighLength > 0 && p.shinLength > 0)
        #expect(MannequinSkeleton.restOffset(of: .leftShoulder).x == -MannequinSkeleton.restOffset(of: .rightShoulder).x)
        #expect(MannequinSkeleton.restOffset(of: .leftHip).x == -MannequinSkeleton.restOffset(of: .rightHip).x)
        #expect(simd_length(MannequinSkeleton.restOffset(of: .leftForearm)) ==
                simd_length(MannequinSkeleton.restOffset(of: .rightForearm)))
        #expect(simd_length(MannequinSkeleton.restOffset(of: .leftShin)) ==
                simd_length(MannequinSkeleton.restOffset(of: .rightShin)))
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

    // MARK: - Stronger spatial constraints (torso reference)
    //
    // Torso column reference (rest): chest ≈ (0,1.25,0); the trunk spans
    // roughly |x|<0.10, |z|<0.10, y∈[0.9,1.45]. Torso front surface z≈+0.08.
    // Backrest plane ≈ z=-0.22. Shoulder rest y≈1.35.

    private let torsoFrontZ: Float = 0.08
    private let backrestZ: Float = -0.22
    private let shoulderY: Float = 1.35

    private func pos(_ e: ExerciseMotionEngine, _ p: Float, _ j: ExerciseJoint) -> SIMD3<Float> {
        MannequinSkeleton.worldPosition(of: j, pose: e.pose(atProgress: p))
    }
    /// Shoulder→hand reach (elbow-extension proxy).
    private func reach(_ e: ExerciseMotionEngine, _ p: Float) -> Float {
        simd_distance(pos(e, p, .rightShoulder), pos(e, p, .rightHand))
    }

    @Test func chestPressStaysInChestRegionAndPressesForward() {
        let e = engine("machine_chest_press")
        // Start hands near chest height (not lower abdomen).
        #expect((0.95...1.45).contains(handY(e, 0.0)))
        // Both hands stay in front of the torso surface (no penetration).
        for p: Float in [0, 0.25, 0.5, 0.75] {
            #expect(pos(e, p, .rightHand).z > torsoFrontZ)
            #expect(pos(e, p, .leftHand).z > torsoFrontZ)
        }
        // Peak is forward of start and elbows more extended.
        #expect(handZ(e, 0.5) > handZ(e, 0.0))
        #expect(reach(e, 0.5) > reach(e, 0.0))
    }

    @Test func latPulldownStartsOverheadEndsUpperChestInFront() {
        let e = engine("lat_pulldown")
        // Start hands above the shoulders (overhead).
        #expect(handY(e, 0.0) > shoulderY)
        // Peak below start, but above a conservative lower-torso boundary
        // (not pelvis level ≈ 0.95).
        #expect(handY(e, 0.5) < handY(e, 0.0))
        #expect(handY(e, 0.5) > 1.0)
        // Hands remain in front of / aligned with the trunk (not behind).
        for p: Float in [0, 0.25, 0.5] {
            #expect(pos(e, p, .rightHand).z > -0.05)
        }
    }

    @Test func seatedRowApproachesTorsoWithoutPenetrating() {
        let e = engine("machine_seated_row")
        // Start hands well forward.
        #expect(handZ(e, 0.0) > 0.30)
        // Peak closer to torso than start, but stops in front of the torso
        // surface and never reaches behind the backrest.
        #expect(handZ(e, 0.5) < handZ(e, 0.0))
        for p: Float in [0, 0.25, 0.5, 0.75] {
            #expect(pos(e, p, .rightHand).z > torsoFrontZ)   // no torso penetration
            #expect(pos(e, p, .rightHand).z > backrestZ)     // not behind backrest
        }
    }

    @Test func legPressExtendsFromFlexedTowardPlate() {
        let e = engine("leg_press")
        let startShin = e.pose(atProgress: 0)[.rightShin].x
        let peakShin = e.pose(atProgress: 0.5)[.rightShin].x
        // Knee moves from more-flexed toward more-extended…
        #expect(peakShin < startShin)
        // …but not into hyperextension (shin stays flexed past straight).
        #expect(peakShin > 0.2)
        // Feet move toward the plate direction (+Z).
        let footStartZ = pos(e, 0, .rightFoot).z
        let footPeakZ = pos(e, 0.5, .rightFoot).z
        #expect(footPeakZ > footStartZ + 0.1)
        // Finite + loop-compatible endpoints.
        #expect(pos(e, 0, .rightFoot).x.isFinite && pos(e, 1, .rightFoot).z.isFinite)
        #expect(abs(pos(e, 0, .rightFoot).z - pos(e, 1, .rightFoot).z) < 0.0001)
    }
}
