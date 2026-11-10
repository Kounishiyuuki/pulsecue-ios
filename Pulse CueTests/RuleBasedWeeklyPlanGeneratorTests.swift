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

// MARK: - Session themes

@MainActor
struct SessionThemeGeneratorTests {

    private static let equipment = AvailableEquipment.standardCatalog()
    private static let byId = Dictionary(uniqueKeysWithValues: equipment.map { ($0.id, $0) })

    /// 筋肥大・中級・上下分割・週4日・胸＋背中 — the scenario the spec names.
    private static func chestBack(_ theme: SessionTheme = .balanced) -> TrainingPlanGenerationRequest {
        TrainingPlanGenerationRequest(
            goal: .hypertrophy, daysPerWeek: 4, targetBodyParts: [.chest, .back],
            experienceLevel: .intermediate, preferredSplit: .upperLower, sessionTheme: theme
        )
    }

    /// Whole-body week so every body-part theme has a session to act on.
    private static func wholeBody(_ theme: SessionTheme) -> TrainingPlanGenerationRequest {
        TrainingPlanGenerationRequest(
            goal: .hypertrophy, daysPerWeek: 4, experienceLevel: .intermediate,
            preferredSplit: .upperLower, sessionTheme: theme
        )
    }

    private static func chosen(_ plan: WeeklyTrainingPlanCandidate) -> [AvailableEquipment] {
        plan.sessions.flatMap(\.exercises).compactMap { byId[$0.machineId] }
    }

    /// Total theme fit of everything the plan picked.
    private static func fit(_ plan: WeeklyTrainingPlanCandidate, _ theme: SessionTheme) -> Int {
        chosen(plan).map(theme.score).reduce(0, +)
    }

    private static func count(_ plan: WeeklyTrainingPlanCandidate, where predicate: (AvailableEquipment) -> Bool) -> Int {
        chosen(plan).filter(predicate).count
    }

    // MARK: Compatibility & determinism

    @Test
    func requestDefaultsToBalancedAndBalancedMatchesUnthemedRequest() {
        let unthemed = TrainingPlanGenerationRequest(
            goal: .hypertrophy, daysPerWeek: 4, targetBodyParts: [.chest, .back],
            experienceLevel: .intermediate, preferredSplit: .upperLower
        )
        #expect(unthemed.sessionTheme == .balanced)
        for seed: UInt64 in [0, 1, 7] {
            let a = RuleBasedWeeklyPlanGenerator.generate(request: unthemed, equipment: Self.equipment, variationSeed: seed)
            let b = RuleBasedWeeklyPlanGenerator.generate(request: Self.chestBack(.balanced), equipment: Self.equipment, variationSeed: seed)
            #expect(a == b)
            #expect(a.sessionTheme == .balanced)
        }
    }

    @Test
    func balancedRationaleIsUnchangedAndThemedRationaleNamesTheTheme() {
        let balanced = RuleBasedWeeklyPlanGenerator.generate(request: Self.chestBack(.balanced), equipment: Self.equipment)
        let chest = RuleBasedWeeklyPlanGenerator.generate(request: Self.chestBack(.chestFocus), equipment: Self.equipment)
        #expect(!balanced.rationale.contains("セッションの方向性"))
        #expect(chest.rationale.contains("胸重視"))
        #expect(chest.title == balanced.title)
    }

    @Test(arguments: SessionTheme.allCases)
    func sameRequestSeedAndThemeIsDeterministic(theme: SessionTheme) {
        for seed: UInt64 in [0, 3, 42] {
            let a = RuleBasedWeeklyPlanGenerator.generate(request: Self.wholeBody(theme), equipment: Self.equipment, variationSeed: seed)
            let b = RuleBasedWeeklyPlanGenerator.generate(request: Self.wholeBody(theme), equipment: Self.equipment, variationSeed: seed)
            #expect(a == b)
            #expect(a.sessionTheme == theme)
        }
    }

    @Test(arguments: SessionTheme.allCases)
    func seedsStillVaryThePlanWithinATheme(theme: SessionTheme) {
        let plans = (0..<12).map {
            RuleBasedWeeklyPlanGenerator.generate(request: Self.chestBack(theme), equipment: Self.equipment, variationSeed: UInt64($0))
        }
        let distinct = plans.reduce(into: [WeeklyTrainingPlanCandidate]()) { if !$0.contains($1) { $0.append($1) } }
        #expect(distinct.count >= 2)
        #expect(plans.allSatisfy { !$0.isEmpty && $0.sessionTheme == theme })
    }

