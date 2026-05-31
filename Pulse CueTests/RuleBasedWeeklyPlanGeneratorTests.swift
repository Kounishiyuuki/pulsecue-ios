//
//  RuleBasedWeeklyPlanGeneratorTests.swift
//  Pulse CueTests
//
//  Pure unit tests for `RuleBasedWeeklyPlanGenerator`. No SwiftData, no
//  ModelContext, no networking — the generator is a deterministic value
//  transform, so these assert on its output values only. A small custom
//  catalog is injected in several tests to prove the generator has no
//  hidden global/context dependency.
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct RuleBasedWeeklyPlanGeneratorTests {

    // MARK: - Determinism

    @Test
    func generatorIsDeterministic() {
        let request = TrainingPlanGenerationRequest(
            goal: .hypertrophy,
            daysPerWeek: 4,
            targetBodyParts: [.chest, .back, .legs],
            experienceLevel: .intermediate,
            preferredSplit: .upperLower
        )
        let a = RuleBasedWeeklyPlanGenerator.generate(request: request)
        let b = RuleBasedWeeklyPlanGenerator.generate(request: request)
        #expect(a == b)
    }

    // MARK: - Days clamping

    @Test
    func daysPerWeekIsClampedToSafeRange() {
        let low = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(daysPerWeek: 0)
        )
        #expect(low.daysPerWeek == RuleBasedWeeklyPlanGenerator.minDays)
        #expect(low.sessions.count == RuleBasedWeeklyPlanGenerator.minDays)
        #expect(low.warnings.contains { $0.contains("日数") })

        let high = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(daysPerWeek: 99)
        )
        #expect(high.daysPerWeek == RuleBasedWeeklyPlanGenerator.maxDays)
        #expect(high.sessions.count == RuleBasedWeeklyPlanGenerator.maxDays)
        #expect(high.warnings.contains { $0.contains("日数") })
    }

    @Test
    func validDaysProduceNoClampWarning() {
        let plan = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(daysPerWeek: 3)
        )
        #expect(plan.daysPerWeek == 3)
        #expect(!plan.warnings.contains { $0.contains("日数") })
    }

    // MARK: - Balanced fallback

    @Test
    func emptyTargetBodyPartsProducesBalancedFullBodyPlan() {
        let plan = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(daysPerWeek: 3, targetBodyParts: [])
        )
        #expect(plan.sessions.count == 3)
        // Every session has at least one exercise from the real catalog.
        #expect(plan.sessions.allSatisfy { !$0.exercises.isEmpty })
        // Across the week the plan touches several distinct body parts.
        let coveredParts = Set(plan.sessions.flatMap { $0.exercises.flatMap(\.bodyParts) })
        #expect(coveredParts.count >= 3)
    }

    // MARK: - Target influence

    @Test
    func targetBodyPartsDriveExerciseSelection() {
        let plan = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(
                daysPerWeek: 2,
                targetBodyParts: [.legs],
                preferredSplit: .fullBody
            )
        )
        let machineIds = Set(plan.sessions.flatMap { $0.exercises.map(\.machineId) })
        let selectedEntries = machineIds.compactMap { MachineCatalog.entry(for: $0) }
        #expect(selectedEntries.allSatisfy {
            $0.bodyParts.contains(BodyPart.legs) || $0.secondaryMuscles.contains(BodyPart.legs)
        })
        // Pure-chest machines should not appear when focus is legs only.
        #expect(!machineIds.contains("bench_press"))
        #expect(!machineIds.contains("pec_deck"))
    }

    // MARK: - Limited body parts

    @Test
    func limitedBodyPartsAreAvoidedWhenPossible() {
        let plan = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(
                daysPerWeek: 4,
                targetBodyParts: [],
                limitedBodyParts: [.legs],
                preferredSplit: .fullBody
            )
        )
        // No session should focus on legs…
        #expect(plan.sessions.allSatisfy { !$0.focusBodyParts.contains(.legs) })
        // …and a legs-only machine should not be selected.
        let machineIds = Set(plan.sessions.flatMap { $0.exercises.map(\.machineId) })
        #expect(!machineIds.contains("leg_press"))
        #expect(!machineIds.contains("leg_curl"))
        #expect(!machineIds.contains("leg_extension"))
    }

    @Test
    func limitingEveryPartFallsBackInsteadOfEmptyPlan() {
        // Limiting all balanced parts would empty the set; the generator
        // must warn and still produce a usable plan.
        let plan = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(
                daysPerWeek: 2,
                targetBodyParts: [.chest],
                limitedBodyParts: [.chest]
            )
        )
        #expect(plan.sessions.allSatisfy { !$0.exercises.isEmpty })
        #expect(plan.warnings.contains { $0.contains("制限") })
    }

    // MARK: - Sparse catalog / beginner filter

    @Test
    func beginnerFriendlyOnlyDoesNotCrashWithSparseCatalog() {
        // The shipped catalog has no beginnerFriendly flags, so the filter
        // must relax rather than yield an empty plan.
        let plan = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(
                daysPerWeek: 3,
                beginnerFriendlyOnly: true
            )
        )
        #expect(plan.sessions.allSatisfy { !$0.exercises.isEmpty })
        #expect(plan.warnings.contains { $0.contains("初心者") })
    }

    @Test
    func beginnerFriendlyOnlyHonoredWhenCatalogSupportsIt() {
        let catalog = [
            MachineCatalogEntry(id: "bf_chest", displayName: "BFチェスト", bodyParts: [.chest], beginnerFriendly: true),
            MachineCatalogEntry(id: "hard_chest", displayName: "上級チェスト", bodyParts: [.chest], beginnerFriendly: false),
        ]
        let plan = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(
                daysPerWeek: 1,
                targetBodyParts: [.chest],
                beginnerFriendlyOnly: true
            ),
            catalog: catalog
        )
        let machineIds = Set(plan.sessions.flatMap { $0.exercises.map(\.machineId) })
        #expect(machineIds == ["bf_chest"])
        #expect(!plan.warnings.contains { $0.contains("初心者") })
    }

    // MARK: - Output shape / candidate-only guarantee

    @Test
    func sessionsContainRoutineStepCandidates() {
        let plan = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(daysPerWeek: 2)
        )
        let firstExercise = try! #require(plan.sessions.first?.exercises.first)
        // It is a RoutineStepCandidate carrying catalog-derived data.
        #expect(!firstExercise.machineId.isEmpty)
        #expect(!firstExercise.exerciseName.isEmpty)
        #expect(firstExercise.sourceLabel == RuleBasedWeeklyPlanGenerator.sourceLabel)
        // Sparse catalog → resolved fallbacks are used (no Step created).
        #expect(firstExercise.resolvedSets == RoutineStepCandidate.fallbackSets)
    }

    @Test
    func injectedCatalogFullyControlsSelection() {
        // Proves there is no hidden dependency on MachineCatalog.all or a
        // ModelContext: only the injected entries can appear.
        let catalog = [
            MachineCatalogEntry(id: "only_a", displayName: "A", bodyParts: [.chest]),
            MachineCatalogEntry(id: "only_b", displayName: "B", bodyParts: [.back]),
        ]
        let plan = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(daysPerWeek: 2),
            catalog: catalog
        )
        let machineIds = Set(plan.sessions.flatMap { $0.exercises.map(\.machineId) })
        #expect(machineIds.isSubset(of: ["only_a", "only_b"]))
        #expect(!machineIds.isEmpty)
    }

    @Test
    func emptyCatalogYieldsEmptyExercisesWithWarning() {
        let plan = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(daysPerWeek: 3),
            catalog: []
        )
        #expect(plan.sessions.count == 3)
        #expect(plan.isEmpty)
        #expect(plan.sessions.allSatisfy { $0.exercises.isEmpty })
        #expect(plan.warnings.contains { $0.contains("空") })
    }

    @Test
    func exerciseCountRespectsExperienceGoalAndDuration() {
        // Advanced + hypertrophy → up to 5; a short session caps it.
        let long = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(
                goal: .hypertrophy, daysPerWeek: 1,
                experienceLevel: .advanced, preferredSplit: .fullBody
            )
        )
        #expect((long.sessions.first?.exercises.count ?? 0) <= 5)

        let short = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(
                goal: .hypertrophy, daysPerWeek: 1,
                experienceLevel: .advanced, preferredSplit: .fullBody,
                sessionDurationMinutes: 24
            )
        )
        // 24 / 12 = 2 cap.
        #expect((short.sessions.first?.exercises.count ?? 0) <= 2)
    }

    // MARK: - Enum display names

    @Test
    func enumDisplayNamesAreNonEmpty() {
        for g in TrainingGoal.allCases { #expect(!g.displayName.isEmpty) }
        for e in ExperienceLevel.allCases { #expect(!e.displayName.isEmpty) }
        for s in TrainingSplit.allCases { #expect(!s.displayName.isEmpty) }
    }
}
