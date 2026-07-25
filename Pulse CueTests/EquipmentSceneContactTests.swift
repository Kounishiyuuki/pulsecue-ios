//
//  EquipmentSceneContactTests.swift
//  Pulse CueTests
//
//  NON-CIRCULAR equipment-contact tests. Instead of comparing two values
//  both derived from the same FK helper, these build the ACTUAL production
//  scene — real mannequin entity hierarchy + real EquipmentSceneFactory
//  result + the real EquipmentMotionBinding — apply representative poses,
//  then read the ACTUAL RealityKit entity world transforms and compare the
//  mannequin's rendered contact joint against the equipment entity.
//
//  They also assert dynamic contact equipment actually MOVES across the
//  cycle (no false green from a static reference point) while structural
//  parts (seat/backrest) stay put, plus head/torso clearance guards.
//

import Foundation
import RealityKit
import simd
import Testing
@testable import Pulse_Cue

@MainActor
struct EquipmentSceneContactTests {

    // MARK: - Harness: real scene, real entity transforms

    private struct Rig {
        let mannequin: MannequinFactory.Mannequin
        let scene: EquipmentSceneFactory.Scene
        let engine: ExerciseMotionEngine
    }

    private func makeRig(_ id: ExerciseID) -> Rig {
        let profile = ExerciseMotionLibrary.profile(for: id)!
        return Rig(
            mannequin: MannequinFactory.makeMannequin(),
            scene: EquipmentSceneFactory.makeScene(for: profile),
            engine: ExerciseMotionEngine(profile: profile)
        )
    }

    /// Poses the real mannequin entities AND runs the real binding, exactly
    /// like the controller's per-frame `applyPose`.
    private func apply(_ rig: Rig, _ progress: Float) {
        let pose = rig.engine.pose(atProgress: progress)
        for (joint, entity) in rig.mannequin.joints {
            entity.orientation = pose[joint].quaternion
        }
        EquipmentMotionBinding.update(rig.scene.contacts, pose: pose)
    }

    /// Rendered world position of a mannequin joint (RealityKit-computed,
    /// independent of the binding's FK helper).
    private func jointWorld(_ rig: Rig, _ j: ExerciseJoint) -> SIMD3<Float> {
        rig.mannequin.joints[j]!.position(relativeTo: nil)
    }
    private func handMidWorld(_ rig: Rig) -> SIMD3<Float> {
        (jointWorld(rig, .leftHand) + jointWorld(rig, .rightHand)) * 0.5
    }
    private func footMidWorld(_ rig: Rig) -> SIMD3<Float> {
        (jointWorld(rig, .leftFoot) + jointWorld(rig, .rightFoot)) * 0.5
    }

    private func contact(_ rig: Rig, _ match: (EquipmentContactKind) -> Bool) -> ModelEntity? {
        rig.scene.contacts.first { match($0.kind) }?.entity
    }
    private func bar(_ rig: Rig) -> ModelEntity? {
        contact(rig) { if case .barBetweenHands = $0 { return true }; return false }
    }
    private func plate(_ rig: Rig) -> ModelEntity? {
        contact(rig) { if case .footPlate = $0 { return true }; return false }
    }
    private func roller(_ rig: Rig) -> ModelEntity? {
        contact(rig) { if case .ankleRoller = $0 { return true }; return false }
    }

    private let phases: [Float] = [0.0, 0.25, 0.5, 0.75]

    // MARK: - Two-handed bars follow hands (chest / lat / row / triceps / arm curl)

    @Test func barFollowsHandsAcrossCycle() throws {
        for id: ExerciseID in ["machine_chest_press", "lat_pulldown", "machine_seated_row",
                               "cable_triceps_pushdown", "machine_arm_curl"] {
            let rig = makeRig(id)
            let b = try #require(bar(rig), "\(id) has no bar contact")
            for p in phases {
                apply(rig, p)
                let d = simd_distance(b.position(relativeTo: nil), handMidWorld(rig))
                #expect(d < 0.10, "\(id) bar↔hands \(d) at \(p)")
            }
        }
    }

