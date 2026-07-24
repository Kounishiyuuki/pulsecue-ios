//
//  Exercise3DSceneController.swift
//  Pulse Cue
//
//  Owns the RealityKit scene for one Form Guide viewing. Uses a PURE
//  virtual scene: `ARView` with `.nonAR` camera mode and no ARSession — so
//  there is no camera permission, no world tracking, no AR at all. A single
//  `SceneEvents.Update` subscription is the one animation clock; it advances
//  a normalized cycle progress and applies the interpolated pose to the
//  reusable mannequin's joint entities. All meshes are iOS 17-safe
//  (box/sphere). Playback, speed, camera presets, orbit/zoom, Reduce Motion
//  and teardown live here so the SwiftUI viewer stays thin.
//

import Foundation
import Combine
import RealityKit
import UIKit
import simd

@MainActor
final class Exercise3DSceneController: ObservableObject {

    // Published UI state.
    @Published private(set) var isPlaying: Bool
    @Published private(set) var speed: Float = 1.0
    @Published private(set) var camera: Exercise3DCamera
    @Published private(set) var sceneFailed = false

    let profile: ExerciseMotionProfile
    private let engine: ExerciseMotionEngine
    private let reduceMotion: Bool
    /// Test/robustness hook: when true, scene construction is treated as
    /// failed so the guide falls back to text without a real ARView.
    private let simulateFailure: Bool

    private weak var arView: ARView?
    private var joints: [ExerciseJoint: Entity] = [:]
    private var cameraEntity = PerspectiveCamera()
    private var updateSub: Cancellable?

    private var progress: Float = 0        // 0...1 cycle position
    // Spherical camera around the target.
    private let target = SIMD3<Float>(0, 1.15, 0)
    private var azimuth: Float
    private var elevation: Float = 0.12
    private var distance: Float = 2.4
    private let minDistance: Float = 1.3
    private let maxDistance: Float = 4.0

    init(profile: ExerciseMotionProfile, reduceMotion: Bool = false, simulateFailure: Bool = false) {
        self.profile = profile
        self.engine = ExerciseMotionEngine(profile: profile)
        self.reduceMotion = reduceMotion
        self.simulateFailure = simulateFailure
        self.camera = profile.preferredCamera
        self.azimuth = Self.azimuth(for: profile.preferredCamera)
        // Reduce Motion: do not auto-run continuous motion; show a clear
        // static demonstration pose (the peak) and let the user opt in.
        self.isPlaying = !reduceMotion
        if reduceMotion { self.progress = 0.5 }
    }

    // MARK: - Scene construction

    func makeARView() -> ARView {
        if simulateFailure {
            sceneFailed = true
            return ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        }
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.automaticallyConfigureSession = false
        view.environment.background = .color(UIColor.clear)
        #if !targetEnvironment(simulator)
        view.renderOptions.insert(.disableMotionBlur)
        #endif
        self.arView = view

        let anchor = AnchorEntity(world: .zero)

        // Mannequin.
        let mannequin = MannequinFactory.makeMannequin()
        joints = mannequin.joints
        anchor.addChild(mannequin.root)

        // Equipment context.
        anchor.addChild(EquipmentSceneFactory.makeEquipment(profile.equipmentScene))

        // Lighting: key + fill so the silhouette reads without harsh shadows.
        let key = DirectionalLight()
        key.light.intensity = 2200
        key.light.color = .white
        key.look(at: .zero, from: SIMD3(1.2, 2.0, 1.5), relativeTo: nil)
        anchor.addChild(key)

        let fill = PointLight()
        fill.light.intensity = 12000
        fill.light.attenuationRadius = 12
        fill.position = SIMD3(-1.5, 1.6, 2.0)
        anchor.addChild(fill)

        // Camera.
        cameraEntity = PerspectiveCamera()
        cameraEntity.camera.fieldOfViewInDegrees = 42
        anchor.addChild(cameraEntity)
        updateCameraTransform()

        view.scene.addAnchor(anchor)

        // Guard against an empty joint map (construction failure).
        if joints.isEmpty {
            sceneFailed = true
            return view
        }

        applyPose(at: progress)

        // Single animation clock.
        updateSub = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.tick(deltaTime: Float(event.deltaTime))
        }
        return view
    }

    private func tick(deltaTime: Float) {
        guard isPlaying, profile.duration > 0, deltaTime.isFinite else { return }
        progress += (deltaTime * speed) / profile.duration
        if progress >= 1 { progress -= floor(progress) }
        applyPose(at: progress)
    }

    private func applyPose(at p: Float) {
        let pose = engine.pose(atProgress: p)
        for (joint, entity) in joints {
            entity.orientation = pose[joint].quaternion
        }
    }

    // MARK: - Playback controls

    func togglePlay() { isPlaying.toggle() }
    func play() { isPlaying = true }
    func pause() { isPlaying = false }

    func restart() {
        progress = reduceMotion ? 0.5 : 0
        applyPose(at: progress)
    }

    func setSpeed(_ value: Float) { speed = value }

    // MARK: - Camera controls

    func setCamera(_ preset: Exercise3DCamera) {
        camera = preset
        azimuth = Self.azimuth(for: preset)
        elevation = 0.12
        updateCameraTransform()
    }

    func orbit(deltaAzimuth: Float, deltaElevation: Float) {
        azimuth += deltaAzimuth
        elevation = min(max(elevation + deltaElevation, -0.6), 1.1) // clamp so camera never inverts
        updateCameraTransform()
    }

    func zoom(scale: Float) {
        guard scale > 0 else { return }
        distance = min(max(distance / scale, minDistance), maxDistance)
        updateCameraTransform()
    }

    func resetCamera() {
        setCamera(profile.preferredCamera)
        distance = 2.4
        updateCameraTransform()
    }

    private func updateCameraTransform() {
        let x = target.x + distance * sin(azimuth) * cos(elevation)
        let y = target.y + distance * sin(elevation)
        let z = target.z + distance * cos(azimuth) * cos(elevation)
        cameraEntity.position = SIMD3(x, y, z)
        cameraEntity.look(at: target, from: cameraEntity.position, relativeTo: nil)
    }

    private static func azimuth(for preset: Exercise3DCamera) -> Float {
        switch preset {
        case .front: return 0
        case .side: return .pi / 2
        case .threeQuarter: return .pi / 4
        }
    }

    // MARK: - Lifecycle

    func teardown() {
        isPlaying = false
        updateSub?.cancel()
        updateSub = nil
        arView?.scene.anchors.removeAll()
        arView = nil
        joints.removeAll()
    }

    deinit {
        updateSub?.cancel()
    }
}
