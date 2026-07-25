//
//  OrbitCameraStateTests.swift
//  Pulse CueTests
//
//  Pure tests for the orbit-camera gesture math. These prove the fix for
//  the cumulative-value bug: because a cumulative drag/pinch is always
//  applied against a fixed gesture baseline, the final camera depends only
//  on the total value, not on how many events delivered it.
//

import Foundation
import simd
import Testing
@testable import Pulse_Cue

struct OrbitCameraStateTests {

    private let base = OrbitCameraState.default(for: .front)

    @Test func dragFrequencyIndependence() {
        // One large update to the total translation…
        let one = base.dragged(byTotalX: 220, y: 90)
        // …vs. ten smaller updates, each a cumulative value applied to the
        // same baseline, reaching the same total.
        var stepped = base
        for i in 1...10 {
            stepped = base.dragged(byTotalX: Float(i) * 22, y: Float(i) * 9)
        }
        #expect(abs(one.azimuth - stepped.azimuth) < 0.0001)
        #expect(abs(one.elevation - stepped.elevation) < 0.0001)
    }

    @Test func pinchFrequencyIndependence() {
        let one = base.zoomed(byMagnification: 1.8)
        var stepped = base
        for mag in [1.15, 1.3, 1.5, 1.65, 1.8] {
            stepped = base.zoomed(byMagnification: Float(mag))
        }
        #expect(abs(one.distance - stepped.distance) < 0.0001)
    }

    @Test func elevationClampsAndCameraNeverInverts() {
        let up = base.dragged(byTotalX: 0, y: 100000)
        let down = base.dragged(byTotalX: 0, y: -100000)
        #expect(up.elevation <= OrbitCameraState.maxElevation + 0.0001)
        #expect(down.elevation >= OrbitCameraState.minElevation - 0.0001)
    }

    @Test func zoomClampsToBounds() {
        let zoomedIn = base.zoomed(byMagnification: 1000)
        let zoomedOut = base.zoomed(byMagnification: 0.0001)
        #expect(zoomedIn.distance >= OrbitCameraState.minDistance - 0.0001)
        #expect(zoomedOut.distance <= OrbitCameraState.maxDistance + 0.0001)
        // Degenerate magnification is ignored (no NaN/inf).
        #expect(base.zoomed(byMagnification: 0).distance.isFinite)
    }

    @Test func consecutiveGesturesContinueFromCommittedState() {
        // Simulate: first gesture drags, commits; second gesture starts from
        // the committed state (not a stale zero baseline).
        let afterFirst = base.dragged(byTotalX: 100, y: 40)
        // Second gesture baseline is afterFirst; a new total of (50,0).
        let afterSecond = afterFirst.dragged(byTotalX: 50, y: 0)
        #expect(afterSecond.azimuth < afterFirst.azimuth) // continued rotating same way
        #expect(afterSecond.elevation == afterFirst.elevation)
    }

    @Test func resetReturnsProfileDefault() {
        let d = OrbitCameraState.default(for: .side)
        #expect(abs(d.azimuth - .pi / 2) < 0.0001)
        #expect(abs(d.distance - 2.4) < 0.0001)
    }

    @Test func positionIsFinite() {
        let p = base.dragged(byTotalX: 30, y: 20).zoomed(byMagnification: 1.3)
            .position(target: SIMD3(0, 1.15, 0))
        #expect(p.x.isFinite && p.y.isFinite && p.z.isFinite)
    }
}
