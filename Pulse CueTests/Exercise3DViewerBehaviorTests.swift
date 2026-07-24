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
        c.beginOrbitGesture()
        c.updateOrbit(totalTranslationX: 200, y: 80) // one big update
        let big = c.cameraState

        let c2 = controller()
        c2.beginOrbitGesture()
        for i in 1...10 { c2.updateOrbit(totalTranslationX: Float(i) * 20, y: Float(i) * 8) }
        let stepped = c2.cameraState

        #expect(abs(big.azimuth - stepped.azimuth) < 0.0001)
        #expect(abs(big.elevation - stepped.elevation) < 0.0001)
    }

    @Test func consecutiveGesturesContinueFromCommittedState() {
        let c = controller()
        c.beginOrbitGesture()
        c.updateOrbit(totalTranslationX: 100, y: 0)
        c.endGesture()
        let afterFirst = c.cameraState.azimuth
        // Second gesture must start from the committed state, not zero.
        c.beginOrbitGesture()
        c.updateOrbit(totalTranslationX: 50, y: 0)
        #expect(c.cameraState.azimuth < afterFirst) // continued same direction
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
