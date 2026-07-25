//
//  EquipmentSceneFactory.swift
//  Pulse Cue
//
//  Procedural equipment context, split into two kinds:
//
//   - STRUCTURAL (static): seat, backrest, cable tower, thigh pad — fixed
//     reference geometry that never moves.
//   - CONTACT (dynamic): the part the user actually grips/pushes (handle,
//     bar, footplate, roller). On a real machine these are moving components,
//     so they FOLLOW the exercise: each frame their transform is driven from
//     the SAME `ExercisePose` the mannequin uses (see `EquipmentMotionBinding`),
//     via the one existing `SceneEvents.Update` clock — no extra timers.
//
//  iOS 17-safe meshes only (box/sphere). Shoulder press uses two per-hand
//  grips instead of a center bar so nothing crosses the head.
//

import Foundation
import RealityKit
import UIKit
import simd

/// How a dynamic contact entity tracks the mannequin each frame.
enum EquipmentContactKind: Sendable {
    /// One bar spanning both hands (midpoint + orientation + width).
    case barBetweenHands
    /// A small grip pinned to a single hand joint (avoids center-crossing).
    case gripAtHand(ExerciseJoint)
    /// A plate at the feet midpoint, nudged in the press (+Z) direction.
    case footPlate
    /// A roller at the ankle midpoint, nudged by `dz` along Z.
    case ankleRoller(dz: Float)
}

@MainActor
struct EquipmentContact {
    let entity: ModelEntity
    let kind: EquipmentContactKind
}

@MainActor
enum EquipmentSceneFactory {

    struct Scene {
        let root: Entity
        /// Dynamic contact parts, updated every frame by `EquipmentMotionBinding`.
        let contacts: [EquipmentContact]
        /// Structural parts by name, exposed so tests can assert they stay put.
        let structural: [String: Entity]
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

    /// A two-hand bar at the canonical (unscaled) length. Its X axis is later
    /// scaled by `EquipmentMotionBinding` to match the actual hand span, so
    /// the mesh is created ONCE (never per frame).
    private static func barMesh() -> ModelEntity {
        box(SIMD3(EquipmentMotionBinding.barCanonicalLength, 0.05, 0.05), .zero, frameMaterial)
    }

    /// Builds the equipment scene for a profile: static structural parts plus
    /// dynamic contact parts (positioned initially via the binding at the
    /// start pose).
    static func makeScene(for profile: ExerciseMotionProfile) -> Scene {
        let root = Entity()
        root.name = "equipment"
        var contacts: [EquipmentContact] = []
        var structural: [String: Entity] = [:]

        func addStructural(_ name: String, _ e: ModelEntity) {
            e.name = name
            structural[name] = e
            root.addChild(e)
        }
        func addContact(_ e: ModelEntity, _ kind: EquipmentContactKind) {
            root.addChild(e)
            contacts.append(EquipmentContact(entity: e, kind: kind))
        }

        switch profile.equipmentScene {
        case .none, .lateralRaise:
            break // free-standing; mannequin alone reads clearly

        case .chestPress, .seatedRow:
            addStructural("seat", box(SIMD3(0.42, 0.08, 0.42), SIMD3(0, 0.86, -0.02), padMaterial))
            addStructural("backrest", box(SIMD3(0.42, 0.5, 0.08), SIMD3(0, 1.12, -0.22), padMaterial))
            addContact(barMesh(), .barBetweenHands)

        case .armCurl:
            addStructural("seat", box(SIMD3(0.42, 0.08, 0.42), SIMD3(0, 0.86, -0.02), padMaterial))
            addStructural("backrest", box(SIMD3(0.42, 0.5, 0.08), SIMD3(0, 1.12, -0.22), padMaterial))
            addStructural("armpad", box(SIMD3(0.42, 0.06, 0.28), SIMD3(0, 1.02, 0.30), padMaterial))
            addContact(barMesh(), .barBetweenHands)

        case .shoulderPress:
            addStructural("seat", box(SIMD3(0.42, 0.08, 0.42), SIMD3(0, 0.86, -0.02), padMaterial))
            addStructural("backrest", box(SIMD3(0.42, 0.5, 0.08), SIMD3(0, 1.12, -0.22), padMaterial))
            // Two per-hand grips — no center bar, so nothing crosses the head.
            addContact(box(SIMD3(0.09, 0.06, 0.06), .zero, frameMaterial), .gripAtHand(.leftHand))
            addContact(box(SIMD3(0.09, 0.06, 0.06), .zero, frameMaterial), .gripAtHand(.rightHand))

        case .latPulldown:
            addStructural("seat", box(SIMD3(0.42, 0.08, 0.42), SIMD3(0, 0.86, -0.02), padMaterial))
            // Thigh pad sits just over the seated lap (holds the thighs down),
            // not up at chest height.
            addStructural("thighPad", box(SIMD3(0.36, 0.06, 0.16), SIMD3(0, 0.98, 0.30), padMaterial))
            // Bar follows the hands down through the pulldown (not fixed overhead).
            addContact(barMesh(), .barBetweenHands)

        case .legPress:
            addStructural("backrest", box(SIMD3(0.5, 0.5, 0.08), SIMD3(0, 1.0, -0.28), padMaterial))
            addContact(box(SIMD3(0.5, 0.5, 0.06), .zero, frameMaterial), .footPlate)

        case .legExtension:
            addStructural("seat", box(SIMD3(0.42, 0.08, 0.42), SIMD3(0, 0.86, -0.02), padMaterial))
            addStructural("backrest", box(SIMD3(0.42, 0.5, 0.08), SIMD3(0, 1.12, -0.22), padMaterial))
            addContact(box(SIMD3(0.4, 0.09, 0.09), .zero, frameMaterial), .ankleRoller(dz: 0.04))

        case .legCurl:
            addStructural("seat", box(SIMD3(0.42, 0.08, 0.42), SIMD3(0, 0.86, -0.02), padMaterial))
            addStructural("backrest", box(SIMD3(0.42, 0.5, 0.08), SIMD3(0, 1.12, -0.22), padMaterial))
            addContact(box(SIMD3(0.4, 0.09, 0.09), .zero, frameMaterial), .ankleRoller(dz: -0.02))

        case .tricepsPushdown:
            addStructural("tower", box(SIMD3(0.05, 1.6, 0.05), SIMD3(0, 1.6, -0.05), frameMaterial))
            addContact(barMesh(), .barBetweenHands)
        }

        return Scene(root: root, contacts: contacts, structural: structural)
    }
}