    @Test
    func nextDistinctVariationKeepsTheThemeAndPersistsNothing() throws {
        let request = Self.chestBack(.backFocus)
        let current = RuleBasedWeeklyPlanGenerator.generate(request: request, equipment: Self.equipment)
        let next = try #require(RuleBasedWeeklyPlanGenerator.nextDistinctVariation(
            request: request, equipment: Self.equipment, current: current, currentSeed: 0
        ))
        #expect(next.candidate != current)
        #expect(next.candidate.sessionTheme == .backFocus)
        #expect(next.candidate == RuleBasedWeeklyPlanGenerator.generate(request: request, equipment: Self.equipment, variationSeed: next.seed))
    }

    // MARK: Themes change the composition

    /// Two days (one upper, one lower) so weekly de-duplication does not
    /// exhaust the pool — over a long week every machine ends up used and
    /// totals tie regardless of theme. Balanced follows pool order, so with the catalog reversed it no longer
    /// happens to pick themed machines early; each theme must then raise its
    /// own fit purely through priority. (With the normal order some themes —
    /// e.g. core, whose two machines sort first — already tie balanced.)
    @Test(arguments: SessionTheme.allCases.filter { $0 != .balanced })
    func everyThemeRaisesItsOwnFitOverBalanced(theme: SessionTheme) {
        let gym = Array(Self.equipment.reversed())
        func twoDays(_ t: SessionTheme) -> TrainingPlanGenerationRequest {
            var r = Self.wholeBody(t); r.daysPerWeek = 2; return r
        }
        let balanced = RuleBasedWeeklyPlanGenerator.generate(request: twoDays(.balanced), equipment: gym)
        let themed = RuleBasedWeeklyPlanGenerator.generate(request: twoDays(theme), equipment: gym)
        #expect(Self.fit(themed, theme) > Self.fit(balanced, theme))
        // And never lower with the normal order.
        let b2 = RuleBasedWeeklyPlanGenerator.generate(request: Self.wholeBody(.balanced), equipment: Self.equipment)
        let t2 = RuleBasedWeeklyPlanGenerator.generate(request: Self.wholeBody(theme), equipment: Self.equipment)
        #expect(Self.fit(t2, theme) >= Self.fit(b2, theme))
    }

    /// Measured on Day 1 (the first upper day): over the whole 4-day week
    /// de-duplication uses almost every chest/back machine whatever the
    /// theme, so the theme shows in what each session leads with.
    @Test
    func chestBackScenarioShiftsTowardTheChosenFocus() {
        func plan(_ theme: SessionTheme) -> WeeklyTrainingPlanCandidate {
            let full = RuleBasedWeeklyPlanGenerator.generate(request: Self.chestBack(theme), equipment: Self.equipment)
            return WeeklyTrainingPlanCandidate(
                title: full.title, goal: full.goal, daysPerWeek: 1,
                sessions: [full.sessions[0]], rationale: "", warnings: []
            )
        }
        let balanced = plan(.balanced)
        let isPush: (AvailableEquipment) -> Bool = { $0.catalogEntry?.movementPattern == .push }
        let isPull: (AvailableEquipment) -> Bool = { $0.catalogEntry?.movementPattern == .pull }
        #expect(Self.count(plan(.push), where: isPush) > Self.count(balanced, where: isPush))
        #expect(Self.count(plan(.pull), where: isPull) > Self.count(balanced, where: isPull))
        #expect(Self.fit(plan(.chestFocus), .chestFocus) > Self.fit(balanced, .chestFocus))
        #expect(Self.fit(plan(.backFocus), .backFocus) > Self.fit(balanced, .backFocus))
        #expect(Self.fit(plan(.press), .press) > Self.fit(balanced, .press))
        // Chest- and back-focused weeks really are different weeks.
        #expect(plan(.chestFocus) != plan(.backFocus))
    }

    /// The theme must hold on every session it applies to, not just Day 1:
    /// the later upper day (Day 3) re-uses strong fits from Day 1 rather
    /// than falling back to unused non-themed equipment.
    /// Per seed a themed session is never weaker than balanced (balanced can
    /// tie by chance when its leftovers already fit); over seeds each day
    /// must be strictly stronger.
    @Test(arguments: [SessionTheme.chestFocus, .backFocus, .push, .pull, .press])
    func themeHoldsOnEveryUpperSessionOfTheWeek(theme: SessionTheme) {
        var totals = [0: (themed: 0, balanced: 0), 2: (themed: 0, balanced: 0)]
        for seed: UInt64 in 0..<6 {
            let balanced = RuleBasedWeeklyPlanGenerator.generate(request: Self.chestBack(), equipment: Self.equipment, variationSeed: seed)
            let themed = RuleBasedWeeklyPlanGenerator.generate(request: Self.chestBack(theme), equipment: Self.equipment, variationSeed: seed)
            for day in [0, 2] {
                // Fit of the session's best `themedSlots` picks: balanced has no
                // cap, so it may stack a 4th fit the themed session gives up
                // for diversity by design.
                func fit(_ plan: WeeklyTrainingPlanCandidate) -> Int {
                    plan.sessions[day].exercises.compactMap { Self.byId[$0.machineId] }.map(theme.score)
                        .sorted(by: >).prefix(RuleBasedWeeklyPlanGenerator.themedSlots(4)).reduce(0, +)
                }
                #expect(fit(themed) >= fit(balanced), "theme \(theme) seed \(seed) day \(day + 1)")
                totals[day]!.themed += fit(themed)
                totals[day]!.balanced += fit(balanced)
                let picks = themed.sessions[day].exercises.compactMap { Self.byId[$0.machineId] }
                #expect(picks.count == 4)
                #expect(picks.filter { theme.score($0) > 0 }.count <= RuleBasedWeeklyPlanGenerator.themedSlots(4))
            }
        }
        for (day, total) in totals {
            #expect(total.themed > total.balanced, "theme \(theme) day \(day + 1)")
        }
    }

    /// Regression (UI QA, 胸重視 Day 3): with the three themed slots filled,
    /// an unused themed item (smith machine) must not take the diversity
    /// slot from a non-themed item already used on Day 1 (seated row).
    @Test
    func diversitySlotPrefersReusedNonThemedOverUnusedThemed() {
        let ids = ["pec_deck", "chest_press", "incline_chest_press", "bench_press", "smith_machine", "seated_row",
                   "leg_press", "leg_extension", "leg_curl", "hack_squat", "calf_raise", "hip_abduction"]
        let gym = AvailableEquipment.standardCatalog(ids.compactMap(MachineCatalog.entry(for:)))
        for seed: UInt64 in 0..<6 {
            let plan = RuleBasedWeeklyPlanGenerator.generate(request: Self.chestBack(.chestFocus), equipment: gym, variationSeed: seed)
            for day in [0, 2] {
                let picks = plan.sessions[day].exercises.map(\.machineId)
                #expect(picks.count == 4, "seed \(seed) day \(day + 1)")
                #expect(picks.contains("seated_row"), "seed \(seed) day \(day + 1): \(picks)")
            }
            // Day 3 really is the case under test: seated_row was used on Day 1.
            #expect(plan.sessions[0].exercises.contains { $0.machineId == "seated_row" })
        }
    }

    /// With no non-themed candidate at all, themed items fill the session
    /// rather than leaving it short.
    @Test
    func allThemedPoolStillFillsTheSession() {
        let ids = ["pec_deck", "chest_press", "incline_chest_press", "bench_press", "smith_machine",
                   "leg_press", "leg_extension", "leg_curl", "hack_squat"]
        let gym = AvailableEquipment.standardCatalog(ids.compactMap(MachineCatalog.entry(for:)))
        let request = TrainingPlanGenerationRequest(
            goal: .hypertrophy, daysPerWeek: 4, targetBodyParts: [.chest],
            experienceLevel: .intermediate, preferredSplit: .upperLower, sessionTheme: .chestFocus
        )
        let plan = RuleBasedWeeklyPlanGenerator.generate(request: request, equipment: gym)
        for day in [0, 2] {
            #expect(plan.sessions[day].exercises.count == 4)
            #expect(plan.sessions[day].exercises.allSatisfy { ["pec_deck", "chest_press", "incline_chest_press", "bench_press", "smith_machine"].contains($0.machineId) })
        }
    }

    /// Every upper-day pool here also holds equipment outside these themes
    /// (chest vs back machines, push vs pull), so the theme must leave room.
    @Test(arguments: [SessionTheme.chestFocus, .backFocus, .push, .pull, .press])
    func themeIsAPriorityNotAFilter(theme: SessionTheme) {
        #expect(RuleBasedWeeklyPlanGenerator.themedSlots(4) == 3)
        for seed: UInt64 in 0..<6 {
            let plan = RuleBasedWeeklyPlanGenerator.generate(request: Self.chestBack(theme), equipment: Self.equipment, variationSeed: seed)
            for upper in [plan.sessions[0], plan.sessions[2]] {
                let picks = upper.exercises.compactMap { Self.byId[$0.machineId] }
                #expect(picks.count == 4)
                #expect(picks.contains { theme.score($0) == 0 })
            }
        }
    }

    @Test
    func pressPrefersMultiJointPushOverIsolation() {
        let entries = ["chest_press", "pec_deck", "shoulder_press", "lateral_raise_machine", "triceps_extension_machine"]
            .compactMap(MachineCatalog.entry(for:))
        let items = AvailableEquipment.standardCatalog(entries)
        let score = Dictionary(uniqueKeysWithValues: items.map { ($0.id, SessionTheme.press.score($0)) })
        #expect(score["chest_press"]! > score["pec_deck"]!)
        #expect(score["shoulder_press"]! > score["lateral_raise_machine"]!)
        #expect(score["shoulder_press"]! > score["triceps_extension_machine"]!)
    }

    // MARK: Safety constraints win over the theme

    @Test(arguments: SessionTheme.allCases)
    func themesNeverPickUnavailableEquipment(theme: SessionTheme) {
        let unavailable = Set(["bench_press", "chest_press", "lat_pulldown", "leg_press"])
        let gym = MachineCatalog.all.map { AvailableEquipment(entry: $0, isAvailable: !unavailable.contains($0.id)) }
        for seed: UInt64 in 0..<6 {
            let plan = RuleBasedWeeklyPlanGenerator.generate(request: Self.wholeBody(theme), equipment: gym, variationSeed: seed)
            #expect(plan.sessions.flatMap(\.exercises).allSatisfy { !unavailable.contains($0.machineId) })
        }
    }

    @Test(arguments: SessionTheme.allCases)
    func themesKeepBeginnerFriendlyOnly(theme: SessionTheme) {
        var request = Self.wholeBody(theme)
        request.beginnerFriendlyOnly = true
        for seed: UInt64 in 0..<6 {
            let plan = RuleBasedWeeklyPlanGenerator.generate(request: request, equipment: Self.equipment, variationSeed: seed)
            #expect(!plan.isEmpty)
            #expect(Self.chosen(plan).allSatisfy { $0.catalogEntry?.beginnerFriendly == true })
        }
    }

    @Test(arguments: SessionTheme.allCases)
    func themesKeepLimitedBodyPartsOut(theme: SessionTheme) {
        var request = Self.wholeBody(theme)
        request.limitedBodyParts = [.legs]
        for seed: UInt64 in 0..<6 {
            let plan = RuleBasedWeeklyPlanGenerator.generate(request: request, equipment: Self.equipment, variationSeed: seed)
            #expect(plan.sessions.allSatisfy { !$0.focusBodyParts.contains(.legs) })
            for session in plan.sessions {
                let focus = Set(session.focusBodyParts)
                #expect(session.exercises.allSatisfy { ex in
                    Self.byId[ex.machineId].map { !$0.bodyParts.isDisjoint(with: focus) } ?? false
                })
            }
        }
    }

    @Test(arguments: SessionTheme.allCases)
    func emptyEquipmentDoesNotCrash(theme: SessionTheme) {
        let plan = RuleBasedWeeklyPlanGenerator.generate(request: Self.wholeBody(theme), equipment: [])
        #expect(plan.isEmpty)
        #expect(plan.sessions.count == 4)
    }

    @Test(arguments: SessionTheme.allCases)
    func smallGymNeverEmptiesASession(theme: SessionTheme) {
        let gym = AvailableEquipment.standardCatalog(["chest_press", "leg_press"].compactMap(MachineCatalog.entry(for:)))
        let plan = RuleBasedWeeklyPlanGenerator.generate(request: Self.wholeBody(theme), equipment: gym)
        let balanced = RuleBasedWeeklyPlanGenerator.generate(request: Self.wholeBody(.balanced), equipment: gym)
        #expect(plan.sessions.allSatisfy { !$0.exercises.isEmpty })
        #expect(zip(plan.sessions, balanced.sessions).allSatisfy { $0.exercises.count == $1.exercises.count })
    }
}

