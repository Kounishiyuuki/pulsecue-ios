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

    private let barExercises: [ExerciseID] = [
        "machine_chest_press", "lat_pulldown", "machine_seated_row",
        "cable_triceps_pushdown", "machine_arm_curl",
    ]

    /// The bar's two world endpoints, derived from its ACTUAL rendered
    /// transform (position + orientation + runtime scale). The local
    /// endpoints are the canonical mesh ends ±L/2 on the X axis.
    private func barEndpoints(_ e: ModelEntity) -> (SIMD3<Float>, SIMD3<Float>) {
        let m = e.transformMatrix(relativeTo: nil)
        let half = EquipmentMotionBinding.barCanonicalLength / 2
        let a = m * SIMD4<Float>(half, 0, 0, 1)
        let b = m * SIMD4<Float>(-half, 0, 0, 1)
        return (SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z))
    }

    private func localPoint(_ worldPoint: SIMD3<Float>, in entity: Entity) -> SIMD3<Float> {
        let p = simd_inverse(entity.transformMatrix(relativeTo: nil))
            * SIMD4<Float>(worldPoint.x, worldPoint.y, worldPoint.z, 1)
        return SIMD3(p.x, p.y, p.z)
    }

    private func visibleEndEffectorContains(
        _ worldPoint: SIMD3<Float>,
        joint: ExerciseJoint,
        rig: Rig
    ) -> Bool {
        let local = localPoint(worldPoint, in: rig.mannequin.joints[joint]!)
        switch joint {
        case .leftHand, .rightHand:
            return MannequinFactory.ContactGeometry.contains(
                local,
                size: MannequinFactory.ContactGeometry.handSize,
                offset: MannequinFactory.ContactGeometry.handOffset
            )
        case .leftFoot, .rightFoot:
            return MannequinFactory.ContactGeometry.contains(
                local,
                size: MannequinFactory.ContactGeometry.footSize,
                offset: MannequinFactory.ContactGeometry.footOffset
            )
        default:
            return false
        }
    }

    // MARK: - Two-handed bar: endpoints/segment actually reach both hands

    @Test func barSegmentReachesBothHandsAndLengthTracksSpan() throws {
        for id in barExercises {
            let rig = makeRig(id)
            let bar = try #require(self.bar(rig), "\(id) has no bar contact")
            for p in phases {
                apply(rig, p)
                let (epA, epB) = barEndpoints(bar)
                let center = bar.position(relativeTo: nil)
                let axis = simd_normalize(epA - epB)
                let halfLen = simd_distance(epA, center)
                let lh = jointWorld(rig, .leftHand)
                let rh = jointWorld(rig, .rightHand)

                // Finite + positive length.
                #expect(halfLen.isFinite && halfLen > 0.01, "\(id) bad bar length at \(p)")

                // Actual rendered bar length ≈ hand separation + grip margin.
                // Derived from the ACTUAL entity transform and ACTUAL hands —
                // not from `barLength(...)` — so a fixed-width bar fails here.
                let actualLen = simd_distance(epA, epB)
                let sep = simd_distance(lh, rh)
                let expected = min(max(sep + 2 * EquipmentMotionBinding.barGripMargin, 0.1), 1.2)
                #expect(abs(actualLen - expected) < 0.04, "\(id) bar length \(actualLen) vs \(expected) at \(p)")

                // Each hand lies ON the bar segment (within its span, close to
                // the axis) — proves the bar REACHES the hands, not just its
                // center is near the midpoint.
                for (name, h) in [("L", lh), ("R", rh)] {
                    let v = h - center
                    let proj = simd_dot(v, axis)
                    let perp = simd_length(v - proj * axis)
                    #expect(abs(proj) <= halfLen + 0.03, "\(id) \(name) hand beyond bar end at \(p)")
                    #expect(perp < 0.06, "\(id) \(name) hand off bar line at \(p)")
                }

                // Center still near hand midpoint.
                #expect(simd_distance(center, (lh + rh) * 0.5) < 0.08, "\(id) bar center off midpoint at \(p)")
            }
        }
    }

    @Test func barLengthChangesWithHandSpan() throws {
        // Lat pulldown hand span differs between overhead start and pulled-down
        // peak, so the dynamic bar length must differ too (would fail if width
        // were fixed).
        let rig = makeRig("lat_pulldown")
        let bar = try #require(self.bar(rig))
        apply(rig, 0.0); let lenStart = { let (a, b) = barEndpoints(bar); return simd_distance(a, b) }()
        apply(rig, 0.5); let lenPeak = { let (a, b) = barEndpoints(bar); return simd_distance(a, b) }()
        let spanStart = { apply(rig, 0.0); return simd_distance(jointWorld(rig, .leftHand), jointWorld(rig, .rightHand)) }()
        let spanPeak = { apply(rig, 0.5); return simd_distance(jointWorld(rig, .leftHand), jointWorld(rig, .rightHand)) }()
        // If the hand span meaningfully changes, so must the bar length.
        if abs(spanStart - spanPeak) > 0.05 {
            #expect(abs(lenStart - lenPeak) > 0.03, "bar length did not track span change")
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

    @Test func renderedEndEffectorsOverlapTheirActualEquipmentContacts() {
        let contactExercises: [ExerciseID] = [
            "machine_chest_press", "lat_pulldown", "machine_seated_row",
            "machine_shoulder_press", "leg_press", "leg_extension", "leg_curl",
            "machine_arm_curl", "cable_triceps_pushdown",
        ]

        for id in contactExercises {
            let rig = makeRig(id)
            for p in phases {
                apply(rig, p)
                for contact in rig.scene.contacts {
                    switch contact.kind {
                    case .barBetweenHands:
                        let (a, b) = barEndpoints(contact.entity)
                        let axis = simd_normalize(a - b)
                        let center = contact.entity.position(relativeTo: nil)
                        for joint: ExerciseJoint in [.leftHand, .rightHand] {
                            let hand = jointWorld(rig, joint)
                            let pointOnBar = center + simd_dot(hand - center, axis) * axis
                            #expect(
                                visibleEndEffectorContains(pointOnBar, joint: joint, rig: rig),
                                "\(id) \(joint) visible hand misses bar at \(p)"
                            )
                        }

                    case .gripAtHand(let joint):
                        #expect(
                            visibleEndEffectorContains(
                                contact.entity.position(relativeTo: nil),
                                joint: joint,
                                rig: rig
                            ),
                            "\(id) \(joint) visible hand misses grip at \(p)"
                        )

                    case .footPlate, .ankleRoller:
                        let center = contact.entity.position(relativeTo: nil)
                        for joint: ExerciseJoint in [.leftFoot, .rightFoot] {
                            let foot = jointWorld(rig, joint)
                            let pointAcrossContact = SIMD3<Float>(foot.x, center.y, center.z)
                            #expect(
                                visibleEndEffectorContains(pointAcrossContact, joint: joint, rig: rig),
                                "\(id) \(joint) visible foot misses contact at \(p)"
                            )
                        }
                    }
                }
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

    @Test func structuralEquipmentStaysStatic() throws {
        // These exercises are expected to HAVE a seat + backrest — the test
        // must fail (not silently skip) if that structural geometry vanishes.
        for id: ExerciseID in ["machine_chest_press", "leg_extension", "machine_shoulder_press"] {
            let rig = makeRig(id)
            let seat = try #require(rig.scene.structural["seat"], "\(id) missing seat")
            let backrest = try #require(rig.scene.structural["backrest"], "\(id) missing backrest")
            apply(rig, 0.0)
            let seatA = seat.position(relativeTo: nil)
            let backA = backrest.position(relativeTo: nil)
            apply(rig, 0.5)
            #expect(simd_distance(seatA, seat.position(relativeTo: nil)) < 0.0001, "\(id) seat moved")
            #expect(simd_distance(backA, backrest.position(relativeTo: nil)) < 0.0001, "\(id) backrest moved")
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
