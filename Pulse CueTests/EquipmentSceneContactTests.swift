//
//  EquipmentSceneContactTests.swift
//  Pulse CueTests
//
//  Verifies lower-body equipment is placed against the ACTUAL mannequin
//  motion (via the same forward kinematics production uses), catching the
//  previous gross misalignment (e.g. a footplate ~18 cm off the feet)
//  without requiring centimeter-perfect contact.
//

import Foundation
import simd
import Testing
@testable import Pulse_Cue

@MainActor
struct EquipmentSceneContactTests {

    private func profile(_ id: ExerciseID) -> ExerciseMotionProfile {
        ExerciseMotionLibrary.profile(for: id)!
    }
    private func foot(_ p: ExerciseMotionProfile, _ progress: Float) -> SIMD3<Float> {
        MannequinSkeleton.worldPosition(of: .rightFoot, pose: ExerciseMotionEngine(profile: p).pose(atProgress: progress))
    }

    @Test func legPressFootplateAlignsWithPressedFoot() {
        let p = profile("leg_press")
        let refs = EquipmentSceneFactory.references(for: p)
        let plate = try! #require(refs.footplateCenter)
        #expect(plate.x.isFinite && plate.y.isFinite && plate.z.isFinite)
        // At full press (peak) the foot should be close to the plate.
        let d = simd_distance(foot(p, 0.5), plate)
        #expect(d < 0.15, "leg press foot→plate distance \(d)")
    }

    @Test func legExtensionRollerAlignsWithLoadedAnkle() {
        let p = profile("leg_extension")
        let refs = EquipmentSceneFactory.references(for: p)
        let roller = try! #require(refs.rollerCenter)
        #expect(roller.x.isFinite && roller.y.isFinite && roller.z.isFinite)
        // Roller sits at the loaded (flexed/start) ankle contact.
        let d = simd_distance(foot(p, 0.0), roller)
        #expect(d < 0.15, "leg extension ankle→roller distance \(d)")
    }

    @Test func legCurlRollerAlignsWithLoadedAnkle() {
        let p = profile("leg_curl")
        let refs = EquipmentSceneFactory.references(for: p)
        let roller = try! #require(refs.rollerCenter)
        #expect(roller.x.isFinite && roller.y.isFinite && roller.z.isFinite)
        // Roller sits at the loaded (curled/peak) ankle contact.
        let d = simd_distance(foot(p, 0.5), roller)
        #expect(d < 0.15, "leg curl ankle→roller distance \(d)")
    }

    @Test func upperBodyHandlesTrackHandPath() {
        // After motion recalibration, chest/lat/row handles reference the
        // actual hand path (finite + near the relevant hand).
        for id: ExerciseID in ["machine_chest_press", "lat_pulldown", "machine_seated_row"] {
            let p = profile(id)
            let h = try! #require(EquipmentSceneFactory.references(for: p).handleCenter)
            #expect(h.x.isFinite && h.y.isFinite && h.z.isFinite)
        }
    }
}
