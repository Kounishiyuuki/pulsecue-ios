//
//  ExerciseGuideTests.swift
//  Pulse CueTests
//
//  Integrity tests for the text Form Guide pack: guides reference real
//  exercises, the MVP set is complete, content is non-empty and concise,
//  no fake 3D asset id leaks in, and custom/unsupported ids never resolve
//  to a guide.
//

import Foundation
import Testing
@testable import Pulse_Cue

struct ExerciseGuideTests {

    @Test func everyGuideReferencesAValidExercise() {
        for guide in FormGuideLibrary.all {
            #expect(ExerciseLibrary.isValid(guide.exerciseId), "guide for unknown \(guide.exerciseId)")
        }
    }

    @Test func mvpGuidePackIsComplete() {
        let expected: [ExerciseID] = [
            "machine_chest_press", "lat_pulldown", "machine_seated_row",
            "machine_shoulder_press", "leg_press", "leg_extension",
            "leg_curl", "machine_arm_curl", "cable_triceps_pushdown",
            "machine_lateral_raise",
        ]
        for id in expected {
            #expect(FormGuideLibrary.guide(for: id) != nil, "missing guide \(id)")
        }
        #expect(FormGuideLibrary.all.count == expected.count)
    }

    @Test func guideIdsAreUnique() {
        let ids = FormGuideLibrary.all.map(\.exerciseId)
        #expect(Set(ids).count == ids.count)
    }

    @Test func guideContentIsPresentAndConcise() {
        for guide in FormGuideLibrary.all {
            #expect((2...4).contains(guide.instructions.count), "\(guide.exerciseId) instructions")
            #expect((2...4).contains(guide.commonMistakes.count), "\(guide.exerciseId) mistakes")
            #expect((1...3).contains(guide.safetyNotes.count), "\(guide.exerciseId) checkpoints")
            #expect(!guide.recommendedViews.isEmpty)
            for line in guide.instructions + guide.commonMistakes + guide.safetyNotes {
                #expect(!line.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    @Test func noGuideShipsAFake3DAsset() {
        for guide in FormGuideLibrary.all {
            #expect(guide.animationAssetId == nil, "\(guide.exerciseId) has a placeholder 3D id")
        }
    }

    @Test func recommendedViewsAreValid() {
        let valid = Set(RecommendedView.allCases)
        for guide in FormGuideLibrary.all {
            for view in guide.recommendedViews {
                #expect(valid.contains(view))
            }
        }
    }

    @Test func unsupportedAndNilIdsHaveNoGuide() {
        #expect(FormGuideLibrary.guide(for: ExerciseID("barbell_bench_press")) == nil) // valid exercise, no MVP guide
        #expect(FormGuideLibrary.guide(for: nil) == nil)
        #expect(!FormGuideLibrary.hasGuide(for: nil))
        #expect(!FormGuideLibrary.hasGuide(for: ExerciseID("not_a_real_id")))
    }

    @Test func sharedDisclaimerAvoidsOverclaiming() {
        let banned = ["怪我を防げ", "絶対に正しい", "保証"]
        for phrase in banned {
            #expect(!FormGuideLibrary.sharedDisclaimer.contains(phrase))
        }
        #expect(!FormGuideLibrary.sharedDisclaimer.isEmpty)
    }
}