    @Test func latBarDoesNotStayOverheadAndFollowsDown() throws {
        let rig = makeRig("lat_pulldown")
        let b = try #require(bar(rig))
        apply(rig, 0.0); let startY = b.position(relativeTo: nil).y
        apply(rig, 0.5); let peakY = b.position(relativeTo: nil).y
        #expect(startY > peakY + 0.2, "lat bar did not descend: \(startY)→\(peakY)")
    }

    @Test func chestAndRowBarStayInFrontOfTorso() throws {
        for id: ExerciseID in ["machine_chest_press", "machine_seated_row"] {
            let rig = makeRig(id)
            let b = try #require(bar(rig))
            for p in phases {
                apply(rig, p)
                #expect(b.position(relativeTo: nil).z > 0.08, "\(id) bar entered torso at \(p)")
            }
        }
    }

    // MARK: - Shoulder press: per-hand grips, head clearance

    @Test func shoulderPressGripsFollowHandsAndClearHead() {
        let rig = makeRig("machine_shoulder_press")
        let grips = rig.scene.contacts.filter { if case .gripAtHand = $0.kind { return true }; return false }
        #expect(grips.count == 2)
        for p in phases {
            apply(rig, p)
            let head = jointWorld(rig, .head)
            for g in grips {
                // Grip sits at its hand…
                if case .gripAtHand(let j) = g.kind {
                    let d = simd_distance(g.entity.position(relativeTo: nil), jointWorld(rig, j))
                    #expect(d < 0.02, "grip detached from hand at \(p)")
                }
                // …and never occupies the head region.
                #expect(simd_distance(g.entity.position(relativeTo: nil), head) > 0.12,
                        "shoulder press grip near head at \(p)")
            }
        }
    }

    // MARK: - Leg press / extension / curl contact

    @Test func legPressPlateFollowsFeet() throws {
        let rig = makeRig("leg_press")
        let pl = try #require(plate(rig))
        for p in phases {
            apply(rig, p)
            let d = simd_distance(pl.position(relativeTo: nil), footMidWorld(rig))
            #expect(d < 0.12, "leg press plate↔feet \(d) at \(p)")
        }
    }

    @Test func legExtensionAndCurlRollerFollowAnkle() throws {
        for id: ExerciseID in ["leg_extension", "leg_curl"] {
            let rig = makeRig(id)
            let r = try #require(roller(rig))
            for p in phases {
                apply(rig, p)
                let d = simd_distance(r.position(relativeTo: nil), footMidWorld(rig))
                #expect(d < 0.12, "\(id) roller↔ankle \(d) at \(p)")
            }
        }
    }

    // MARK: - Anti-circularity: dynamic moves, structural stays

    @Test func dynamicContactActuallyMovesAcrossCycle() throws {
        // A footplate/roller/bar must occupy DIFFERENT positions at start vs
        // peak — otherwise a static reference could pass the contact test.
        for id: ExerciseID in ["machine_chest_press", "lat_pulldown", "leg_press", "leg_extension"] {
            let rig = makeRig(id)
            let e = try #require(bar(rig) ?? plate(rig) ?? roller(rig))
            apply(rig, 0.0); let a = e.position(relativeTo: nil)
            apply(rig, 0.5); let b = e.position(relativeTo: nil)
            #expect(simd_distance(a, b) > 0.05, "\(id) contact did not move")
        }
    }

    @Test func structuralEquipmentStaysStatic() {
        for id: ExerciseID in ["machine_chest_press", "leg_extension", "machine_shoulder_press"] {
            let rig = makeRig(id)
            guard let seat = rig.scene.structural["seat"] else { continue }
            apply(rig, 0.0); let a = seat.position(relativeTo: nil)
            apply(rig, 0.5); let b = seat.position(relativeTo: nil)
            #expect(simd_distance(a, b) < 0.0001, "\(id) seat moved")
        }
    }

    // MARK: - Finiteness

    @Test func contactTransformsAreFinite() {
        for profile in ExerciseMotionLibrary.all {
            let rig = makeRig(profile.exerciseId)
            for p in phases {
                apply(rig, p)
                for c in rig.scene.contacts {
                    let pos = c.entity.position(relativeTo: nil)
                    #expect(pos.x.isFinite && pos.y.isFinite && pos.z.isFinite)
                }
            }
        }
    }
}