// MARK: - Exercise locks + one-day regeneration

struct WeeklyPlanExerciseLockTests {

    private static let equipment = AvailableEquipment.standardCatalog()
    private static let byId = Dictionary(uniqueKeysWithValues: equipment.map { ($0.id, $0) })

    private static func request(_ theme: SessionTheme = .chestFocus) -> TrainingPlanGenerationRequest {
        TrainingPlanGenerationRequest(
            goal: .hypertrophy, daysPerWeek: 4, targetBodyParts: [.chest, .back],
            experienceLevel: .intermediate, preferredSplit: .upperLower, sessionTheme: theme
        )
    }

    private static func plan(_ theme: SessionTheme = .chestFocus) -> WeeklyTrainingPlanCandidate {
        RuleBasedWeeklyPlanGenerator.generate(request: request(theme), equipment: equipment)
    }

    private static func regen(
        _ current: WeeklyTrainingPlanCandidate, day: Int = 0, locks: Set<String>, seed: UInt64,
        request: TrainingPlanGenerationRequest = request(), equipment: [AvailableEquipment] = equipment
    ) -> WeeklyTrainingPlanCandidate? {
        RuleBasedWeeklyPlanGenerator.regenerateSession(
            request: request, equipment: equipment, current: current,
            sessionIndex: day, lockedMachineIds: locks, seed: seed
        )
    }

