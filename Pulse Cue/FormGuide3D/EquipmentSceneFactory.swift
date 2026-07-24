//
//  EquipmentSceneFactory.swift
//  Pulse Cue
//
//  Minimal, procedural equipment context per exercise. Deliberately NOT
//  photorealistic: a few reused rounded boxes (seat, backrest, footplate,
//  bar, rollers) that stay visually subordinate to the mannequin but make
//  the movement easier to read. iOS 17-safe meshes only (box/sphere).
//

import Foundation
import RealityKit
import UIKit
import simd

@MainActor
enum EquipmentSceneFactory {

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

    /// Builds the equipment container for a scene. Returns an empty entity
    /// for `.none`. Positions assume the standing skeleton (pelvis ≈ y 0.95,
    /// feet ≈ y 0), character facing +Z.
    static func makeEquipment(_ scene: ExerciseEquipmentScene) -> Entity {
        let root = Entity()
        root.name = "equipment"
        switch scene {
        case .none:
            break
        case .chestPress, .shoulderPress, .seatedRow, .armCurl:
            // Seat + backrest behind the torso.
            root.addChild(box(SIMD3(0.42, 0.08, 0.42), SIMD3(0, 0.86, -0.02), padMaterial)) // seat
            root.addChild(box(SIMD3(0.42, 0.5, 0.08), SIMD3(0, 1.12, -0.22), padMaterial))   // backrest
            if scene == .armCurl {
                root.addChild(box(SIMD3(0.42, 0.06, 0.28), SIMD3(0, 1.02, 0.30), padMaterial)) // arm pad
            }
        case .latPulldown:
            root.addChild(box(SIMD3(0.42, 0.08, 0.42), SIMD3(0, 0.86, -0.02), padMaterial))  // seat
            root.addChild(box(SIMD3(0.36, 0.06, 0.10), SIMD3(0, 1.85, 0.05), frameMaterial)) // overhead thigh pad ref bar
            root.addChild(box(SIMD3(0.7, 0.05, 0.05), SIMD3(0, 2.05, 0.05), frameMaterial))  // overhead bar
        case .legPress:
            root.addChild(box(SIMD3(0.5, 0.5, 0.08), SIMD3(0, 1.0, -0.28), padMaterial))     // backrest
            root.addChild(box(SIMD3(0.5, 0.5, 0.06), SIMD3(0, 0.9, 0.75), frameMaterial))    // footplate ahead
        case .legExtension, .legCurl:
            root.addChild(box(SIMD3(0.42, 0.08, 0.42), SIMD3(0, 0.86, -0.02), padMaterial))  // seat
            root.addChild(box(SIMD3(0.42, 0.5, 0.08), SIMD3(0, 1.12, -0.22), padMaterial))   // backrest
            // Ankle/shin roller in front, lower for extension, mid for curl.
            let rollerY: Float = scene == .legExtension ? 0.15 : 0.35
            root.addChild(box(SIMD3(0.4, 0.09, 0.09), SIMD3(0, rollerY, 0.55), frameMaterial))
        case .tricepsPushdown:
            root.addChild(box(SIMD3(0.05, 1.6, 0.05), SIMD3(0, 1.6, -0.05), frameMaterial))  // cable column behind
            root.addChild(box(SIMD3(0.4, 0.04, 0.04), SIMD3(0, 1.1, 0.15), frameMaterial))   // straight bar handle
        case .lateralRaise:
            break // free-standing; mannequin alone reads clearly
        }
        return root
    }
}
