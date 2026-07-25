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
    private var reduceMotion: Bool
    /// Test/robustness hook: when true, scene construction is treated as
    /// failed so the guide falls back to text without a real ARView.
    private let simulateFailure: Bool

    /// The defined cycle start. `最初から` always returns here.
    private let cycleStartProgress: Float = 0
    /// A clearer static demonstration pose used as the initial frame when
    /// Reduce Motion is on (the peak of the movement). It is only an initial
    /// frame — restart still goes to `cycleStartProgress`.
    private let reduceMotionStaticProgress: Float = 0.5

    private weak var arView: ARView?
    private var joints: [ExerciseJoint: Entity] = [:]
    private var equipmentContacts: [EquipmentContact] = []
    private var cameraEntity = PerspectiveCamera()
    private var updateSub: Cancellable?

    private(set) var progress: Float = 0   // 0...1 cycle position (test-readable)
    private let target = SIMD3<Float>(0, 1.15, 0)

    // Orbit camera: `cameraState` is the committed state. Drag owns
    // azimuth+elevation, pinch owns distance; each holds ONLY its own
    // per-axis gesture-start baseline, so simultaneous drag+pinch never
    // rewrite the other's axis and end order is irrelevant.
    private(set) var cameraState: OrbitCameraState
    private var dragBaselineAzimuth: Float = 0
    private var dragBaselineElevation: Float = 0
    private var pinchBaselineDistance: Float = 2.4

    init(
        profile: ExerciseMotionProfile,
        reduceMotion: Bool = false,
        simulateFailure: Bool = false,
        staticProgress: Float? = nil
    ) {
        self.profile = profile
        self.engine = ExerciseMotionEngine(profile: profile)
        self.reduceMotion = reduceMotion
        self.simulateFailure = simulateFailure
        self.camera = profile.preferredCamera
        let state = OrbitCameraState.default(for: profile.preferredCamera)
        self.cameraState = state
        if let staticProgress {
            // DEBUG screenshot mode: freeze at a fixed progress, paused.
            self.isPlaying = false
            self.progress = min(max(staticProgress, 0), 1)
        } else {
            // Reduce Motion: do not auto-run continuous motion; show a clear
            // static demonstration pose and let the user opt in.
            self.isPlaying = !reduceMotion
            self.progress = reduceMotion ? reduceMotionStaticProgress : cycleStartProgress
        }
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

        // Equipment: static structural parts + dynamic contact parts that
        // follow the mannequin (updated each frame in `applyPose`).
        let equipment = EquipmentSceneFactory.makeScene(for: profile)
        equipmentContacts = equipment.contacts
        anchor.addChild(equipment.root)

        // Lighting: key + fill so the silhouette reads. Shadows are disabled
        // — they are not needed for an MVP movement reference and cast-shadow
        // programmable-blending is a common source of simulator Metal
        // pipeline warnings.
        let key = DirectionalLight()
        key.light.intensity = 2200
        key.light.color = .white
        key.shadow = nil
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
        // Same frame, same pose, same clock — dynamic equipment follows.
        EquipmentMotionBinding.update(equipmentContacts, pose: pose)
    }

    // MARK: - Playback controls

    func togglePlay() { isPlaying.toggle() }
    func play() { isPlaying = true }
    func pause() { isPlaying = false }

    /// `最初から`: always returns to the defined cycle start (progress 0),
    /// regardless of Reduce Motion. Does not change play/pause.
    func restart() {
        progress = cycleStartProgress
        applyPose(at: progress)
    }

    func setSpeed(_ value: Float) { speed = value }

    // MARK: - Reduce Motion runtime sync

    /// Called when the system Reduce Motion setting changes while the guide
    /// is on screen. Turning it ON stops continuous motion immediately and
    /// shows the static demonstration pose. Turning it OFF is conservative:
    /// stays paused so the badge and controller never disagree; the user can
    /// explicitly press play.
    func setReduceMotion(_ enabled: Bool) {
        guard enabled != reduceMotion else { return }
        reduceMotion = enabled
        if enabled {
            isPlaying = false
            progress = reduceMotionStaticProgress
            applyPose(at: progress)
        } else {
            // Remain paused; do not auto-start.
            isPlaying = false
        }
    }

    // MARK: - Camera controls

    func setCamera(_ preset: Exercise3DCamera) {
        camera = preset
        // Preserve current zoom distance; only reframe the angle.
        let d = OrbitCameraState.default(for: preset)
        cameraState = OrbitCameraState(azimuth: d.azimuth, elevation: d.elevation, distance: cameraState.distance)
        updateCameraTransform()
    }

    // Drag lifecycle: owns azimuth+elevation only. Baseline is captured at
    // beginDrag; each update recomputes those two axes from that baseline +
    // cumulative translation while keeping the CURRENT distance (which a
    // simultaneous pinch may be changing).
    func beginDrag() {
        dragBaselineAzimuth = cameraState.azimuth
        dragBaselineElevation = cameraState.elevation
    }
    func updateDrag(totalTranslationX dx: Float, y dy: Float) {
        cameraState = OrbitCameraState(
            azimuth: OrbitCameraState.azimuth(dragBaseline: dragBaselineAzimuth, totalX: dx),
            elevation: OrbitCameraState.elevation(dragBaseline: dragBaselineElevation, totalY: dy),
            distance: cameraState.distance
        )
        updateCameraTransform()
    }
    func endDrag() {} // nothing to commit; cameraState is already current

    // Pinch lifecycle: owns distance only. Keeps the CURRENT azimuth/elevation
    // (which a simultaneous drag may be changing).
    func beginPinch() {
        pinchBaselineDistance = cameraState.distance
    }
    func updatePinch(magnification: Float) {
        cameraState = OrbitCameraState(
            azimuth: cameraState.azimuth,
            elevation: cameraState.elevation,
            distance: OrbitCameraState.distance(pinchBaseline: pinchBaselineDistance, magnification: magnification)
        )
        updateCameraTransform()
    }
    func endPinch() {}

    func resetCamera() {
        camera = profile.preferredCamera
        cameraState = OrbitCameraState.default(for: profile.preferredCamera)
        // Clear transient baselines so a following gesture starts clean.
        dragBaselineAzimuth = cameraState.azimuth
        dragBaselineElevation = cameraState.elevation
        pinchBaselineDistance = cameraState.distance
        updateCameraTransform()
    }

    private func updateCameraTransform() {
        let pos = cameraState.position(target: target)
        cameraEntity.position = pos
        cameraEntity.look(at: target, from: pos, relativeTo: nil)
    }

    // MARK: - Lifecycle

    func teardown() {
        isPlaying = false
        updateSub?.cancel()
        updateSub = nil
        arView?.scene.anchors.removeAll()
        arView = nil
        joints.removeAll()
        equipmentContacts.removeAll()
    }

    deinit {
        updateSub?.cancel()
    }
}
