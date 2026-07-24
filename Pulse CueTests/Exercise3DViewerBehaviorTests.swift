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

    @Test func restartDoesNotCrashAndKeepsState() {
        let c = controller()
        c.restart()
        #expect(c.isPlaying) // restart alone does not toggle playback
    }

    @Test func cameraPresetAndReset() {
        let c = controller()
        c.setCamera(.side)
        #expect(c.camera == .side)
        c.setCamera(.front)
        #expect(c.camera == .front)
        c.resetCamera()
        #expect(c.camera == c.profile.preferredCamera)
    }

    @Test func orbitAndZoomDoNotCrash() {
        let c = controller()
        c.orbit(deltaAzimuth: 0.3, deltaElevation: 2.0) // elevation clamps internally
        c.zoom(scale: 2.0)
        c.zoom(scale: 0.1)
        c.zoom(scale: 0) // ignored
        #expect(true)
    }

    @Test func reduceMotionStartsPaused() {
        let c = controller(reduceMotion: true)
        #expect(!c.isPlaying) // no auto continuous motion
    }

    @Test func simulatedFailureFallsBack() {
        let c = controller(fail: true)
        _ = c.makeARView()
        #expect(c.sceneFailed)
        c.teardown()
    }
}
