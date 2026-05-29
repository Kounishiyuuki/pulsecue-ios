//
//  RoutineStepCandidateTests.swift
//  Pulse CueTests
//
//  Unit tests for the pure `RoutineStepCandidate` builder used by the
//  machine catalog detail → 種目候補 preview. These cover building from a
//  fully-populated entry, safe fallback when defaults are missing, and
//  that identity / body-part / formatting data is preserved. No
//  SwiftData, no networking, no AI — the candidate is a plain value.
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct RoutineStepCandidateTests {

    private func entryWithDefaults() -> MachineCatalogEntry {
        MachineCatalogEntry(
            id: "bench_press",
            displayName: "ベンチプレス",
            bodyParts: [.chest, .arms],
            secondaryMuscles: [.shoulders],
            setupNotes: "肩甲骨を寄せて胸を張る",
            safetyNotes: "セーフティバーを使用",
            defaultSets: 3,
            defaultReps: 8...12,
            defaultRestSeconds: 90
        )
    }

    @Test
    func candidateBuildsFromEntryWithDefaults() {
        let candidate = RoutineStepCandidate(entry: entryWithDefaults())
        #expect(candidate.hasMenuDefaults)
        #expect(candidate.setsAndRepsText == "3セット × 8〜12回")
        #expect(candidate.restText == "セット間 1分30秒")
    }

    @Test
    func candidateFallsBackSafelyWhenDefaultsMissing() {
        let bare = MachineCatalogEntry(
            id: "pec_deck",
            displayName: "ペックデック",
            bodyParts: [.chest]
        )
        let candidate = RoutineStepCandidate(entry: bare)
        #expect(!candidate.hasMenuDefaults)
        #expect(candidate.setsAndRepsText == nil)
        #expect(candidate.restText == nil)
        #expect(candidate.notes == nil)
        // The preview can still render generic guidance.
        #expect(!MachineExerciseTemplate.fallbackMessage.isEmpty)
    }

    @Test
    func candidatePreservesMachineIdAndDisplayName() {
        let candidate = RoutineStepCandidate(entry: entryWithDefaults())
        #expect(candidate.machineId == "bench_press")
        #expect(candidate.exerciseName == "ベンチプレス")
    }

    @Test
    func candidatePreservesBodyPartsInCanonicalOrder() {
        let candidate = RoutineStepCandidate(entry: entryWithDefaults())
        // Only primary body parts, ordered by BodyPart.allCases (chest
        // precedes arms), independent of the source Set's ordering.
        #expect(candidate.bodyParts == [.chest, .arms])
    }

    @Test
    func candidatePrefersSetupNotesThenSafetyNotes() {
        let setupOnly = MachineCatalogEntry(
            id: "a", displayName: "A", bodyParts: [.chest],
            setupNotes: "セットアップ", safetyNotes: nil
        )
        #expect(RoutineStepCandidate(entry: setupOnly).notes == "セットアップ")

        let safetyOnly = MachineCatalogEntry(
            id: "b", displayName: "B", bodyParts: [.chest],
            setupNotes: nil, safetyNotes: "安全"
        )
        #expect(RoutineStepCandidate(entry: safetyOnly).notes == "安全")
    }

    @Test
    func candidateUsesDefaultSourceLabel() {
        let candidate = RoutineStepCandidate(entry: entryWithDefaults())
        #expect(candidate.sourceLabel == "マシンカタログ")
    }

    @Test
    func candidateReusesMachineExerciseTemplateValues() {
        let entry = entryWithDefaults()
        let candidate = RoutineStepCandidate(entry: entry)
        // The candidate's template must equal one built directly from the
        // same entry — i.e. no duplicated/divergent formatting logic.
        #expect(candidate.template == MachineExerciseTemplate(entry: entry))
    }

    @Test
    func candidateIsValueTypeRequiringNoSwiftData() {
        // A candidate can be created and compared with no ModelContext /
        // container in sight; building two from the same entry yields
        // equal values (Equatable synthesis over plain value fields).
        let entry = entryWithDefaults()
        #expect(RoutineStepCandidate(entry: entry) == RoutineStepCandidate(entry: entry))
    }
}
