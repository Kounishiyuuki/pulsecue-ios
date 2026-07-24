//
//  EquipmentSceneFactory.swift
//  Pulse Cue
//
//  Minimal, procedural equipment context per exercise. Deliberately NOT
//  photorealistic: a few reused rounded boxes (seat, backrest, footplate,
//  bar, rollers) that stay visually subordinate to the mannequin. iOS
//  17-safe meshes only (box/sphere).
//
//  Placement is DERIVED from the actual motion via forward kinematics
//  (`MannequinSkeleton.worldPosition` on the profile's start/peak poses)
//  rather than magic constants, so footplates/rollers/handles line up with
//  where the limbs actually are. `references(for:)` exposes the key contact
//  geometry so tests can assert alignment without building RealityKit
//  entities.
//
//  Simplification: leg-extension / leg-curl rollers are single static boxes,
//  while a real machine's pad travels on the lever arm. They are placed at
//  the loaded contact pose and are intentionally approximate.
//

import Foundation
import RealityKit
import UIKit
import simd

@MainActor
enum EquipmentSceneFactory {

    /// Key equipment contact geometry in model space, derived from FK. Only
    /// the fields relevant to a scene are non-nil.
    struct References: Sendable {
        var footplateCenter: SIMD3<Float>?
        var rollerCenter: SIMD3<Float>?
        var handleCenter: SIMD3<Float>?
    }

    private static func foot(_ profile: ExerciseMotionProfile, _ p: Float) -> SIMD3<Float> {
        MannequinSkeleton.worldPosition(of: .rightFoot, pose: ExerciseMotionEngine(profile: profile).pose(atProgress: p))
    }
    private static func hand(_ profile: ExerciseMotionProfile, _ p: Float) -> SIMD3<Float> {
        MannequinSkeleton.worldPosition(of: .rightHand, pose: ExerciseMotionEngine(profile: profile).pose(atProgress: p))
    }

    /// Pure reference geometry for a profile (no RealityKit). Centered on
    /// x=0 so equipment is symmetric.
    static func references(for profile: ExerciseMotionProfile) -> References {
        let footStart = foot(profile, 0)
        let footPeak = foot(profile, 0.5)
        let handStart = hand(profile, 0)
        let handAvg = (hand(profile, 0) + hand(profile, 0.5)) * 0.5
        switch profile.equipmentScene {
        case .legPress:
            // Plate just beyond the fully-pressed (peak) foot, in the press
            // direction (+Z).
            return References(footplateCenter: SIMD3(0, footPeak.y, footPeak.z + 0.03))
        case .legExtension:
            // Roller at the loaded (flexed, start) ankle, slightly in front.
            return References(rollerCenter: SIMD3(0, footStart.y, footStart.z + 0.04))
        case .legCurl:
            // Roller at the loaded (curled, peak) ankle, slightly behind.
            return References(rollerCenter: SIMD3(0, footPeak.y, footPeak.z - 0.02))
        case .chestPress, .shoulderPress, .armCurl:
            return References(handleCenter: SIMD3(0, handAvg.y, handAvg.z))
        case .latPulldown:
            return References(handleCenter: SIMD3(0, handStart.y, handStart.z))
        case .seatedRow:
            return References(handleCenter: SIMD3(0, handStart.y, handStart.z))
        case .tricepsPushdown:
            return References(handleCenter: SIMD3(0, handAvg.y, handAvg.z))
        case .lateralRaise, .none:
            return References()
        }
    }

    private static var frameMaterial: SimpleMaterial {
        SimpleMaterial(color: UIColor(white: 0.35, alpha: 1.0), roughness: 0.7, isMetallic: true)
    }
    private static var padMaterial: SimpleMaterial {
        SimpleMaterial(color: UIColor(red: 0.22, green: 0.24, blue: 0.30, alpha: 1.0), roughness: 0.9, isMetallic: false)
    }

    private static func box(_ size: SIMD3<Float>, _ position: SIMD3<Float>, _ material: SimpleMaterial) -> ModelEntity {
        let e = ModelEntity(mesh: .generateBox(size: size, cornerRadius: min(size.min(), 0.05) * 0.4), materials: [material])
        e.position = position
        return e
    }

    /// Builds the equipment container for a profile, positioning parts from
    /// `references(for:)`.
    static func makeEquipment(for profile: ExerciseMotionProfile) -> Entity {
        let root = Entity()
        root.name = "equipment"
        let refs = references(for: profile)

        switch profile.equipmentScene {
        case .none, .lateralRaise:
            break // free-standing; mannequin alone reads clearly

        case .chestPress, .shoulderPress, .seatedRow, .armCurl:
            root.addChild(box(SIMD3(0.42, 0.08, 0.42), SIMD3(0, 0.86, -0.02), padMaterial)) // seat
            root.addChild(box(SIMD3(0.42, 0.5, 0.08), SIMD3(0, 1.12, -0.22), padMaterial))   // backrest
            if let h = refs.handleCenter {
                // Handles at the actual hand path.
                root.addChild(box(SIMD3(0.5, 0.05, 0.05), h, frameMaterial))
            }

        case .latPulldown:
            root.addChild(box(SIMD3(0.42, 0.08, 0.42), SIMD3(0, 0.86, -0.02), padMaterial))  // seat
            root.addChild(box(SIMD3(0.36, 0.06, 0.10), SIMD3(0, 1.85, 0.05), frameMaterial))  // thigh pad ref
            if let h = refs.handleCenter {
                // Overhead bar at the start (overhead) hand height.
                root.addChild(box(SIMD3(0.7, 0.05, 0.05), SIMD3(0, h.y + 0.06, h.z), frameMaterial))
            }

        case .legPress:
            root.addChild(box(SIMD3(0.5, 0.5, 0.08), SIMD3(0, 1.0, -0.28), padMaterial))     // backrest
            if let plate = refs.footplateCenter {
                root.addChild(box(SIMD3(0.5, 0.5, 0.06), plate, frameMaterial))              // footplate at foot path
            }

        case .legExtension, .legCurl:
            root.addChild(box(SIMD3(0.42, 0.08, 0.42), SIMD3(0, 0.86, -0.02), padMaterial))  // seat
            root.addChild(box(SIMD3(0.42, 0.5, 0.08), SIMD3(0, 1.12, -0.22), padMaterial))   // backrest
            if let roller = refs.rollerCenter {
                root.addChild(box(SIMD3(0.4, 0.09, 0.09), roller, frameMaterial))            // roller at ankle path
            }

        case .tricepsPushdown:
            root.addChild(box(SIMD3(0.05, 1.6, 0.05), SIMD3(0, 1.6, -0.05), frameMaterial))  // cable column
            if let h = refs.handleCenter {
                root.addChild(box(SIMD3(0.4, 0.04, 0.04), h, frameMaterial))                 // straight bar at hands
            }
        }
        return root
    }
}
