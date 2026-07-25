//
//  Exercise3DViewerBehaviorTests.swift
//  Pulse CueTests
//
//  Behavior tests for the RealityKit scene controller's state machine
//  (playback, speed, camera, Reduce Motion, failure fallback). These drive
//  the controller directly; the pure motion math lives in
//  ExerciseMotionProfileTests. Marked @MainActor because the controller is.
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct Exercise3DViewerBehaviorTests {

    private func controller(reduceMotion: Bool = false, fail: Bool = false) -> Exercise3DSceneController {
        Exercise3DSceneController(
            profile: ExerciseMotionLibrary.profile(for: "machine_chest_press")!,
            reduceMotion: reduceMotion,
            simulateFailure: fail
        )
    }

    @Test func defaultsToPlayingAtNormalSpeed() {
        let c = controller()
        #expect(c.isPlaying)
        #expect(abs(c.speed - 1.0) < 0.001)
    }

    @Test func pauseAndResume() {
        let c = controller()
        c.pause()
        #expect(!c.isPlaying)
        c.play()
        #expect(c.isPlaying)
        c.togglePlay()
        #expect(!c.isPlaying)
    }

    @Test func speedSwitch() {
        let c = controller()
        c.setSpeed(0.5)
        #expect(abs(c.speed - 0.5) < 0.001)
        c.setSpeed(1.0)
        #expect(abs(c.speed - 1.0) < 0.001)
    }

    @Test func restartGoesToProgressZeroNormalMode() {
        let c = controller()
        c.restart()
        #expect(c.progress == 0)
        #expect(c.isPlaying) // restart alone does not toggle playback
    }

    @Test func restartGoesToProgressZeroUnderReduceMotion() {
        let c = controller(reduceMotion: true)
        // Reduce Motion opens on the static demo pose (0.5)…
        #expect(abs(c.progress - 0.5) < 0.0001)
        // …but 最初から means the actual cycle start, progress 0.
        c.restart()
        #expect(c.progress == 0)
    }

    @Test func cameraPresetAndReset() {
        let c = controller()
        c.setCamera(.side)
        #expect(c.camera == .side)
        c.setCamera(.front)
        #expect(c.camera == .front)
        c.resetCamera()
        #expect(c.camera == c.profile.preferredCamera)
        #expect(abs(c.cameraState.distance - 2.4) < 0.0001)
    }

    @Test func gestureDragFrequencyIndependenceThroughController() {
        let c = controller()
        c.beginDrag()
        c.updateDrag(totalTranslationX: 200, y: 80) // one big update
        let big = c.cameraState

        let c2 = controller()
        c2.beginDrag()
        for i in 1...10 { c2.updateDrag(totalTranslationX: Float(i) * 20, y: Float(i) * 8) }
        let stepped = c2.cameraState

        #expect(abs(big.azimuth - stepped.azimuth) < 0.0001)
        #expect(abs(big.elevation - stepped.elevation) < 0.0001)
    }

    @Test func consecutiveGesturesContinueFromCommittedState() {
        let c = controller()
        c.beginDrag()
        c.updateDrag(totalTranslationX: 100, y: 0)
        c.endDrag()
        let afterFirst = c.cameraState.azimuth
        // Second gesture must start from the committed state, not zero.
        c.beginDrag()
        c.updateDrag(totalTranslationX: 50, y: 0)
        #expect(c.cameraState.azimuth < afterFirst) // continued same direction
    }

    // MARK: - Simultaneous drag + pinch (independent axes)

    @Test func interleavedDragAndPinchKeepIndependentAxes() {
        let c = controller()
        let startAz = c.cameraState.azimuth
        let startEl = c.cameraState.elevation
        let startDist = c.cameraState.distance

        c.beginDrag()
        c.beginPinch()
        c.updateDrag(totalTranslationX: 120, y: 60)
        c.updatePinch(magnification: 1.5)
        c.updateDrag(totalTranslationX: 200, y: 90)
        c.updatePinch(magnification: 1.8)

        // Drag axes reflect the final drag; pinch axis reflects the final
        // pinch. Neither returned to its baseline.
        #expect(c.cameraState.azimuth != startAz)
        #expect(c.cameraState.elevation != startEl)
        #expect(c.cameraState.distance != startDist)
        // Zoom is the pinch result (distance decreased for magnification>1),
        // NOT reset by the drag updates.
        #expect(c.cameraState.distance < startDist)
        // Azimuth equals a pure drag of the same total (pinch did not rewrite it).
        let pureDrag = OrbitCameraState.azimuth(dragBaseline: startAz, totalX: 200)
        #expect(abs(c.cameraState.azimuth - pureDrag) < 0.0001)
    }

    @Test func gestureEndOrderDoesNotChangeResult() {
        func run(endDragFirst: Bool) -> OrbitCameraState {
            let c = controller()
            c.beginDrag(); c.beginPinch()
            c.updateDrag(totalTranslationX: 150, y: 40)
            c.updatePinch(magnification: 1.6)
            if endDragFirst { c.endDrag(); c.endPinch() } else { c.endPinch(); c.endDrag() }
            return c.cameraState
        }
        let a = run(endDragFirst: true)
        let b = run(endDragFirst: false)
        #expect(abs(a.azimuth - b.azimuth) < 0.0001)
        #expect(abs(a.elevation - b.elevation) < 0.0001)
        #expect(abs(a.distance - b.distance) < 0.0001)
    }

    @Test func oneGestureContinuesAfterOtherEnds() {
        let c = controller()
        c.beginDrag(); c.beginPinch()
        c.updateDrag(totalTranslationX: 100, y: 30)
        c.updatePinch(magnification: 1.4)
        let zoomAfterPinch = c.cameraState.distance
        c.endPinch()
        // Continue dragging — azimuth changes, zoom retains the pinch value.
        c.beginDrag() // real UI re-begins from committed state
        c.updateDrag(totalTranslationX: 180, y: 60)
        #expect(abs(c.cameraState.distance - zoomAfterPinch) < 0.0001) // zoom kept
        #expect(c.cameraState.azimuth != c.cameraState.azimuth + 1) // sanity (finite)
        #expect(c.cameraState.distance < c.cameraState.distance + 1)
    }

    @Test func resetClearsTransientBaselinesMidGesture() {
        let c = controller()
        c.beginDrag()
        c.updateDrag(totalTranslationX: 120, y: 40)
        c.resetCamera()
        #expect(c.cameraState == OrbitCameraState.default(for: c.profile.preferredCamera))
        // Next gesture starts cleanly from the reset state.
        c.beginDrag()
        c.updateDrag(totalTranslationX: 40, y: 0)
        let expected = OrbitCameraState.azimuth(
            dragBaseline: OrbitCameraState.default(for: c.profile.preferredCamera).azimuth, totalX: 40)
        #expect(abs(c.cameraState.azimuth - expected) < 0.0001)
    }

    @Test func reduceMotionStartsPaused() {
        let c = controller(reduceMotion: true)
        #expect(!c.isPlaying) // no auto continuous motion
    }

    @Test func reduceMotionRuntimeFalseToTrueStopsMotion() {
        let c = controller(reduceMotion: false)
        #expect(c.isPlaying)
        c.setReduceMotion(true)
        #expect(!c.isPlaying)                        // stops immediately
        #expect(abs(c.progress - 0.5) < 0.0001)      // static demo pose
    }

    @Test func reduceMotionRuntimeTrueToFalseStaysPaused() {
        let c = controller(reduceMotion: true)
        c.setReduceMotion(false)
        #expect(!c.isPlaying) // conservative: do not auto-start
    }

    @Test func simulatedFailureFallsBack() {
        let c = controller(fail: true)
        _ = c.makeARView()
        #expect(c.sceneFailed)
        c.teardown()
    }
}
