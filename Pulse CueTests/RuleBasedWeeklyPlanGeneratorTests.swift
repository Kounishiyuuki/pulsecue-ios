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
import SwiftData
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
    func beginnerFriendlyOnlyIsHonoredByShippedCatalog() {
        // Since the 1.0 catalog now carries real beginnerFriendly flags,
        // beginner-only mode filters for real instead of relaxing: every
        // balanced body part still has a beginner-friendly machine, so the
        // plan is non-empty, only beginner-friendly machines are chosen, and
        // no "初心者向け条件を緩和" warning is emitted.
        let plan = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(
                daysPerWeek: 3,
                beginnerFriendlyOnly: true
            )
        )
        #expect(plan.sessions.allSatisfy { !$0.exercises.isEmpty })
        let machineIds = Set(plan.sessions.flatMap { $0.exercises.map(\.machineId) })
        let selected = machineIds.compactMap { MachineCatalog.entry(for: $0) }
        #expect(selected.allSatisfy { $0.beginnerFriendly == true })
        #expect(!plan.warnings.contains { $0.contains("初心者") })
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
            equipment: AvailableEquipment.standardCatalog(catalog)
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
            equipment: AvailableEquipment.standardCatalog(catalog)
        )
        let machineIds = Set(plan.sessions.flatMap { $0.exercises.map(\.machineId) })
        #expect(machineIds.isSubset(of: ["only_a", "only_b"]))
        #expect(!machineIds.isEmpty)
    }

    @Test
    func emptyCatalogYieldsEmptyExercisesWithWarning() {
        let plan = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(daysPerWeek: 3),
            equipment: []
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

    // MARK: - 1.0 catalog expansion

    @Test
    func newCatalogMachinesContributeToWeeklyPlanViaExistingPath() {
        // The weekly generator reads catalog entries + fallback generation
        // directly (no per-machine template table), so a representative new
        // machine surfaces in a plan just by being in the catalog. Inject a
        // single-entry catalog to prove it end-to-end for each part family.
        let cases: [(id: String, part: BodyPart)] = [
            ("hack_squat", .legs),
            ("incline_chest_press", .chest),
            ("lateral_raise_machine", .shoulders),
            ("abdominal_machine", .core),
        ]
        for c in cases {
            let entry = MachineCatalog.entry(for: c.id)!
            let plan = RuleBasedWeeklyPlanGenerator.generate(
                request: TrainingPlanGenerationRequest(daysPerWeek: 1, targetBodyParts: [c.part]),
                equipment: AvailableEquipment.standardCatalog([entry])
            )
            let machineIds = Set(plan.sessions.flatMap { $0.exercises.map(\.machineId) })
            #expect(machineIds.contains(c.id), "\(c.id) did not appear in a weekly plan")
        }
    }

    // MARK: - Enum display names

    @Test
    func enumDisplayNamesAreNonEmpty() {
        for g in TrainingGoal.allCases { #expect(!g.displayName.isEmpty) }
        for e in ExperienceLevel.allCases { #expect(!e.displayName.isEmpty) }
        for s in TrainingSplit.allCases { #expect(!s.displayName.isEmpty) }
    }

    // MARK: - Variation seed

    private static let variedRequest = TrainingPlanGenerationRequest(
        goal: .hypertrophy,
        daysPerWeek: 3,
        targetBodyParts: [.chest, .back, .legs],
        experienceLevel: .intermediate,
        preferredSplit: .fullBody
    )

    private static func machineIds(_ plan: WeeklyTrainingPlanCandidate) -> [[String]] {
        plan.sessions.map { $0.exercises.map(\.machineId) }
    }

    @Test
    func sameSeedYieldsSamePlan() {
        for seed: UInt64 in [0, 1, 42, .max] {
            let a = RuleBasedWeeklyPlanGenerator.generate(request: Self.variedRequest, variationSeed: seed)
            let b = RuleBasedWeeklyPlanGenerator.generate(request: Self.variedRequest, variationSeed: seed)
            #expect(a == b)
        }
    }

    @Test
    func differentSeedsYieldDifferentPlansWhenCatalogIsRich() {
        let base = RuleBasedWeeklyPlanGenerator.generate(request: Self.variedRequest, variationSeed: 0)
        #expect(base.hasAlternatives)
        let distinct = Set((0..<10).map {
            Self.machineIds(RuleBasedWeeklyPlanGenerator.generate(request: Self.variedRequest, variationSeed: UInt64($0)))
        })
        #expect(distinct.count > 1)
    }

    @Test
    func seedsNeverBreakTargetLimitedOrBeginnerConstraints() {
        let request = TrainingPlanGenerationRequest(
            daysPerWeek: 4,
            limitedBodyParts: [.legs],
            preferredSplit: .fullBody,
            beginnerFriendlyOnly: true
        )
        for seed in UInt64(1)...30 {
            let plan = RuleBasedWeeklyPlanGenerator.generate(request: request, variationSeed: seed)
            let ids = Set(plan.sessions.flatMap { $0.exercises.map(\.machineId) })
            #expect(plan.sessions.allSatisfy { !$0.exercises.isEmpty && !$0.focusBodyParts.contains(.legs) })
            #expect(ids.isDisjoint(with: ["leg_press", "leg_curl", "leg_extension"]))
            #expect(ids.compactMap { MachineCatalog.entry(for: $0) }.allSatisfy { $0.beginnerFriendly == true })
        }

        let chestOnly = TrainingPlanGenerationRequest(daysPerWeek: 2, targetBodyParts: [.chest])
        for seed in UInt64(1)...30 {
            let plan = RuleBasedWeeklyPlanGenerator.generate(request: chestOnly, variationSeed: seed)
            let entries = plan.sessions.flatMap { $0.exercises.map(\.machineId) }.compactMap { MachineCatalog.entry(for: $0) }
            #expect(!entries.isEmpty)
            #expect(entries.allSatisfy { $0.bodyParts.contains(.chest) })
        }
    }

    @Test
    func seedsNeverSelectUnavailableEquipment() {
        let equipment = [
            AvailableEquipment(entry: MachineCatalogEntry(id: "ok_a", displayName: "A", bodyParts: [.chest])),
            AvailableEquipment(entry: MachineCatalogEntry(id: "ok_b", displayName: "B", bodyParts: [.chest])),
            AvailableEquipment(entry: MachineCatalogEntry(id: "off", displayName: "Off", bodyParts: [.chest]), isAvailable: false),
        ]
        for seed in UInt64(0)...30 {
            let plan = RuleBasedWeeklyPlanGenerator.generate(
                request: TrainingPlanGenerationRequest(daysPerWeek: 3, targetBodyParts: [.chest]),
                equipment: equipment,
                variationSeed: seed
            )
            let ids = Set(plan.sessions.flatMap { $0.exercises.map(\.machineId) })
            #expect(!ids.contains("off"))
            #expect(!ids.isEmpty)
        }
    }

    @Test
    func weekPrefersUnusedEquipmentWhenEnoughCandidates() {
        let equipment = AvailableEquipment.standardCatalog((1...6).map {
            MachineCatalogEntry(id: "c\($0)", displayName: "C\($0)", bodyParts: [.chest])
        })
        let request = TrainingPlanGenerationRequest(daysPerWeek: 2, targetBodyParts: [.chest])
        for seed in UInt64(0)...10 {
            let plan = RuleBasedWeeklyPlanGenerator.generate(request: request, equipment: equipment, variationSeed: seed)
            let all = plan.sessions.flatMap { $0.exercises.map(\.machineId) }
            #expect(all.count == 6)                // 3 per day × 2 days
            #expect(Set(all).count == all.count)   // no repeats across the week
        }
    }

    @Test
    func sparseCatalogReusesEquipmentInsteadOfEmptyingDays() {
        let equipment = AvailableEquipment.standardCatalog([
            MachineCatalogEntry(id: "solo", displayName: "Solo", bodyParts: [.chest]),
        ])
        for seed in UInt64(0)...10 {
            let plan = RuleBasedWeeklyPlanGenerator.generate(
                request: TrainingPlanGenerationRequest(daysPerWeek: 4),
                equipment: equipment,
                variationSeed: seed
            )
            #expect(plan.sessions.allSatisfy { $0.exercises.map(\.machineId) == ["solo"] })
            // One machine: there is no other plan to offer.
            #expect(!plan.hasAlternatives)
        }
        let empty = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(daysPerWeek: 2),
            equipment: [],
            variationSeed: 7
        )
        #expect(empty.isEmpty)
        #expect(!empty.hasAlternatives)
    }

    @Test
    func regeneratingWithNewSeedPersistsNothing() throws {
        let schema = Schema([Routine.self, Step.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let context = ModelContext(try ModelContainer(for: schema, configurations: [config]))
        for seed in UInt64(0)...5 {
            _ = RuleBasedWeeklyPlanGenerator.generate(request: Self.variedRequest, variationSeed: seed)
        }
        #expect(try context.fetchCount(FetchDescriptor<Routine>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Step>()) == 0)
        #expect(!context.hasChanges)
    }

    // MARK: - Next distinct variation

    /// Two chest machines, one exercise per session (12 min → 1 exercise):
    /// the smallest pool that still has an alternative.
    private static let tinyEquipment = AvailableEquipment.standardCatalog([
        MachineCatalogEntry(id: "t_a", displayName: "TA", bodyParts: [.chest]),
        MachineCatalogEntry(id: "t_b", displayName: "TB", bodyParts: [.chest]),
    ])
    private static let tinyRequest = TrainingPlanGenerationRequest(
        daysPerWeek: 1, targetBodyParts: [.chest], sessionDurationMinutes: 12
    )

    @Test
    func nextDistinctVariationDiffersOnTinyPool() throws {
        for start in UInt64(0)...20 {
            let current = RuleBasedWeeklyPlanGenerator.generate(
                request: Self.tinyRequest, equipment: Self.tinyEquipment, variationSeed: start
            )
            #expect(current.hasAlternatives)
            let next = try #require(RuleBasedWeeklyPlanGenerator.nextDistinctVariation(
                request: Self.tinyRequest, equipment: Self.tinyEquipment, current: current, currentSeed: start
            ))
            #expect(next.candidate != current)
            #expect(next.seed != start)
            // The returned seed reproduces the returned plan.
            #expect(RuleBasedWeeklyPlanGenerator.generate(
                request: Self.tinyRequest, equipment: Self.tinyEquipment, variationSeed: next.seed
            ) == next.candidate)
        }
    }

    @Test
    func nextDistinctVariationSkipsAdjacentSeedWithSamePlan() throws {
        func plan(_ seed: UInt64) -> WeeklyTrainingPlanCandidate {
            RuleBasedWeeklyPlanGenerator.generate(
                request: Self.tinyRequest, equipment: Self.tinyEquipment, variationSeed: seed
            )
        }
        // Reproduce the bug case: seed s and s+1 map to the same plan.
        let start = try #require((UInt64(1)...200).first { plan($0) == plan($0 + 1) })
        let next = try #require(RuleBasedWeeklyPlanGenerator.nextDistinctVariation(
            request: Self.tinyRequest, equipment: Self.tinyEquipment, current: plan(start), currentSeed: start
        ))
        #expect(next.seed > start + 1)       // the duplicate neighbour was skipped
        #expect(next.candidate != plan(start))
        // Deterministic: asking again gives the same answer.
        let again = try #require(RuleBasedWeeklyPlanGenerator.nextDistinctVariation(
            request: Self.tinyRequest, equipment: Self.tinyEquipment, current: plan(start), currentSeed: start
        ))
        #expect(again.seed == next.seed && again.candidate == next.candidate)
    }

    @Test
    func nextDistinctVariationStopsWhenNoAlternativeExists() {
        let single = AvailableEquipment.standardCatalog([
            MachineCatalogEntry(id: "solo", displayName: "Solo", bodyParts: [.chest]),
        ])
        let current = RuleBasedWeeklyPlanGenerator.generate(request: Self.tinyRequest, equipment: single, variationSeed: 5)
        #expect(RuleBasedWeeklyPlanGenerator.nextDistinctVariation(
            request: Self.tinyRequest, equipment: single, current: current, currentSeed: 5
        ) == nil)
        // A zero budget never loops at all.
        #expect(RuleBasedWeeklyPlanGenerator.nextDistinctVariation(
            request: Self.tinyRequest, equipment: single, current: current, currentSeed: 0, maxAttempts: 0
        ) == nil)
    }

    @Test
    func nextDistinctVariationPersistsNothing() throws {
        let schema = Schema([Routine.self, Step.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let context = ModelContext(try ModelContainer(for: schema, configurations: [config]))
        var seed: UInt64 = 0
        var current = RuleBasedWeeklyPlanGenerator.generate(request: Self.tinyRequest, equipment: Self.tinyEquipment)
        for _ in 0..<5 {
            let next = try #require(RuleBasedWeeklyPlanGenerator.nextDistinctVariation(
                request: Self.tinyRequest, equipment: Self.tinyEquipment, current: current, currentSeed: seed
            ))
            seed = next.seed
            current = next.candidate
        }
        #expect(try context.fetchCount(FetchDescriptor<Routine>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Step>()) == 0)
        #expect(!context.hasChanges)
    }
}
