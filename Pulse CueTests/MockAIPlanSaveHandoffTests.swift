//
//  MockAIPlanSaveHandoffTests.swift
//  Pulse CueTests
//
//  Covers the mock-AI → routine save handoff: a candidate produced by
//  `MockAITrainingPlanProvider` + `AITrainingPlanNormalizer` converts
//  through the existing `RoutineFactory.makeRoutines(from:)` path, and
//  nothing persists until an explicit `modelContext.insert`. Reuses the
//  shared `WeeklyPlanSaveState` for duplicate-save prevention. No real
//  AI, no networking, no schema migration.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

@MainActor
struct MockAIPlanSaveHandoffTests {

    private static func makeContext() throws -> ModelContext {
        let schema = Schema([Routine.self, Step.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    /// Drives the same pipeline the chat view uses: mock provider →
    /// normalizer → candidate.
    private func mockCandidate(
        daysPerWeek: Int = 3,
        goal: TrainingGoal = .hypertrophy,
        machineIds: [String] = ["chest_press", "lat_pulldown", "leg_press"]
    ) async throws -> WeeklyTrainingPlanCandidate {
        let request = AITrainingPlanRequest(
            userMessage: "テスト",
            goal: goal,
            daysPerWeek: daysPerWeek,
            availableMachineIds: machineIds
        )
        let response = try await MockAITrainingPlanProvider().generatePlan(for: request)
        return AITrainingPlanNormalizer.normalize(response: response, request: request)
    }

    // MARK: - Generation creates nothing

    @Test
    func generatingCandidateCreatesNoRoutines() async throws {
        let context = try Self.makeContext()
        _ = try await mockCandidate()
        // Producing the candidate is value-only — no persistence.
        #expect(try context.fetchCount(FetchDescriptor<Routine>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Step>()) == 0)
    }

    // MARK: - Conversion

    @Test
    func candidateConvertsToOneRoutinePerNonEmptySession() async throws {
        let candidate = try await mockCandidate(daysPerWeek: 3)
        let outputs = RoutineFactory.makeRoutines(from: candidate)
        let expected = candidate.sessions.filter { !$0.exercises.isEmpty }.count
        #expect(outputs.count == expected)
        #expect(outputs.count == candidate.savableSessionCount)
        // Each routine is named after its source session.
        let nonEmptyTitles = candidate.sessions.filter { !$0.exercises.isEmpty }.map(\.title)
        #expect(outputs.map(\.routine.name) == nonEmptyTitles)
    }

    // MARK: - Explicit-save boundary

    @Test
    func buildingCreatesNothingUntilExplicitInsert() async throws {
        let context = try Self.makeContext()
        let candidate = try await mockCandidate(daysPerWeek: 2)

        let outputs = RoutineFactory.makeRoutines(from: candidate)
        #expect(!outputs.isEmpty)
        // Built, not inserted.
        #expect(try context.fetchCount(FetchDescriptor<Routine>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Step>()) == 0)

        // Explicit confirmation: insert routines + steps.
        for output in outputs {
            context.insert(output.routine)
            for step in output.steps { context.insert(step) }
        }

        #expect(try context.fetchCount(FetchDescriptor<Routine>()) == outputs.count)
        let totalSteps = outputs.reduce(0) { $0 + $1.steps.count }
        #expect(try context.fetchCount(FetchDescriptor<Step>()) == totalSteps)
    }

    @Test
    func savedRoutineStepsLinkToTheirRoutine() async throws {
        let context = try Self.makeContext()
        let candidate = try await mockCandidate(daysPerWeek: 1)
        let outputs = RoutineFactory.makeRoutines(from: candidate)
        for output in outputs {
            context.insert(output.routine)
            for step in output.steps { context.insert(step) }
        }
        let routines = try context.fetch(FetchDescriptor<Routine>())
        let steps = try context.fetch(FetchDescriptor<Step>())
        let routineIds = Set(routines.map(\.id))
        #expect(!steps.isEmpty)
        #expect(steps.allSatisfy { routineIds.contains($0.routineId) })
    }

    // MARK: - Duplicate-save prevention (shared save state)

    @Test
    func saveStateBlocksReSaveAfterSavingAndResetsOnRegenerate() {
        // The chat view reuses WeeklyPlanSaveState exactly as the weekly
        // review screen does: savable while idle, blocked once saved.
        var state = WeeklyPlanSaveState.idle
        #expect(state.canSave)
        state = .saved(routineCount: 3)
        #expect(!state.canSave)
        // Regenerating resets to idle, re-enabling save for the new candidate.
        state = .idle
        #expect(state.canSave)
    }
}
