//
//  RoutineStepCandidateSaveTests.swift
//  Pulse CueTests
//
//  Tests the machine candidate → routine save path: the pure resolution
//  of concrete savable values, the `RoutineFactory` overload that builds
//  a one-step routine, and the explicit-confirm boundary (the factory
//  builds but never inserts; only an explicit `modelContext.insert`
//  persists anything). No networking, no AI, no schema migration.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct RoutineStepCandidateSaveTests {

    private func entryWithDefaults() -> MachineCatalogEntry {
        MachineCatalogEntry(
            id: "bench_press",
            displayName: "ベンチプレス",
            bodyParts: [.chest, .arms],
            setupNotes: "肩甲骨を寄せて胸を張る",
            defaultSets: 4,
            defaultReps: 8...12,
            defaultRestSeconds: 90
        )
    }

    private static func makeContext() throws -> ModelContext {
        let schema = Schema([Routine.self, Step.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    // MARK: - Resolved values

    @Test
    func candidateResolvesConcreteValuesFromDefaults() {
        let candidate = RoutineStepCandidate(entry: entryWithDefaults())
        #expect(candidate.resolvedSets == 4)
        // Lower bound of the 8...12 range.
        #expect(candidate.resolvedRepsTarget == 8)
        #expect(candidate.resolvedRestSeconds == 90)
    }

    @Test
    func candidateResolvesFallbacksWhenDefaultsMissing() {
        let bare = MachineCatalogEntry(id: "pec_deck", displayName: "ペックデック", bodyParts: [.chest])
        let candidate = RoutineStepCandidate(entry: bare)
        #expect(candidate.resolvedSets == RoutineStepCandidate.fallbackSets)
        #expect(candidate.resolvedRepsTarget == RoutineStepCandidate.fallbackRepsTarget)
        #expect(candidate.resolvedRestSeconds == RoutineStepCandidate.fallbackRestSeconds)
    }

    // MARK: - Factory mapping (pure)

    @Test
    func factoryBuildsSingleStepRoutineFromCandidate() {
        let candidate = RoutineStepCandidate(entry: entryWithDefaults())
        let output = RoutineFactory.makeRoutine(from: candidate, title: "胸の日")

        #expect(output.routine.name == "胸の日")
        #expect(output.steps.count == 1)
        let step = try! #require(output.steps.first)
        #expect(step.order == 0)
        #expect(step.title == "ベンチプレス")
        #expect(step.sets == 4)
        #expect(step.repsTarget == 8)
        #expect(step.restSeconds == 90)
        #expect(step.note == "肩甲骨を寄せて胸を張る")
        #expect(step.routineId == output.routine.id)
    }

    @Test
    func factoryFallsBackToExerciseNameWhenTitleBlank() {
        let candidate = RoutineStepCandidate(entry: entryWithDefaults())
        #expect(RoutineFactory.makeRoutine(from: candidate, title: "").routine.name == "ベンチプレス")
        #expect(RoutineFactory.makeRoutine(from: candidate, title: "   ").routine.name == "ベンチプレス")
    }

    @Test
    func factoryNoteIsEmptyWhenCandidateHasNoNotes() {
        let bare = MachineCatalogEntry(id: "pec_deck", displayName: "ペックデック", bodyParts: [.chest])
        let output = RoutineFactory.makeRoutine(from: RoutineStepCandidate(entry: bare), title: "x")
        #expect(output.steps.first?.note == "")
    }

    @Test
    func factoryRestIsClampedByStepInit() {
        // restSeconds above Step.clampRest's 600 ceiling must be clamped.
        let entry = MachineCatalogEntry(
            id: "x", displayName: "X", bodyParts: [.chest],
            defaultSets: 3, defaultReps: 10...10, defaultRestSeconds: 9999
        )
        let output = RoutineFactory.makeRoutine(from: RoutineStepCandidate(entry: entry), title: "x")
        #expect(output.steps.first?.restSeconds == 600)
    }

    // MARK: - Explicit-confirm boundary (in-memory SwiftData)

    @Test
    func factoryDoesNotInsertUntilExplicitContextInsert() throws {
        let context = try Self.makeContext()
        let candidate = RoutineStepCandidate(entry: entryWithDefaults())

        // Building the routine must not persist anything — this is the
        // "candidate stays inert until confirmation" guarantee.
        let output = RoutineFactory.makeRoutine(from: candidate, title: "胸の日")
        #expect(try context.fetchCount(FetchDescriptor<Routine>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Step>()) == 0)

        // Explicit confirmation: the caller inserts.
        context.insert(output.routine)
        for step in output.steps { context.insert(step) }

        #expect(try context.fetchCount(FetchDescriptor<Routine>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Step>()) == 1)

        let savedRoutine = try #require(try context.fetch(FetchDescriptor<Routine>()).first)
        #expect(savedRoutine.name == "胸の日")
        let savedStep = try #require(try context.fetch(FetchDescriptor<Step>()).first)
        #expect(savedStep.routineId == savedRoutine.id)
        #expect(savedStep.title == "ベンチプレス")
        #expect(savedStep.sets == 4)
    }
}