    @Test
    func lockedExerciseSurvivesUnchangedInPlace() throws {
        let current = Self.plan()
        let kept = current.sessions[0].exercises[1]
        for seed: UInt64 in 1...8 {
            let next = try #require(Self.regen(current, locks: [kept.machineId], seed: seed))
            #expect(next.sessions[0].exercises[1] == kept)
        }
    }

    @Test
    func multipleLocksAllSurviveInPlace() throws {
        let current = Self.plan()
        let day = current.sessions[0].exercises
        let locks: Set<String> = [day[0].machineId, day[3].machineId]
        for seed: UInt64 in 1...8 {
            let next = try #require(Self.regen(current, locks: locks, seed: seed)).sessions[0].exercises
            #expect(next[0] == day[0])
            #expect(next[3] == day[3])
            #expect(next.count == day.count)
        }
    }

    @Test
    func anUnlockedSlotChangesWhenAlternativesExist() throws {
        let current = Self.plan()
        let day = current.sessions[0].exercises
        let next = try #require(RuleBasedWeeklyPlanGenerator.nextDistinctSessionVariation(
            request: Self.request(), equipment: Self.equipment, current: current,
            sessionIndex: 0, lockedMachineIds: [day[0].machineId], currentSeed: 0
        )).candidate.sessions[0].exercises
        #expect(next[0] == day[0])
        #expect(zip(next.dropFirst(), day.dropFirst()).contains { $0 != $1 })
    }

    @Test(arguments: [0, 1, 2, 3])
    func onlyTheTargetDayChanges(day: Int) throws {
        let current = Self.plan()
        let next = try #require(RuleBasedWeeklyPlanGenerator.nextDistinctSessionVariation(
            request: Self.request(), equipment: Self.equipment, current: current,
            sessionIndex: day, lockedMachineIds: [], currentSeed: 0
        )).candidate
        for other in current.sessions.indices where other != day {
            #expect(next.sessions[other] == current.sessions[other])
        }
        #expect(next.sessions[day] != current.sessions[day])
        #expect(next.sessionTheme == current.sessionTheme)
        #expect(next.title == current.title && next.rationale == current.rationale)
    }

    @Test
    func allLockedCannotRegenerate() {
        let current = Self.plan()
        let all = Set(current.sessions[0].exercises.map(\.machineId))
        #expect(Self.regen(current, locks: all, seed: 1) == nil)
        #expect(RuleBasedWeeklyPlanGenerator.nextDistinctSessionVariation(
            request: Self.request(), equipment: Self.equipment, current: current,
            sessionIndex: 0, lockedMachineIds: all, currentSeed: 0
        ) == nil)
    }

    @Test
    func zeroLocksReplacesTheWholeDay() throws {
        let current = Self.plan()
        let next = try #require(RuleBasedWeeklyPlanGenerator.nextDistinctSessionVariation(
            request: Self.request(), equipment: Self.equipment, current: current,
            sessionIndex: 0, lockedMachineIds: [], currentSeed: 0
        )).candidate
        #expect(next.sessions[0].exercises.count == current.sessions[0].exercises.count)
        #expect(next.sessions[0] != current.sessions[0])
    }

    @Test
    func noDuplicateMachineWithinADay() throws {
        for theme in SessionTheme.allCases {
            let current = Self.plan(theme)
            let locks: Set<String> = [current.sessions[0].exercises[0].machineId]
            for seed: UInt64 in 1...10 {
                let ids = try #require(Self.regen(current, locks: locks, seed: seed, request: Self.request(theme)))
                    .sessions[0].exercises.map(\.machineId)
                #expect(Set(ids).count == ids.count, "\(theme) seed \(seed): \(ids)")
            }
        }
    }

    @Test
    func sameInputsAndSeedAreDeterministic() {
        let current = Self.plan()
        let locks: Set<String> = [current.sessions[0].exercises[0].machineId]
        for seed: UInt64 in 1...6 {
            #expect(Self.regen(current, locks: locks, seed: seed) == Self.regen(current, locks: locks, seed: seed))
        }
    }

    @Test
    func differentSeedsYieldAlternatives() {
        let current = Self.plan()
        let locks: Set<String> = [current.sessions[0].exercises[0].machineId]
        let days = Set((1...12).compactMap { Self.regen(current, locks: locks, seed: $0)?.sessions[0].exercises.map(\.machineId) })
        #expect(days.count >= 2)
    }

    @Test(arguments: SessionTheme.allCases)
    func constraintsHoldOnPartialRegeneration(theme: SessionTheme) throws {
        let unavailable: Set<String> = ["bench_press", "lat_pulldown"]
        let gym = MachineCatalog.all.map { AvailableEquipment(entry: $0, isAvailable: !unavailable.contains($0.id)) }
        var request = Self.request(theme)
        request.beginnerFriendlyOnly = true
        request.limitedBodyParts = [.shoulders]
        let current = RuleBasedWeeklyPlanGenerator.generate(request: request, equipment: gym)
        let byId = Dictionary(uniqueKeysWithValues: gym.map { ($0.id, $0) })
        for day in current.sessions.indices where !current.sessions[day].exercises.isEmpty {
            let locks: Set<String> = [current.sessions[day].exercises[0].machineId]
            for seed: UInt64 in 1...6 {
                let next = try #require(Self.regen(current, day: day, locks: locks, seed: seed, request: request, equipment: gym))
                for ex in next.sessions[day].exercises {
                    #expect(!unavailable.contains(ex.machineId))
                    #expect(byId[ex.machineId]?.catalogEntry?.beginnerFriendly == true)
                }
            }
        }
    }

    /// Theme fit of the day's best `themedSlots` picks, as in the theme tests.
    private static func fit(_ day: TrainingSessionCandidate, _ theme: SessionTheme) -> Int {
        day.exercises.compactMap { byId[$0.machineId] }.map(theme.score)
            .sorted(by: >).prefix(RuleBasedWeeklyPlanGenerator.themedSlots(4)).reduce(0, +)
    }

    @Test(arguments: [SessionTheme.chestFocus, .backFocus, .push, .pull])
    func themeHoldsAfterPartialRegeneration(theme: SessionTheme) throws {
        let themed = Self.plan(theme)
        let balanced = Self.plan(.balanced)
        for day in [0, 2] {
            var themedTotal = 0, balancedTotal = 0
            for seed: UInt64 in 1...6 {
                let t = try #require(Self.regen(themed, day: day, locks: [], seed: seed, request: Self.request(theme)))
                let b = try #require(Self.regen(balanced, day: day, locks: [], seed: seed, request: Self.request(.balanced)))
                #expect(Self.fit(t.sessions[day], theme) >= Self.fit(b.sessions[day], theme), "\(theme) day \(day + 1) seed \(seed)")
                themedTotal += Self.fit(t.sessions[day], theme)
                balancedTotal += Self.fit(b.sessions[day], theme)
                let picks = t.sessions[day].exercises.compactMap { Self.byId[$0.machineId] }
                #expect(picks.contains { theme.score($0) == 0 }, "diversity slot kept")
            }
            // Balanced can already sit at the ceiling (e.g. a back-heavy
            // Day 3), so the strict check is "never weaker", plus: the themed
            // day reaches the best top-3 fit its focus pool allows.
            #expect(themedTotal >= balancedTotal, "\(theme) day \(day + 1)")
            // Ceiling from the eligible pool (same filter the generator uses:
            // available + day focus), independent of any generated result.
            let query = MachineCatalogQuery(bodyParts: themed.sessions[day].focusBodyParts, beginnerFriendlyOnly: false)
            let ceiling = Self.equipment.filter { $0.isAvailable && $0.matches(query) }.map(theme.score)
                .sorted(by: >).prefix(RuleBasedWeeklyPlanGenerator.themedSlots(4)).reduce(0, +)
            #expect(themedTotal == ceiling * 6, "\(theme) day \(day + 1) reaches the ceiling")
        }
    }

    @Test
    func thinGymKeepsLocksAndFillsWhatItCan() throws {
        let ids = ["bench_press", "chest_press", "lat_pulldown", "leg_press"]
        let gym = AvailableEquipment.standardCatalog(ids.compactMap(MachineCatalog.entry(for:)))
        let current = RuleBasedWeeklyPlanGenerator.generate(request: Self.request(), equipment: gym)
        let day = current.sessions[0].exercises
        let locks: Set<String> = [day[0].machineId]
        let next = try #require(Self.regen(current, locks: locks, seed: 3, equipment: gym)).sessions[0].exercises
        #expect(next[0] == day[0])
        #expect(!next.isEmpty)
        #expect(Set(next.map(\.machineId)).count == next.count)
    }

    /// Chest day, thin gym: locked bench + one other chest machine only.
    /// The open slots must keep the valid original chest pick rather than
    /// widening to the leg machines that are also in the gym.
    @Test
    func validOriginalBeatsOffTargetFallback() throws {
        let ids = ["bench_press", "chest_press", "pec_deck", "lat_pulldown", "leg_press", "leg_extension", "leg_curl"]
        let gym = AvailableEquipment.standardCatalog(ids.compactMap(MachineCatalog.entry(for:)))
        let request = TrainingPlanGenerationRequest(
            goal: .hypertrophy, daysPerWeek: 4, targetBodyParts: [.chest],
            experienceLevel: .intermediate, preferredSplit: .bodyPart, sessionTheme: .chestFocus
        )
        let current = RuleBasedWeeklyPlanGenerator.generate(request: request, equipment: gym)
        let day = current.sessions[0]
        let lock = try #require(day.exercises.first { $0.machineId == "bench_press" })
        let focusIds = Set(gym.filter { $0.matches(MachineCatalogQuery(bodyParts: day.focusBodyParts, beginnerFriendlyOnly: false)) }.map(\.id))
        for seed: UInt64 in 1...8 {
            let next = try #require(Self.regen(current, locks: [lock.machineId], seed: seed, request: request, equipment: gym)).sessions[0].exercises
            #expect(next.contains(lock))
            #expect(next.allSatisfy { focusIds.contains($0.machineId) }, "seed \(seed): \(next.map(\.machineId))")
            #expect(!next.contains { ["leg_press", "leg_extension", "leg_curl"].contains($0.machineId) })
            #expect(Set(next.map(\.machineId)).count == next.count)
        }
    }

    @Test(arguments: SessionTheme.allCases)
    func notEnoughValidEquipmentStaysInBounds(theme: SessionTheme) throws {
        let unavailable: Set<String> = ["chest_press", "incline_chest_press", "pec_deck", "smith_machine", "barbell", "dumbbells", "cable_machine"]
        let gym = MachineCatalog.all.map { AvailableEquipment(entry: $0, isAvailable: !unavailable.contains($0.id)) }
        var request = Self.request(theme)
        request.targetBodyParts = [.chest]
        request.limitedBodyParts = [.legs]
        request.beginnerFriendlyOnly = true
        let current = RuleBasedWeeklyPlanGenerator.generate(request: request, equipment: gym)
        let byId = Dictionary(uniqueKeysWithValues: gym.map { ($0.id, $0) })
        for dayIndex in current.sessions.indices where !current.sessions[dayIndex].exercises.isEmpty {
            let day = current.sessions[dayIndex]
            let locks: Set<String> = [day.exercises[0].machineId]
            let before = Set(day.exercises.map(\.machineId))
            for seed: UInt64 in 1...4 {
                guard let next = Self.regen(current, day: dayIndex, locks: locks, seed: seed, request: request, equipment: gym) else { continue }
                let picks = next.sessions[dayIndex].exercises
                #expect(picks.first == day.exercises[0])
                #expect(picks.allSatisfy { !unavailable.contains($0.machineId) })
                // New picks stay inside the day's filters (focus already
                // excludes the limited legs); anything else must be an
                // original that was already on this day.
                let query = MachineCatalogQuery(bodyParts: day.focusBodyParts, beginnerFriendlyOnly: true)
                for ex in picks where !before.contains(ex.machineId) {
                    #expect(byId[ex.machineId].map { $0.matches(query) } == true, "\(ex.machineId)")
                }
            }
        }
    }

    /// A chest day whose candidate holds an off-target leg machine (as the
    /// first generation's whole-body fallback can produce), on a gym too
    /// thin to refill the chest slots.
    private static func chestDayWithLegLeftover() -> (WeeklyTrainingPlanCandidate, [AvailableEquipment], TrainingPlanGenerationRequest) {
        let ids = ["bench_press", "chest_press", "leg_press", "leg_extension", "leg_curl", "lat_pulldown"]
        let gym = AvailableEquipment.standardCatalog(ids.compactMap(MachineCatalog.entry(for:)))
        let byId = Dictionary(uniqueKeysWithValues: gym.map { ($0.id, $0) })
        let request = TrainingPlanGenerationRequest(
            goal: .hypertrophy, daysPerWeek: 2, targetBodyParts: [.chest],
            experienceLevel: .intermediate, preferredSplit: .bodyPart, sessionTheme: .chestFocus
        )
        let base = RuleBasedWeeklyPlanGenerator.generate(request: request, equipment: gym)
        let day = base.sessions[0]
        let exercises = ["bench_press", "leg_press", "chest_press"].map { RoutineStepCandidate(equipment: byId[$0]!) }
        var sessions = base.sessions
        sessions[0] = TrainingSessionCandidate(title: day.title, focusBodyParts: day.focusBodyParts, exercises: exercises, notes: day.notes)
        let plan = WeeklyTrainingPlanCandidate(
            title: base.title, goal: base.goal, daysPerWeek: base.daysPerWeek, sessions: sessions,
            rationale: base.rationale, warnings: base.warnings, hasAlternatives: base.hasAlternatives, sessionTheme: base.sessionTheme
        )
        return (plan, gym, request)
    }

    @Test
    func unlockedOffTargetOriginalIsDroppedNotKept() throws {
        let (plan, gym, request) = Self.chestDayWithLegLeftover()
        #expect(plan.sessions[0].focusBodyParts == [.chest])
        let legs: Set<String> = ["leg_press", "leg_extension", "leg_curl"]
        for seed: UInt64 in 1...6 {
            let next = try #require(Self.regen(plan, locks: ["bench_press"], seed: seed, request: request, equipment: gym)).sessions[0].exercises
            #expect(next.first == plan.sessions[0].exercises[0], "locked bench stays first")
            #expect(!next.contains { legs.contains($0.machineId) }, "seed \(seed): \(next.map(\.machineId))")
            #expect(next.allSatisfy { ["bench_press", "chest_press"].contains($0.machineId) })
            #expect(next.count < 4, "only two chest machines exist; the day may be short")
        }
    }

    @Test
    func lockedOffTargetOriginalIsKept() throws {
        let (plan, gym, request) = Self.chestDayWithLegLeftover()
        for seed: UInt64 in 1...6 {
            let next = try #require(Self.regen(plan, locks: ["leg_press"], seed: seed, request: request, equipment: gym)).sessions[0].exercises
            #expect(next[1] == plan.sessions[0].exercises[1], "locked leg_press stays in place")
            #expect(next.filter { $0.machineId != "leg_press" }.allSatisfy { ["bench_press", "chest_press"].contains($0.machineId) })
        }
    }
}


