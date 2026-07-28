//
//  SessionHistoryPresentationTests.swift
//  Pulse CueTests
//
//  Regression coverage for the History Detail data source. `StepResult` is the
//  historical source of truth: results must stay visible after their Step or
//  Routine is deleted (deletion does not cascade to StepResult). Steps only
//  enrich the title when still resolvable.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct SessionHistoryPresentationTests {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Routine.self, Step.self, Session.self, StepResult.self, DayLog.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private func fetchResults(_ context: ModelContext, sessionId: UUID) throws -> [StepResult] {
        try context.fetch(FetchDescriptor<StepResult>(
            predicate: #Predicate { $0.sessionId == sessionId },
            sortBy: [SortDescriptor(\.setIndex, order: .forward)]
        ))
    }

    private func fetchSteps(_ context: ModelContext, routineId: UUID) throws -> [Step] {
        try context.fetch(FetchDescriptor<Step>(
            predicate: #Predicate { $0.routineId == routineId },
            sortBy: [SortDescriptor(\.order, order: .forward)]
        ))
    }

    // MARK: - Pure derivation

    @Test func emptyResultsProduceNoGroups() {
        #expect(SessionHistoryPresentation.groupedResults(results: [], steps: []).isEmpty)
    }

    @Test func resolvableStepEnrichesTitle() {
        let step = Step(routineId: UUID(), order: 0, title: "ベンチプレス", sets: 2, repsTarget: 10, restSeconds: 60)
        let r0 = StepResult(sessionId: UUID(), stepId: step.id, setIndex: 0, done: true, actualReps: 10)
        let r1 = StepResult(sessionId: UUID(), stepId: step.id, setIndex: 1, done: true, actualReps: 8)
        let groups = SessionHistoryPresentation.groupedResults(results: [r0, r1], steps: [step])
        #expect(groups.count == 1)
        #expect(groups[0].title == "ベンチプレス")
        #expect(groups[0].isOrphaned == false)
        #expect(groups[0].results.map(\.setIndex) == [0, 1])
        #expect(groups[0].results.map(\.actualReps) == [10, 8])
    }

    @Test func orphanedStepStaysVisibleWithFallbackTitle() {
        // No Step provided → result is orphaned but must NOT be dropped.
        let stepId = UUID()
        let r0 = StepResult(sessionId: UUID(), stepId: stepId, setIndex: 0, done: true, actualReps: 12)
        let groups = SessionHistoryPresentation.groupedResults(results: [r0], steps: [])
        #expect(groups.count == 1)
        #expect(groups[0].isOrphaned)
        #expect(groups[0].title == SessionHistoryPresentation.orphanedTitle)
        #expect(groups[0].results.first?.actualReps == 12)
        #expect(groups[0].results.first?.done == true)
    }

    @Test func mixedResolvedAndOrphanedBothVisibleResolvedFirst() {
        let live = Step(routineId: UUID(), order: 0, title: "スクワット", sets: 1, repsTarget: 5, restSeconds: 90)
        let liveResult = StepResult(sessionId: UUID(), stepId: live.id, setIndex: 0, done: true, actualReps: 5)
        let orphanResult = StepResult(sessionId: UUID(), stepId: UUID(), setIndex: 0, done: false, actualReps: nil)
        let groups = SessionHistoryPresentation.groupedResults(results: [liveResult, orphanResult], steps: [live])
        #expect(groups.count == 2)
        // Resolvable step first, orphaned after.
        #expect(groups[0].title == "スクワット")
        #expect(groups[0].isOrphaned == false)
        #expect(groups[1].isOrphaned)
        #expect(groups[1].title == SessionHistoryPresentation.orphanedTitle)
    }

    @Test func orphanOrderingIsDeterministicAcrossFetchOrdersAndSetIndexTies() {
        let sessionId = UUID()
        let earlierStepId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let laterStepId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let earlierResultId = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let laterResultId = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let later = StepResult(
            id: laterResultId, sessionId: sessionId, stepId: laterStepId,
            setIndex: 0, done: true, actualReps: 8
        )
        let earlier = StepResult(
            id: earlierResultId, sessionId: sessionId, stepId: earlierStepId,
            setIndex: 0, done: true, actualReps: 10
        )

        let forward = SessionHistoryPresentation.groupedResults(
            results: [later, earlier], steps: []
        )
        let reversed = SessionHistoryPresentation.groupedResults(
            results: [earlier, later], steps: []
        )

        #expect(forward.map(\.id) == [earlierStepId, laterStepId])
        #expect(reversed.map(\.id) == [earlierStepId, laterStepId])
        #expect(forward.flatMap(\.results).map(\.actualReps) == [10, 8])
        #expect(reversed.flatMap(\.results).map(\.actualReps) == [10, 8])
    }

    // MARK: - Real deletion semantics (integration)

    @Test func stepDeletionKeepsHistoricalResultVisible() throws {
        let context = try makeContext()
        let routine = Routine(name: "Push")
        context.insert(routine)
        let step = Step(routineId: routine.id, order: 0, title: "チェストプレス", sets: 2, repsTarget: 10, restSeconds: 60)
        context.insert(step)
        let session = Session(routineId: routine.id, dayDate: Date(), status: .completed)
        context.insert(session)
        context.insert(StepResult(sessionId: session.id, stepId: step.id, setIndex: 0, done: true, actualReps: 10))
        context.insert(StepResult(sessionId: session.id, stepId: step.id, setIndex: 1, done: true, actualReps: 9))
        try context.save()

        // Before deletion: resolvable.
        var groups = SessionHistoryPresentation.groupedResults(
            results: try fetchResults(context, sessionId: session.id),
            steps: try fetchSteps(context, routineId: routine.id)
        )
        #expect(groups.count == 1)
        #expect(groups[0].title == "チェストプレス")

        // Delete the Step using the supported deletion (RoutineEditor semantics).
        context.delete(step)
        try context.save()

        // After deletion: StepResult persists and stays visible (orphaned).
        let remainingResults = try fetchResults(context, sessionId: session.id)
        #expect(remainingResults.count == 2)
        groups = SessionHistoryPresentation.groupedResults(
            results: remainingResults,
            steps: try fetchSteps(context, routineId: routine.id)
        )
        #expect(groups.count == 1)
        #expect(groups[0].isOrphaned)
        #expect(groups[0].results.map(\.actualReps) == [10, 9])
    }

    @Test func routineDeletionKeepsHistoricalResultVisible() throws {
        let context = try makeContext()
        let routine = Routine(name: "Legs")
        context.insert(routine)
        let step = Step(routineId: routine.id, order: 0, title: "レッグプレス", sets: 1, repsTarget: 8, restSeconds: 60)
        context.insert(step)
        let session = Session(routineId: routine.id, dayDate: Date(), status: .completed)
        context.insert(session)
        context.insert(StepResult(sessionId: session.id, stepId: step.id, setIndex: 0, done: true, actualReps: 8))
        try context.save()

        // Delete routine + its steps (WorkoutView.deleteRoutine semantics).
        context.delete(step)
        context.delete(routine)
        try context.save()

        let remainingResults = try fetchResults(context, sessionId: session.id)
        #expect(remainingResults.count == 1)
        let steps = try fetchSteps(context, routineId: routine.id)
        #expect(steps.isEmpty)
        let groups = SessionHistoryPresentation.groupedResults(results: remainingResults, steps: steps)
        #expect(groups.count == 1)
        #expect(groups[0].isOrphaned)
        #expect(groups[0].results.first?.actualReps == 8)
        #expect(groups[0].results.first?.done == true)
    }
}
