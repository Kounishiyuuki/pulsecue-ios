//
//  AITrainingPlanNormalizerTests.swift
//  Pulse CueTests
//
//  Pure unit tests for the local-only AI planning boundary: the
//  deterministic mock provider and the normalizer that converts raw
//  (untrusted) AI output into a `WeeklyTrainingPlanCandidate`. No
//  networking, no real AI, no SwiftData / ModelContext — everything is
//  value-level and offline.
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct AITrainingPlanNormalizerTests {

    // A small deterministic catalog so tests don't depend on the shipped
    // catalog's exact contents (other than where explicitly noted).
    private func testCatalog() -> [MachineCatalogEntry] {
        [
            MachineCatalogEntry(id: "chest_press", displayName: "チェストプレス", bodyParts: [.chest]),
            MachineCatalogEntry(id: "lat_pulldown", displayName: "ラットプルダウン", bodyParts: [.back, .arms]),
            MachineCatalogEntry(id: "leg_press", displayName: "レッグプレス", bodyParts: [.legs]),
        ]
    }

    // MARK: - Mock provider

    @Test
    func mockProviderIsDeterministic() async throws {
        let provider = MockAITrainingPlanProvider()
        let request = AITrainingPlanRequest(
            userMessage: "胸と背中を鍛えたい",
            goal: .hypertrophy,
            daysPerWeek: 3,
            availableMachineIds: ["chest_press", "lat_pulldown", "leg_press"]
        )
        let a = try await provider.generatePlan(for: request)
        let b = try await provider.generatePlan(for: request)
        #expect(a == b)
        #expect(a.sessions.count == 3)
    }

    @Test
    func mockProviderClampsDays() async throws {
        let provider = MockAITrainingPlanProvider()
        let high = try await provider.generatePlan(for: AITrainingPlanRequest(daysPerWeek: 99))
        #expect(high.sessions.count == MockAITrainingPlanProvider.maxDays)
        let low = try await provider.generatePlan(for: AITrainingPlanRequest(daysPerWeek: 0))
        #expect(low.sessions.count == MockAITrainingPlanProvider.minDays)
    }

    @Test
    func mockProviderFallsBackToCatalogWhenNoMachinesGiven() async throws {
        let provider = MockAITrainingPlanProvider()
        let response = try await provider.generatePlan(for: AITrainingPlanRequest(daysPerWeek: 2))
        let allIds = Set(response.sessions.flatMap(\.exerciseMachineIds))
        #expect(!allIds.isEmpty)
        // Every produced id is a real catalog id.
        #expect(allIds.allSatisfy { MachineCatalog.entry(for: $0) != nil })
    }

    // MARK: - End-to-end (mock → normalizer)

    @Test
    func mockResponseNormalizesIntoValidCandidate() async throws {
        let catalog = testCatalog()
        let request = AITrainingPlanRequest(
            goal: .strength,
            daysPerWeek: 3,
            availableMachineIds: catalog.map(\.id)
        )
        let response = try await MockAITrainingPlanProvider().generatePlan(for: request)
        let candidate = AITrainingPlanNormalizer.normalize(
            response: response, request: request, catalog: catalog
        )
        #expect(!candidate.isEmpty)
        #expect(candidate.goal == .strength)
        #expect(candidate.sessions.allSatisfy { !$0.exercises.isEmpty })
        // Every exercise resolves to a catalog machine and is candidate-only.
        let ids = candidate.sessions.flatMap { $0.exercises.map(\.machineId) }
        #expect(ids.allSatisfy { id in catalog.contains { $0.id == id } })
    }

    // MARK: - Validation / safety

    @Test
    func unknownMachineIdsAreDroppedAndWarned() {
        let catalog = testCatalog()
        let response = AITrainingPlanResponse(
            title: "Test",
            sessions: [
                AITrainingSessionResponse(
                    title: "Day 1",
                    exerciseMachineIds: ["chest_press", "totally_fake", "another_fake"]
                )
            ]
        )
        let candidate = AITrainingPlanNormalizer.normalize(
            response: response, request: AITrainingPlanRequest(), catalog: catalog
        )
        let ids = candidate.sessions.flatMap { $0.exercises.map(\.machineId) }
        #expect(ids == ["chest_press"])
        #expect(candidate.warnings.contains { $0.contains("totally_fake") })
        #expect(candidate.warnings.contains { $0.contains("another_fake") })
    }

    @Test
    func sessionsWithNoValidMachinesAreSkippedWithWarning() {
        let catalog = testCatalog()
        let response = AITrainingPlanResponse(
            sessions: [
                AITrainingSessionResponse(title: "良い日", exerciseMachineIds: ["leg_press"]),
                AITrainingSessionResponse(title: "空の日", exerciseMachineIds: ["nope"]),
                AITrainingSessionResponse(title: "完全に空", exerciseMachineIds: []),
            ]
        )
        let candidate = AITrainingPlanNormalizer.normalize(
            response: response, request: AITrainingPlanRequest(), catalog: catalog
        )
        #expect(candidate.sessions.count == 1)
        #expect(candidate.sessions.first?.title == "良い日")
        #expect(candidate.warnings.contains { $0.contains("空の日") })
        #expect(candidate.warnings.contains { $0.contains("完全に空") })
    }

    @Test
    func missingSessionTitleUsesDayFallback() {
        let catalog = testCatalog()
        let response = AITrainingPlanResponse(
            sessions: [
                AITrainingSessionResponse(title: nil, exerciseMachineIds: ["chest_press"]),
                AITrainingSessionResponse(title: "   ", exerciseMachineIds: ["leg_press"]),
            ]
        )
        let candidate = AITrainingPlanNormalizer.normalize(
            response: response, request: AITrainingPlanRequest(), catalog: catalog
        )
        #expect(candidate.sessions.map(\.title) == ["Day 1", "Day 2"])
    }

    @Test
    func missingPlanTitleUsesGoalFallback() {
        let candidate = AITrainingPlanNormalizer.normalize(
            response: AITrainingPlanResponse(title: nil, sessions: []),
            request: AITrainingPlanRequest(goal: .fatLoss),
            catalog: testCatalog()
        )
        #expect(candidate.title.contains("減量"))
    }

    @Test
    func emptyResponseProducesEmptyCandidateWithWarningAndDoesNotCrash() {
        let candidate = AITrainingPlanNormalizer.normalize(
            response: AITrainingPlanResponse(),
            request: AITrainingPlanRequest(),
            catalog: testCatalog()
        )
        #expect(candidate.isEmpty)
        #expect(candidate.sessions.isEmpty)
        #expect(candidate.daysPerWeek == 0)
        #expect(!candidate.warnings.isEmpty)
    }

    @Test
    func responseWarningsArePreserved() {
        let candidate = AITrainingPlanNormalizer.normalize(
            response: AITrainingPlanResponse(
                sessions: [AITrainingSessionResponse(exerciseMachineIds: ["chest_press"])],
                warnings: ["モデルからの注意書き"]
            ),
            request: AITrainingPlanRequest(),
            catalog: testCatalog()
        )
        #expect(candidate.warnings.contains("モデルからの注意書き"))
    }

    @Test
    func focusBodyPartsAreDerivedInCanonicalOrder() {
        let catalog = testCatalog()
        // lat_pulldown → [.back, .arms]; canonical order is chest,back,legs,
        // shoulders,arms,core,fullBody, so back precedes arms.
        let response = AITrainingPlanResponse(
            sessions: [AITrainingSessionResponse(exerciseMachineIds: ["lat_pulldown"])]
        )
        let candidate = AITrainingPlanNormalizer.normalize(
            response: response, request: AITrainingPlanRequest(), catalog: catalog
        )
        #expect(candidate.sessions.first?.focusBodyParts == [.back, .arms])
    }

    @Test
    func daysPerWeekIsClampedToValidSessionCount() {
        let catalog = testCatalog()
        let sessions = (0..<10).map {
            AITrainingSessionResponse(title: "D\($0)", exerciseMachineIds: ["chest_press"])
        }
        let candidate = AITrainingPlanNormalizer.normalize(
            response: AITrainingPlanResponse(sessions: sessions),
            request: AITrainingPlanRequest(),
            catalog: catalog
        )
        // 10 valid sessions, but daysPerWeek is clamped to the 6 ceiling.
        #expect(candidate.daysPerWeek == AITrainingPlanNormalizer.maxDays)
        #expect(candidate.sessions.count == 10)
    }
}