// MARK: - Weekly volume analysis

@MainActor
struct WeeklyTrainingVolumeAnalyzerTests {

    private static func ex(
        _ id: String, _ parts: [BodyPart], sets: Int?, resolved: Bool = true
    ) -> RoutineStepCandidate {
        RoutineStepCandidate(
            machineId: id, exerciseName: id, bodyParts: parts,
            template: MachineExerciseTemplate(sets: sets, reps: 8...12, restSeconds: 90),
            notes: nil, sourceLabel: "test",
            exerciseId: resolved ? ExerciseID(rawValue: id) : nil
        )
    }

    private static func plan(_ days: [[RoutineStepCandidate]]) -> WeeklyTrainingPlanCandidate {
        WeeklyTrainingPlanCandidate(
            title: "t", goal: .hypertrophy, daysPerWeek: days.count,
            sessions: days.enumerated().map { i, exercises in
                TrainingSessionCandidate(title: "Day \(i + 1)", focusBodyParts: [.chest], exercises: exercises, notes: "")
            },
            rationale: "", warnings: []
        )
    }

    @Test
    func totalsMatchResolvedSetsAndExerciseCount() {
        let candidate = RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(
                goal: .hypertrophy, daysPerWeek: 4, targetBodyParts: [.chest, .back],
                experienceLevel: .intermediate, preferredSplit: .upperLower, sessionTheme: .chestFocus
            ),
            equipment: AvailableEquipment.standardCatalog()
        )
        let all = candidate.sessions.flatMap(\.exercises)
        let summary = WeeklyTrainingVolumeAnalyzer.analyze(candidate)
        #expect(!all.isEmpty)
        #expect(summary.totalSets == all.reduce(0) { $0 + $1.resolvedSets })
        #expect(summary.exerciseCount == all.count)
        #expect(summary.activeDayCount == candidate.savableSessions.count)
        #expect(summary.primarySetsByBodyPart.values.reduce(0, +) + summary.unclassifiedSets == summary.totalSets)
    }

    @Test
    func emptySessionIsNotAnActiveDay() {
        let summary = WeeklyTrainingVolumeAnalyzer.analyze(Self.plan([[Self.ex("a", [.chest], sets: 3)], []]))
        #expect(summary.activeDayCount == 1)
        #expect(summary.days.count == 2)
        #expect(summary.days[1].totalSets == 0)
    }

    @Test
    func resolvedExerciseCountsOnlyItsPrimaryPart() {
        let summary = WeeklyTrainingVolumeAnalyzer.analyze(Self.plan([[Self.ex("bench", [.chest, .arms, .shoulders], sets: 3)]]))
        #expect(summary.sets(for: .chest) == 3)
        #expect(summary.sets(for: .arms) == 0)
        #expect(summary.sets(for: .shoulders) == 0)
        #expect(summary.unclassifiedSets == 0)
    }

    @Test
    func unresolvedSinglePartCountsTowardThatPart() {
        let summary = WeeklyTrainingVolumeAnalyzer.analyze(Self.plan([[Self.ex("custom", [.back], sets: 4, resolved: false)]]))
        #expect(summary.sets(for: .back) == 4)
        #expect(summary.unclassifiedSets == 0)
    }

    @Test
    func unresolvedMultiPartIsUnclassified() {
        let summary = WeeklyTrainingVolumeAnalyzer.analyze(Self.plan([[Self.ex("custom", [.chest, .back], sets: 4, resolved: false)]]))
        #expect(summary.sets(for: .chest) == 0)
        #expect(summary.sets(for: .back) == 0)
        #expect(summary.unclassifiedSets == 4)
        #expect(summary.totalSets == 4)
    }

    @Test
    func missingSetsUseTheSameFallbackAsSave() {
        let summary = WeeklyTrainingVolumeAnalyzer.analyze(Self.plan([[Self.ex("a", [.legs], sets: nil)]]))
        #expect(summary.sets(for: .legs) == RoutineStepCandidate.fallbackSets)
    }

    @Test
    func dayTotalsAndPerDayBreakdown() {
        let summary = WeeklyTrainingVolumeAnalyzer.analyze(Self.plan([
            [Self.ex("a", [.chest], sets: 3), Self.ex("b", [.back, .arms], sets: 4)],
            [Self.ex("c", [.chest], sets: 2)],
        ]))
        #expect(summary.days.map(\.totalSets) == [7, 2])
        #expect(summary.days.map(\.exerciseCount) == [2, 1])
        #expect(summary.days[0].primarySetsByBodyPart == [.chest: 3, .back: 4])
        #expect(summary.days[1].primarySetsByBodyPart == [.chest: 2])
        #expect(summary.sets(for: .chest) == 5)
    }

    @Test
    func reflectsPartialRegeneration() throws {
        let request = TrainingPlanGenerationRequest(
            goal: .hypertrophy, daysPerWeek: 4, targetBodyParts: [.chest, .back],
            experienceLevel: .intermediate, preferredSplit: .upperLower, sessionTheme: .chestFocus
        )
        let equipment = AvailableEquipment.standardCatalog()
        let before = RuleBasedWeeklyPlanGenerator.generate(request: request, equipment: equipment)
        let after = try #require(RuleBasedWeeklyPlanGenerator.regenerateSession(
            request: request, equipment: equipment, current: before,
            sessionIndex: 0, lockedMachineIds: [before.sessions[0].exercises[0].machineId], seed: 7
        ))
        let summary = WeeklyTrainingVolumeAnalyzer.analyze(after)
        let day0 = after.sessions[0].exercises
        #expect(summary.days[0].totalSets == day0.reduce(0) { $0 + $1.resolvedSets })
        #expect(summary.days[0].exerciseCount == day0.count)
        #expect(summary == WeeklyTrainingVolumeAnalyzer.analyze(after))
        #expect(summary.exerciseCount == after.sessions.flatMap(\.exercises).count)
        #expect(Array(summary.days.dropFirst()) == Array(WeeklyTrainingVolumeAnalyzer.analyze(before).days.dropFirst()))
    }

    @Test
    func compactFocusLabels() {
        let label = WeeklyTrainingVolumeAnalyzer.compactFocusLabel
        #expect(label([.chest, .back, .shoulders, .arms]) == "上半身")
        #expect(label([.legs, .core]) == "下半身")
        #expect(label([.back, .chest]) == "胸・背中")
        #expect(label([.chest]) == "胸")
        #expect(label([.chest, .back, .legs, .shoulders, .arms, .core]) == "全身")
        #expect(label([.fullBody]) == "全身")
        #expect(label([]) == "全身")
        #expect(label([.chest, .back, .shoulders]) == "胸・背中・肩")
        #expect(label([.chest, .back, .shoulders, .arms, .legs]) == "上半身・脚")
        #expect(label([.legs, .core, .chest]) == "下半身・胸")
        #expect(label([.legs, .core, .chest, .back, .shoulders]) == "下半身・胸 ほか2部位")
    }

    @Test
    func dayLabelsFollowFocusNotSessionTitle() {
        let equipment = AvailableEquipment.standardCatalog()
        let chestBack = WeeklyTrainingVolumeAnalyzer.analyze(RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(
                goal: .hypertrophy, daysPerWeek: 4, targetBodyParts: [.chest, .back],
                experienceLevel: .intermediate, preferredSplit: .upperLower, sessionTheme: .chestFocus
            ), equipment: equipment
        ))
        // Day 2 / 4 are titled 下半身 here but their focus is chest + back.
        #expect(chestBack.days.map(\.focusLabel) == ["胸・背中", "胸・背中", "胸・背中", "胸・背中"])
        let everything = WeeklyTrainingVolumeAnalyzer.analyze(RuleBasedWeeklyPlanGenerator.generate(
            request: TrainingPlanGenerationRequest(
                goal: .hypertrophy, daysPerWeek: 4,
                targetBodyParts: [.chest, .back, .shoulders, .arms, .legs, .core],
                experienceLevel: .intermediate, preferredSplit: .upperLower
            ), equipment: equipment
        ))
        #expect(everything.days.map(\.focusLabel) == ["上半身", "下半身", "上半身", "下半身"])
    }

    /// Every exercise lands in exactly one bucket: one body part or
    /// unclassified — never several, never none.
    @Test
    func everySetIsCountedInExactlyOneBucket() {
        let mixed = Self.plan([
            [Self.ex("bench", [.chest, .arms, .shoulders], sets: 3),
             Self.ex("custom1", [.back], sets: 4, resolved: false),
             Self.ex("custom2", [.chest, .back], sets: 5, resolved: false),
             Self.ex("nil", [.legs, .core], sets: nil)],
            [],
            [Self.ex("row", [.back, .arms], sets: 2)],
        ])
        var cases = [mixed]
        for theme in SessionTheme.allCases {
            cases.append(RuleBasedWeeklyPlanGenerator.generate(
                request: TrainingPlanGenerationRequest(
                    goal: .hypertrophy, daysPerWeek: 4, targetBodyParts: [.chest, .back, .legs],
                    experienceLevel: .intermediate, preferredSplit: .upperLower, sessionTheme: theme
                ), equipment: AvailableEquipment.standardCatalog()
            ))
        }
        for candidate in cases {
            let s = WeeklyTrainingVolumeAnalyzer.analyze(candidate)
            #expect(s.totalSets == s.primarySetsByBodyPart.values.reduce(0, +) + s.unclassifiedSets)
        }
        let s = WeeklyTrainingVolumeAnalyzer.analyze(mixed)
        #expect(s.totalSets == 3 + 4 + 5 + RoutineStepCandidate.fallbackSets + 2)
        #expect(s.unclassifiedSets == 5)
    }

    @Test
    func emptyCandidateIsAllZero() {
        let summary = WeeklyTrainingVolumeAnalyzer.analyze(Self.plan([]))
        #expect(summary.totalSets == 0)
        #expect(summary.exerciseCount == 0)
        #expect(summary.activeDayCount == 0)
        #expect(summary.days.isEmpty)
        #expect(summary.unclassifiedSets == 0)
    }
}
