//
//  OrbitCameraState.swift
//  Pulse Cue
//
//  Pure, testable orbit-camera state (azimuth / elevation / distance) for
//  the Form Guide 3D viewer. Extracted from the RealityKit controller so
//  the gesture math is unit tested without UIKit gesture injection.
//
//  Gesture contract (fixes the cumulative-value bug): a drag/pinch reports
//  a CUMULATIVE value each event. We therefore apply it against a baseline
//  captured at gesture start — `baseline.dragged(byTotal:)` /
//  `baseline.zoomed(byMagnification:)` — so the result depends only on the
//  final cumulative value, not on how many events delivered it (frequency-
//  independent, no compounding). On gesture end the mutated state simply
//  becomes the next baseline, so consecutive gestures continue smoothly.
//

import Foundation
import simd

struct OrbitCameraState: Equatable, Sendable {
    var azimuth: Float      // radians, around +Y
    var elevation: Float    // radians, clamped so the camera never inverts
    var distance: Float     // meters from target

    // Bounds (shared by production + tests).
    static let minDistance: Float = 1.3
    static let maxDistance: Float = 4.0
    static let minElevation: Float = -0.6
    static let maxElevation: Float = 1.1
    /// Screen points → radians for drag orbit.
    static let dragToRadians: Float = 0.006
    /// Screen points → radians for drag elevation.
    static let dragToElevation: Float = 0.006

    init(azimuth: Float, elevation: Float, distance: Float) {
        self.azimuth = azimuth
        self.elevation = Self.clampElevation(elevation)
        self.distance = Self.clampDistance(distance)
    }

    static func clampElevation(_ v: Float) -> Float {
        min(max(v.isFinite ? v : 0, minElevation), maxElevation)
    }
    static func clampDistance(_ v: Float) -> Float {
        min(max(v.isFinite ? v : minDistance, minDistance), maxDistance)
    }

    /// Absolute new state for a drag whose CUMULATIVE translation (points)
    /// since gesture start is (dx, dy). Applied to `self` as the baseline.
    /// Horizontal drag rotates azimuth; vertical drag changes elevation.
    func dragged(byTotalX dx: Float, y dy: Float) -> OrbitCameraState {
        let nx = dx.isFinite ? dx : 0
        let ny = dy.isFinite ? dy : 0
        return OrbitCameraState(
            azimuth: azimuth + (-nx) * Self.dragToRadians,
            elevation: elevation + ny * Self.dragToElevation,
            distance: distance
        )
    }

    /// Absolute new state for a pinch whose CUMULATIVE magnification since
    /// gesture start is `magnification` (1.0 = no change). Applied to `self`
    /// as the baseline. Zooming in (magnification > 1) reduces distance.
    func zoomed(byMagnification magnification: Float) -> OrbitCameraState {
        let m = (magnification.isFinite && magnification > 0.0001) ? magnification : 1
        return OrbitCameraState(
            azimuth: azimuth,
            elevation: elevation,
            distance: distance / m
        )
    }

    /// Camera world position for a given look-at target.
    func position(target: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(
            target.x + distance * sin(azimuth) * cos(elevation),
            target.y + distance * sin(elevation),
            target.z + distance * cos(azimuth) * cos(elevation)
        )
    }

    /// Default state for a preset framing.
    static func `default`(for camera: Exercise3DCamera, distance: Float = 2.4) -> OrbitCameraState {
        let az: Float
        switch camera {
        case .front: az = 0
        case .side: az = .pi / 2
        case .threeQuarter: az = .pi / 4
        }
        return OrbitCameraState(azimuth: az, elevation: 0.12, distance: distance)
    }
}
