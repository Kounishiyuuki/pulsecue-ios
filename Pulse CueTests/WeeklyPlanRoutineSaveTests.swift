//
//  WeeklyPlanRoutineSaveTests.swift
//  Pulse CueTests
//
//  Covers the weekly-plan → routine save path: the pure `RoutineFactory`
//  conversion (one routine per non-empty session) and the explicit-
//  confirm boundary (the factory builds but never inserts; only an
//  explicit `modelContext.insert` persists anything). No networking, no
//  AI, no schema migration.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct WeeklyPlanRoutineSaveTests {

    // MARK: - Helpers

    private func candidate(
        id: String,
        name: String,
        parts: Set<BodyPart> = [.chest],
        sets: Int? = nil,
        reps: ClosedRange<Int>? = nil,
        rest: Int? = nil,
        notes: String? = nil
    ) -> RoutineStepCandidate {
        let entry = MachineCatalogEntry(
            id: id,
            displayName: name,
            bodyParts: parts,
            setupNotes: notes,
            defaultSets: sets,
            defaultReps: reps,
            defaultRestSeconds: rest
        )
        return RoutineStepCandidate(entry: entry, sourceLabel: "週間プラン")
    }

    private func session(
        title: String,
        exercises: [RoutineStepCandidate],
        notes: String = ""
    ) -> TrainingSessionCandidate {
        TrainingSessionCandidate(
            title: title,
            focusBodyParts: [.chest],
            exercises: exercises,
            notes: notes
        )
    }

    private func plan(_ sessions: [TrainingSessionCandidate]) -> WeeklyTrainingPlanCandidate {
        WeeklyTrainingPlanCandidate(
            title: "テスト週次プラン",
            goal: .hypertrophy,
            daysPerWeek: sessions.count,
            sessions: sessions,
            rationale: "テスト",
            warnings: []
        )
    }

    private static func makeContext() throws -> ModelContext {
        let schema = Schema([Routine.self, Step.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    // MARK: - Session conversion (pure)

    @Test
    func sessionConvertsToOneRoutineWithOrderedSteps() {
        let s = session(
            title: "Day 1 · 全身",
            exercises: [
                candidate(id: "a", name: "種目A", sets: 3, reps: 8...12, rest: 90),
                candidate(id: "b", name: "種目B", sets: 4, reps: 6...10, rest: 120),
            ]
        )
        let out = RoutineFactory.makeRoutine(from: s)
        #expect(out.routine.name == "Day 1 · 全身")
        #expect(out.steps.count == 2)
        #expect(out.steps.map(\.order) == [0, 1])
        #expect(out.steps.map(\.title) == ["種目A", "種目B"])
        #expect(out.steps.allSatisfy { $0.routineId == out.routine.id })
    }

    @Test
    func sessionStepUsesResolvedValuesAndFallbacks() {
        let withDefaults = candidate(id: "a", name: "A", sets: 4, reps: 8...12, rest: 90)
        let noDefaults = candidate(id: "b", name: "B")
        let out = RoutineFactory.makeRoutine(from: session(title: "x", exercises: [withDefaults, noDefaults]))

        #expect(out.steps[0].sets == 4)
        #expect(out.steps[0].repsTarget == 8)        // lower bound of 8...12
        #expect(out.steps[0].restSeconds == 90)
        // Missing catalog defaults → RoutineStepCandidate fallbacks.
        #expect(out.steps[1].sets == RoutineStepCandidate.fallbackSets)
        #expect(out.steps[1].repsTarget == RoutineStepCandidate.fallbackRepsTarget)
        #expect(out.steps[1].restSeconds == RoutineStepCandidate.fallbackRestSeconds)
    }

    @Test
    func sessionStepRestIsClampedByStepInit() {
        let c = candidate(id: "a", name: "A", sets: 3, reps: 10...10, rest: 9999)
        let out = RoutineFactory.makeRoutine(from: session(title: "x", exercises: [c]))
        #expect(out.steps.first?.restSeconds == 600)   // Step.clampRest ceiling
    }

    @Test
    func sessionNoteComesFromCandidateNotes() {
        let c = candidate(id: "a", name: "A", notes: "肩甲骨を寄せる")
        let out = RoutineFactory.makeRoutine(from: session(title: "x", exercises: [c]))
        #expect(out.steps.first?.note == "肩甲骨を寄せる")

        let bare = RoutineFactory.makeRoutine(from: session(title: "y", exercises: [candidate(id: "b", name: "B")]))
        #expect(bare.steps.first?.note == "")
    }

    @Test
    func blankSessionTitleFallsBack() {
        let out = RoutineFactory.makeRoutine(from: session(title: "   ", exercises: [candidate(id: "a", name: "A")]))
        #expect(out.routine.name == "プラン")
    }

    // MARK: - Plan conversion (pure)

    @Test
    func makeRoutinesCreatesOnePerNonEmptySessionInOrder() {
        let p = plan([
            session(title: "Day 1", exercises: [candidate(id: "a", name: "A")]),
            session(title: "Day 2 (empty)", exercises: []),
            session(title: "Day 3", exercises: [candidate(id: "b", name: "B"), candidate(id: "c", name: "C")]),
        ])
        let outs = RoutineFactory.makeRoutines(from: p)
        #expect(outs.count == 2)                                   // empty session skipped
        #expect(outs.map(\.routine.name) == ["Day 1", "Day 3"])   // order preserved
        #expect(outs.map { $0.steps.count } == [1, 2])
    }

    @Test
    func makeRoutinesIsEmptyWhenAllSessionsEmpty() {
        let p = plan([session(title: "Day 1", exercises: []), session(title: "Day 2", exercises: [])])
        #expect(RoutineFactory.makeRoutines(from: p).isEmpty)
    }

    @Test
    func generatedPlanConvertsToRoutinesPerNonEmptySession() {
        let generated = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(daysPerWeek: 3)
        )
        let outs = RoutineFactory.makeRoutines(from: generated)
        let expectedCount = generated.sessions.filter { !$0.exercises.isEmpty }.count
        #expect(outs.count == expectedCount)
        // Each routine is named after its source session.
        let sessionTitles = generated.sessions.filter { !$0.exercises.isEmpty }.map(\.title)
        #expect(outs.map(\.routine.name) == sessionTitles)
    }

    // MARK: - Savable-session count (pure, no model construction)

    @Test
    func savableSessionsExcludeEmptySessions() {
        let p = plan([
            session(title: "Day 1", exercises: [candidate(id: "a", name: "A")]),
            session(title: "Day 2 (empty)", exercises: []),
            session(title: "Day 3", exercises: [candidate(id: "b", name: "B"), candidate(id: "c", name: "C")]),
        ])
        #expect(p.savableSessionCount == 2)
        #expect(p.savableSessions.map(\.title) == ["Day 1", "Day 3"])
    }

    @Test
    func savableSessionCountIsZeroWhenAllEmpty() {
        let p = plan([session(title: "Day 1", exercises: []), session(title: "Day 2", exercises: [])])
        #expect(p.savableSessionCount == 0)
        #expect(p.savableSessions.isEmpty)
    }

    @Test
    func savableSessionCountMatchesMakeRoutinesCount() {
        // The UI counts savable sessions without building any Routine/Step;
        // that count must still agree with what a save would produce.
        let p = plan([
            session(title: "Day 1", exercises: [candidate(id: "a", name: "A")]),
            session(title: "Day 2", exercises: []),
            session(title: "Day 3", exercises: [candidate(id: "b", name: "B")]),
        ])
        #expect(p.savableSessionCount == RoutineFactory.makeRoutines(from: p).count)
    }

    // MARK: - Explicit-confirm boundary (in-memory SwiftData)

    @Test
    func buildingCreatesNothingUntilExplicitInsert() throws {
        let context = try Self.makeContext()
        let p = plan([
            session(title: "Day 1", exercises: [candidate(id: "a", name: "A")]),
            session(title: "Day 2", exercises: [candidate(id: "b", name: "B"), candidate(id: "c", name: "C")]),
        ])

        // Building the routines must not persist anything.
        let outs = RoutineFactory.makeRoutines(from: p)
        #expect(try context.fetchCount(FetchDescriptor<Routine>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Step>()) == 0)

        // Explicit confirmation: insert each routine + its steps.
        for out in outs {
            context.insert(out.routine)
            for step in out.steps { context.insert(step) }
        }

        #expect(try context.fetchCount(FetchDescriptor<Routine>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<Step>()) == 3)
    }

    @Test
    func savedRoutinesPreserveNamesAndStepLinkage() throws {
        let context = try Self.makeContext()
        let p = plan([session(title: "胸の日", exercises: [candidate(id: "a", name: "ベンチ", sets: 3, reps: 8...12, rest: 90)])])

        for out in RoutineFactory.makeRoutines(from: p) {
            context.insert(out.routine)
            for step in out.steps { context.insert(step) }
        }

        let routine = try #require(try context.fetch(FetchDescriptor<Routine>()).first)
        #expect(routine.name == "胸の日")
        let step = try #require(try context.fetch(FetchDescriptor<Step>()).first)
        #expect(step.routineId == routine.id)
        #expect(step.title == "ベンチ")
        #expect(step.sets == 3)
        #expect(step.repsTarget == 8)
        #expect(step.restSeconds == 90)
    }
}
