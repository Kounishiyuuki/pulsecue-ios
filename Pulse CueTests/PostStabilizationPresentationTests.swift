//
//  PostStabilizationPresentationTests.swift
//  Pulse CueTests
//
//  Pure-logic guards for the post-#138 stabilization fixes:
//   - Form Guide text fallback discoverability (auto-expand when no 3D).
//   - Weekly candidate invalidation when generation inputs change.
//

import Testing
@testable import Pulse_Cue

struct FormGuidePresentationTests {

    @Test func textExpandsWhenNo3DDemoExists() {
        // No motion profile → text is the only instruction → start expanded.
        #expect(FormGuidePresentation.instructionsInitiallyExpanded(hasMotionProfile: false))
    }

    @Test func textStaysCollapsedWhen3DLeads() {
        // 3D demo present → keep the calm "3D first" screen; text collapsed.
        // (Runtime auto-expands only if the scene fails, covered by the view.)
        #expect(FormGuidePresentation.instructionsInitiallyExpanded(hasMotionProfile: true) == false)
    }
}

@MainActor
struct WeeklyPlanInputChangeTests {

    private let baseline = WeeklyPlanGenerationInputs.production(
        goal: .consistency,
        experience: .beginner,
        split: .fullBody,
        daysPerWeek: 3,
        bodyParts: []
    )

    @Test(arguments: [
        WeeklyPlanGenerationInputs.production(
            goal: .hypertrophy, experience: .beginner, split: .fullBody,
            daysPerWeek: 3, bodyParts: []
        ),
        WeeklyPlanGenerationInputs.production(
            goal: .consistency, experience: .intermediate, split: .fullBody,
            daysPerWeek: 3, bodyParts: []
        ),
        WeeklyPlanGenerationInputs.production(
            goal: .consistency, experience: .beginner, split: .upperLower,
            daysPerWeek: 3, bodyParts: []
        ),
        WeeklyPlanGenerationInputs.production(
            goal: .consistency, experience: .beginner, split: .fullBody,
            daysPerWeek: 4, bodyParts: []
        ),
        WeeklyPlanGenerationInputs.production(
            goal: .consistency, experience: .beginner, split: .fullBody,
            daysPerWeek: 3, bodyParts: [.chest]
        ),
    ])
    func everyProductionGenerationInputChangesTheFingerprint(
        changed: WeeklyPlanGenerationInputs
    ) {
        #expect(changed != baseline)
    }

    @Test func noCandidateNothingToInvalidate() {
        #expect(
            WeeklyPlanInputChange.invalidatesCandidate(
                hasCandidate: false, saveState: .idle, hasEquipmentNotice: false
            ) == false
        )
    }

    @Test func existingCandidateIsInvalidatedOnInputChange() {
        #expect(
            WeeklyPlanInputChange.invalidatesCandidate(
                hasCandidate: true, saveState: .idle, hasEquipmentNotice: false
            )
        )
    }

    @Test func savedCandidateIsInvalidatedSoStaleSaveCannotStand() {
        // After a save, changing an input must reset state so the (now stale)
        // success card cannot remain under new conditions.
        #expect(
            WeeklyPlanInputChange.invalidatesCandidate(
                hasCandidate: false, saveState: .saved(routineCount: 2), hasEquipmentNotice: false
            )
        )
    }

    @Test func equipmentNoticeIsClearedOnInputChange() {
        #expect(
            WeeklyPlanInputChange.invalidatesCandidate(
                hasCandidate: false, saveState: .idle, hasEquipmentNotice: true
            )
        )
    }

    @Test func savedStateCannotBeSavedAgain() {
        // Locks the "no accidental duplicate/outdated save" contract.
        #expect(WeeklyPlanSaveState.idle.canSave)
        #expect(WeeklyPlanSaveState.saved(routineCount: 1).canSave == false)
    }
}
