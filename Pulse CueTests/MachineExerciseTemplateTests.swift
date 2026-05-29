//
//  MachineExerciseTemplateTests.swift
//  Pulse CueTests
//
//  Unit tests for the pure `MachineExerciseTemplate` presentation helper
//  used by `MachineCatalogDetailView`. These cover the sets/reps/rest
//  formatting and the missing-defaults fallback so the detail screen can
//  rely on safe strings without brittle UI tests.
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct MachineExerciseTemplateTests {

    @Test
    func fullDefaultsProduceSetsRepsAndRest() {
        let template = MachineExerciseTemplate(sets: 3, reps: 8...12, restSeconds: 90)
        #expect(template.hasAnyDefault)
        #expect(template.setsAndRepsText == "3セット × 8〜12回")
        #expect(template.restText == "セット間 1分30秒")
    }

    @Test
    func initFromEntryReadsDefaults() {
        let entry = MachineCatalogEntry(
            id: "t",
            displayName: "T",
            bodyParts: [.chest],
            defaultSets: 4,
            defaultReps: 10...10,
            defaultRestSeconds: 45
        )
        let template = MachineExerciseTemplate(entry: entry)
        #expect(template.setsAndRepsText == "4セット × 10回")
        #expect(template.restText == "セット間 45秒")
    }

    @Test
    func singleValueRepRangeRendersWithoutDash() {
        let template = MachineExerciseTemplate(sets: nil, reps: 15...15, restSeconds: nil)
        #expect(template.setsAndRepsText == "15回")
    }

    @Test
    func setsOnlyAndRepsOnlyAreHandled() {
        let setsOnly = MachineExerciseTemplate(sets: 5, reps: nil, restSeconds: nil)
        #expect(setsOnly.setsAndRepsText == "5セット")

        let repsOnly = MachineExerciseTemplate(sets: nil, reps: 6...10, restSeconds: nil)
        #expect(repsOnly.setsAndRepsText == "6〜10回")
    }

    @Test
    func restOnlyHasNilSetsAndReps() {
        let template = MachineExerciseTemplate(sets: nil, reps: nil, restSeconds: 60)
        #expect(template.hasAnyDefault)
        #expect(template.setsAndRepsText == nil)
        #expect(template.restText == "セット間 1分")
    }

    @Test
    func noDefaultsReportsEmptyAndNilStrings() {
        let template = MachineExerciseTemplate(sets: nil, reps: nil, restSeconds: nil)
        #expect(!template.hasAnyDefault)
        #expect(template.setsAndRepsText == nil)
        #expect(template.restText == nil)
        #expect(!MachineExerciseTemplate.fallbackMessage.isEmpty)
    }

    @Test
    func humanizedDurationFormatsSecondsMinutesAndMixed() {
        #expect(MachineExerciseTemplate.humanizedDuration(seconds: 45) == "45秒")
        #expect(MachineExerciseTemplate.humanizedDuration(seconds: 60) == "1分")
        #expect(MachineExerciseTemplate.humanizedDuration(seconds: 120) == "2分")
        #expect(MachineExerciseTemplate.humanizedDuration(seconds: 90) == "1分30秒")
        #expect(MachineExerciseTemplate.humanizedDuration(seconds: 0) == "0秒")
    }

    @Test
    func humanizedDurationClampsNegativeInput() {
        #expect(MachineExerciseTemplate.humanizedDuration(seconds: -30) == "0秒")
    }

    @Test
    func enumDisplayNamesAreNonEmpty() {
        for c in MachineCategory.allCases { #expect(!c.displayName.isEmpty) }
        for e in EquipmentType.allCases { #expect(!e.displayName.isEmpty) }
        for m in MovementPattern.allCases { #expect(!m.displayName.isEmpty) }
        for d in MachineDifficulty.allCases { #expect(!d.displayName.isEmpty) }
    }
}
