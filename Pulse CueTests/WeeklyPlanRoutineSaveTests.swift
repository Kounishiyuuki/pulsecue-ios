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

    // MARK: - Save state (pure; duplicate-save prevention & completion copy)

    @Test
    func idleStateAllowsSaving() {
        #expect(WeeklyPlanSaveState.idle.canSave)
    }

    @Test
    func savedStateBlocksAdditionalSaves() {
        // Once saved, the same candidate cannot be saved again — this is
        // how the UI prevents accidental duplicate saves.
        #expect(!WeeklyPlanSaveState.saved(routineCount: 3).canSave)
    }

    @Test
    func savedStateCarriesRoutineCount() {
        #expect(WeeklyPlanSaveState.saved(routineCount: 5) == .saved(routineCount: 5))
        #expect(WeeklyPlanSaveState.saved(routineCount: 5) != .saved(routineCount: 2))
    }

    @Test
    func savedSummaryIncludesRoutineCount() {
        let summary = WeeklyPlanSaveState.savedSummary(routineCount: 4)
        #expect(summary.contains("4"))
        #expect(!summary.isEmpty)
    }
}

// MARK: - Saved weekly plans (V11)

@MainActor
struct SavedTrainingPlanTests {

    private static func makeContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: PulseCueSchemaV17.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    private static let request = TrainingPlanGenerationRequest(
        goal: .hypertrophy, daysPerWeek: 4, targetBodyParts: [.chest, .back],
        experienceLevel: .intermediate, preferredSplit: .upperLower
    )
    private static let equipment = AvailableEquipment.standardCatalog(
        ["bench_press", "chest_press", "pec_deck", "incline_chest_press", "cable_machine",
         "smith_machine", "dumbbells", "lat_pulldown", "seated_row"].compactMap { MachineCatalog.entry(for: $0) }
    )
    private static func candidate(seed: UInt64 = 0) -> WeeklyTrainingPlanCandidate {
        RuleBasedWeeklyPlanGenerator.generate(request: request, equipment: equipment, variationSeed: seed)
    }

    private static func counts(_ c: ModelContext) throws -> (plans: Int, routines: Int, steps: Int) {
        (try c.fetchCount(FetchDescriptor<SavedTrainingPlan>()),
         try c.fetchCount(FetchDescriptor<Routine>()),
         try c.fetchCount(FetchDescriptor<Step>()))
    }

    // MARK: Save

    @Test
    func savingFourDayPlanCreatesOnePlanAndFourLinkedOrderedRoutines() throws {
        let context = try Self.makeContext()
        let plan = Self.candidate()
        let saved = try #require(try SavedTrainingPlanStore.save(plan, split: .upperLower, name: "筋肥大メイン", in: context))
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<SavedTrainingPlan>()) == 1)
        let routines = try context.fetch(FetchDescriptor<Routine>())
        #expect(routines.count == 4)
        #expect(routines.allSatisfy { $0.savedTrainingPlanId == saved.plan.id })
        let ordered = SavedTrainingPlanStore.routines(of: saved.plan, in: routines)
        #expect(ordered.map(\.planDayIndex) == [0, 1, 2, 3])
        #expect(ordered.map(\.name) == ["Day 1 · 上半身", "Day 2 · 下半身", "Day 3 · 上半身", "Day 4 · 下半身"])
        // Steps saved exactly as before: one per exercise, linked by routineId.
        let steps = try context.fetch(FetchDescriptor<Step>())
        #expect(steps.count == plan.sessions.reduce(0) { $0 + $1.exercises.count })
        for (routine, session) in zip(ordered, plan.sessions) {
            #expect(steps.filter { $0.routineId == routine.id }.count == session.exercises.count)
        }
        #expect(saved.plan.goalRaw == TrainingGoal.hypertrophy.rawValue)
        #expect(saved.plan.splitRaw == TrainingSplit.upperLower.rawValue)
        #expect(saved.plan.daysPerWeek == 4)
    }

    // MARK: Explicit save boundary

    private struct InjectedSaveFailure: Error {}

    @Test
    func successfulSaveIsVisibleFromAFreshContextAndAfterReopen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsecue-savedplan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("store.sqlite")
        let schema = Schema(versionedSchema: PulseCueSchemaV17.self)
        let expectedSteps = Self.candidate().sessions.reduce(0) { $0 + $1.exercises.count }

        do {
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            context.autosaveEnabled = false   // prove persistence comes from the explicit save
            _ = try #require(try SavedTrainingPlanStore.save(Self.candidate(), split: .upperLower, name: "筋肥大メイン", in: context))
            #expect(!context.hasChanges)
            let fresh = try Self.counts(ModelContext(container))
            #expect(fresh.plans == 1 && fresh.routines == 4 && fresh.steps == expectedSteps)
        }
        do {
            let container = try ModelContainer(
                for: schema, migrationPlan: PulseCueMigrationPlan.self,
                configurations: ModelConfiguration(schema: schema, url: url)
            )
            let context = ModelContext(container)
            let c = try Self.counts(context)
            #expect(c.plans == 1 && c.routines == 4 && c.steps == expectedSteps)
            #expect(try context.fetch(FetchDescriptor<SavedTrainingPlan>()).map(\.name) == ["筋肥大メイン"])
        }
    }

    @Test
    func failedSaveThrowsAndLeavesNothingForALaterSave() throws {
        let context = try Self.makeContext()
        context.autosaveEnabled = false
        // An unrelated pending change made before the failed save.
        let unrelated = Routine(name: "未保存の手作り")
        context.insert(unrelated)

        var threw = false
        do {
            _ = try SavedTrainingPlanStore.save(
                Self.candidate(), split: .upperLower, name: "失敗", in: context,
                commit: { _ in throw InjectedSaveFailure() }
            )
        } catch is InjectedSaveFailure {
            threw = true
        }
        #expect(threw)   // the caller never reaches its success state

        // A later save (what autosave would do) must not persist the plan.
        try context.save()
        let c = try Self.counts(context)
        #expect(c.plans == 0)
        #expect(c.steps == 0)
        // Only the unrelated routine survived — no rollback() wiped it.
        #expect(try context.fetch(FetchDescriptor<Routine>()).map(\.name) == ["未保存の手作り"])
    }

    @Test
    func failedSaveIsRecoverableByRetrying() throws {
        let context = try Self.makeContext()
        _ = try? SavedTrainingPlanStore.save(
            Self.candidate(), split: .upperLower, name: "P", in: context,
            commit: { _ in throw InjectedSaveFailure() }
        )
        _ = try #require(try SavedTrainingPlanStore.save(Self.candidate(), split: .upperLower, name: "P", in: context))
        let c = try Self.counts(context)
        #expect(c.plans == 1 && c.routines == 4)
    }

    // MARK: Non-save boundary

    @Test
    func generatingAndAlternativesPersistNothing() throws {
        let context = try Self.makeContext()
        var current = Self.candidate()
        var seed: UInt64 = 0
        for _ in 0..<3 {
            let next = try #require(RuleBasedWeeklyPlanGenerator.nextDistinctVariation(
                request: Self.request, equipment: Self.equipment, current: current, currentSeed: seed
            ))
            (seed, current) = (next.seed, next.candidate)
        }
        _ = SavedTrainingPlanStore.defaultName(for: current, split: .upperLower)
        let c = try Self.counts(context)
        #expect(c.plans == 0 && c.routines == 0 && c.steps == 0)
        #expect(!context.hasChanges)
    }

    @Test
    func emptyCandidateSavesNothing() throws {
        let context = try Self.makeContext()
        let empty = RuleBasedWeeklyPlanGenerator.generate(request: Self.request, equipment: [])
        #expect(try SavedTrainingPlanStore.save(empty, split: .upperLower, name: "x", in: context) == nil)
        let c = try Self.counts(context)
        #expect(c.plans == 0 && c.routines == 0)
    }

    // MARK: Name

    @Test
    func customNameIsStoredAndBlankFallsBackToDefault() throws {
        let context = try Self.makeContext()
        let custom = try #require(try SavedTrainingPlanStore.save(Self.candidate(), split: .upperLower, name: "  学校ある週 ", in: context))
        #expect(custom.plan.name == "学校ある週")
        let blank = try #require(try SavedTrainingPlanStore.save(Self.candidate(), split: .upperLower, name: " \n ", in: context))
        #expect(blank.plan.name == "筋肥大・上下分割・週4日")
    }

    @Test
    func renameChangesPlanNameAndUpdatedAtButNotDayNames() throws {
        let context = try Self.makeContext()
        let created = Date(timeIntervalSince1970: 1_000)
        let saved = try #require(try SavedTrainingPlanStore.save(Self.candidate(), split: .upperLower, name: "筋肥大メイン", in: context, now: created))
        let later = Date(timeIntervalSince1970: 2_000)
        try SavedTrainingPlanStore.rename(saved.plan, to: "夏までプラン", in: context, now: later)
        #expect(saved.plan.name == "夏までプラン")
        #expect(saved.plan.updatedAt == later)
        #expect(saved.plan.createdAt == created)
        #expect(saved.routines.first?.name == "Day 1 · 上半身")
        // Blank rename keeps the name and does not touch updatedAt.
        try SavedTrainingPlanStore.rename(saved.plan, to: "   ", in: context, now: Date(timeIntervalSince1970: 3_000))
        #expect(saved.plan.name == "夏までプラン")
        #expect(saved.plan.updatedAt == later)
    }

    // MARK: Compatibility

    @Test
    func unlinkedRoutinesKeepTheirExistingBehaviour() throws {
        let context = try Self.makeContext()
        let manual = Routine(name: "手作り")
        let generated = Routine(name: "Quick", origin: .workoutGenerated)
        context.insert(manual); context.insert(generated)
        try context.save()
        let all = try context.fetch(FetchDescriptor<Routine>())
        #expect(all.allSatisfy { $0.savedTrainingPlanId == nil && $0.planDayIndex == nil })
        #expect(RoutineLibrary.startable(from: all).map(\.name) == ["手作り"])
        let saved = try #require(try SavedTrainingPlanStore.save(Self.candidate(), split: .upperLower, name: "P", in: context))
        // A plan's day lookup never picks up unrelated routines.
        #expect(SavedTrainingPlanStore.routines(of: saved.plan, in: try context.fetch(FetchDescriptor<Routine>())).count == 4)
        // Plan days are ordinary user-saved routines (editor / library path).
        #expect(saved.routines.allSatisfy { $0.origin == .userSaved })
        saved.routines[0].name = "Day 1 · 胸の日"
        #expect(saved.plan.name == "P")
    }

    // MARK: Delete

    @Test
    func deletingPlanKeepsRoutinesStepsAndSessionsAndUnlinksThem() throws {
        let context = try Self.makeContext()
        let saved = try #require(try SavedTrainingPlanStore.save(Self.candidate(), split: .upperLower, name: "P", in: context))
        let other = try #require(try SavedTrainingPlanStore.save(Self.candidate(seed: 3), split: .upperLower, name: "Q", in: context))
        let session = Session(routineId: saved.routines[0].id, dayDate: Date(), status: .completed)
        context.insert(session)
        try context.save()
        let before = try Self.counts(context)

        try SavedTrainingPlanStore.deletePlanKeepingRoutines(saved.plan, in: context)

        // Read back from the store, as the app's @Query does after the merge.
        let store = ModelContext(context.container)
        let after = try Self.counts(store)
        #expect(after.plans == before.plans - 1)
        #expect(after.routines == before.routines)
        #expect(after.steps == before.steps)
        #expect(try store.fetchCount(FetchDescriptor<Session>()) == 1)
        let routines = try store.fetch(FetchDescriptor<Routine>())
        let formerIds = Set(saved.routines.map(\.id))
        #expect(routines.filter { formerIds.contains($0.id) }.allSatisfy { $0.savedTrainingPlanId == nil && $0.planDayIndex == nil })
        // The other plan is untouched.
        #expect(routines.filter { $0.savedTrainingPlanId == other.plan.id }.count == 4)
    }

    // MARK: Rename / delete commit failure

    @Test
    func failedRenameRestoresNameAndUpdatedAtAndIsNeverPersisted() throws {
        let context = try Self.makeContext()
        context.autosaveEnabled = false
        let saved = try #require(try SavedTrainingPlanStore.save(Self.candidate(), split: .upperLower, name: "元の名前", in: context))
        let before = (name: saved.plan.name, updatedAt: saved.plan.updatedAt)
        let unrelated = Routine(name: "未保存の手作り")
        context.insert(unrelated)

        #expect(throws: InjectedSaveFailure.self) {
            try SavedTrainingPlanStore.rename(
                saved.plan, to: "失敗した名前", in: context, now: Date(timeIntervalSince1970: 9_000),
                commit: { _ in throw InjectedSaveFailure() }
            )
        }
        #expect(saved.plan.name == before.name)
        #expect(saved.plan.updatedAt == before.updatedAt)

        try context.save()   // what autosave would do later
        let fresh = ModelContext(context.container)
        let plans = try fresh.fetch(FetchDescriptor<SavedTrainingPlan>())
        #expect(plans.map(\.name) == ["元の名前"])
        #expect(plans.first?.updatedAt == before.updatedAt)
        // The unrelated pending routine was not rolled back.
        #expect(try fresh.fetch(FetchDescriptor<Routine>()).contains { $0.name == "未保存の手作り" })
    }

    @Test
    func failedDeleteRestoresPlanAndLinksAndIsNeverPersisted() throws {
        let context = try Self.makeContext()
        context.autosaveEnabled = false
        let saved = try #require(try SavedTrainingPlanStore.save(Self.candidate(), split: .upperLower, name: "P", in: context))
        let session = Session(routineId: saved.routines[0].id, dayDate: Date(), status: .completed)
        context.insert(session)
        try context.save()
        let before = try Self.counts(context)
        let planId = saved.plan.id
        let links = Dictionary(uniqueKeysWithValues: saved.routines.map { ($0.id, $0.planDayIndex) })
        let unrelated = Routine(name: "未保存の手作り")
        context.insert(unrelated)

        #expect(throws: InjectedSaveFailure.self) {
            try SavedTrainingPlanStore.deletePlanKeepingRoutines(
                saved.plan, in: context, commit: { _ in throw InjectedSaveFailure() }
            )
        }

        func check(_ c: ModelContext) throws {
            let plans = try c.fetch(FetchDescriptor<SavedTrainingPlan>())
            #expect(plans.map(\.id) == [planId])
            let routines = try c.fetch(FetchDescriptor<Routine>())
            for (id, index) in links {
                let routine = try #require(routines.first { $0.id == id })
                #expect(routine.savedTrainingPlanId == planId)
                #expect(routine.planDayIndex == index)
            }
            #expect(try c.fetchCount(FetchDescriptor<Step>()) == before.steps)
            #expect(try c.fetchCount(FetchDescriptor<Session>()) == 1)
            #expect(routines.contains { $0.name == "未保存の手作り" })
        }
        try check(context)
        try context.save()   // what autosave would do later
        try check(ModelContext(context.container))
    }

    // MARK: Session theme

    @Test
    func changingThemeGeneratingAndAlternativesPersistNothing() throws {
        let context = try Self.makeContext()
        for theme in SessionTheme.allCases {
            var request = Self.request
            request.sessionTheme = theme
            let current = RuleBasedWeeklyPlanGenerator.generate(request: request, equipment: Self.equipment)
            _ = RuleBasedWeeklyPlanGenerator.nextDistinctVariation(
                request: request, equipment: Self.equipment, current: current, currentSeed: 0
            )
        }
        let c = try Self.counts(context)
        #expect(c.plans == 0 && c.routines == 0 && c.steps == 0)
        #expect(!context.hasChanges)
    }

    @Test
    func defaultNameShowsANonBalancedTheme() {
        var request = Self.request
        #expect(SavedTrainingPlanStore.defaultName(
            for: RuleBasedWeeklyPlanGenerator.generate(request: request, equipment: Self.equipment), split: .upperLower
        ) == "筋肥大・上下分割・週4日")
        request.sessionTheme = .chestFocus
        #expect(SavedTrainingPlanStore.defaultName(
            for: RuleBasedWeeklyPlanGenerator.generate(request: request, equipment: Self.equipment), split: .upperLower
        ) == "筋肥大・上下分割・週4日・胸重視")
    }

    @Test
    func themedPlanSavesLikeAnyOtherPlan() throws {
        let context = try Self.makeContext()
        var request = Self.request
        request.sessionTheme = .backFocus
        let plan = RuleBasedWeeklyPlanGenerator.generate(request: request, equipment: Self.equipment)
        let saved = try #require(try SavedTrainingPlanStore.save(plan, split: .upperLower, name: "", in: context))
        #expect(saved.plan.name == "筋肥大・上下分割・週4日・背中重視")
        #expect(saved.routines.count == 4)
        #expect(try ModelContext(context.container).fetchCount(FetchDescriptor<SavedTrainingPlan>()) == 1)
    }

    // MARK: Exercise locks + partial regeneration

    @Test
    func lockingAndPartialRegenerationPersistNothing() throws {
        let context = try Self.makeContext()
        let current = RuleBasedWeeklyPlanGenerator.generate(request: Self.request, equipment: Self.equipment)
        let locks: Set<String> = [current.sessions[0].exercises[0].machineId]
        for seed: UInt64 in 0..<5 {
            _ = RuleBasedWeeklyPlanGenerator.regenerateSession(
                request: Self.request, equipment: Self.equipment, current: current,
                sessionIndex: 0, lockedMachineIds: locks, seed: seed
            )
        }
        _ = RuleBasedWeeklyPlanGenerator.nextDistinctSessionVariation(
            request: Self.request, equipment: Self.equipment, current: current,
            sessionIndex: 1, lockedMachineIds: [], currentSeed: 0
        )
        let c = try Self.counts(context)
        #expect(c.plans == 0 && c.routines == 0 && c.steps == 0)
        #expect(!context.hasChanges)
    }

    @Test
    func partiallyRegeneratedPlanSavesExactlyWhatIsShown() throws {
        let context = try Self.makeContext()
        let current = RuleBasedWeeklyPlanGenerator.generate(request: Self.request, equipment: Self.equipment)
        let locks: Set<String> = [current.sessions[0].exercises[0].machineId, current.sessions[0].exercises[2].machineId]
        let edited = try #require(RuleBasedWeeklyPlanGenerator.nextDistinctSessionVariation(
            request: Self.request, equipment: Self.equipment, current: current,
            sessionIndex: 0, lockedMachineIds: locks, currentSeed: 0
        )).candidate
        let saved = try #require(try SavedTrainingPlanStore.save(edited, split: .upperLower, name: "", in: context))
        let fresh = ModelContext(context.container)
        let steps = try fresh.fetch(FetchDescriptor<Step>())
        #expect(saved.routines.count == edited.savableSessionCount)
        for (routine, session) in zip(saved.routines, edited.savableSessions) {
            let rows = steps.filter { $0.routineId == routine.id }.sorted { $0.order < $1.order }
            #expect(rows.map(\.title) == session.exercises.map(\.exerciseName))
            #expect(rows.map(\.restSeconds) == session.exercises.map { $0.template.restSeconds ?? rows[0].restSeconds }
                || session.exercises.contains { $0.template.restSeconds == nil })
        }
    }
}

// MARK: - V10 → V11 migration

@MainActor
struct SavedTrainingPlanMigrationTests {

    @Test("V11 only swaps the frozen Routine and adds SavedTrainingPlan")
    func v11OnlyReplacesRoutineAndAddsPlan() {
        let v10 = Set(PulseCueSchemaV10.models.map { ObjectIdentifier($0) })
        let v11 = Set(PulseCueSchemaV11.models.map { ObjectIdentifier($0) })
        #expect(v11.subtracting(v10) == [ObjectIdentifier(Routine.self), ObjectIdentifier(SavedTrainingPlan.self)])
        #expect(v10.subtracting(v11) == [ObjectIdentifier(PulseCueSchemaV5.Routine.self)])
        #expect(PulseCueMigrationPlan.schemas.contains { $0 == PulseCueSchemaV11.self })
        // V5–V10 still describe the pre-V11 on-disk Routine.
        let v10Names = Set(Schema(versionedSchema: PulseCueSchemaV10.self).entitiesByName["Routine"]?.properties.map(\.name) ?? [])
        #expect(v10Names.contains("storedOrigin"))
        #expect(!v10Names.contains("savedTrainingPlanId"))
    }

    @Test("V10 → V11 keeps existing routines and leaves them unlinked")
    func migrationPreservesRoutines() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsecue-v11migtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("store.sqlite")
        let manualID = UUID(), generatedID = UUID(), legacyID = UUID()

        do {
            let schema = Schema(versionedSchema: PulseCueSchemaV10.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            context.insert(PulseCueSchemaV5.Routine(id: manualID, name: "手作り", isPinned: true, storedOrigin: .userSaved))
            context.insert(PulseCueSchemaV5.Routine(id: generatedID, name: "Quick", storedOrigin: .workoutGenerated))
            context.insert(PulseCueSchemaV5.Routine(id: legacyID, name: "古い", storedOrigin: nil))
            context.insert(Step(routineId: manualID, order: 0, title: "ベンチ", sets: 3, repsTarget: 10, restSeconds: 60))
            try context.save()
        }

        do {
            let schema = Schema(versionedSchema: PulseCueSchemaV11.self)
            let container = try ModelContainer(
                for: schema, migrationPlan: PulseCueMigrationPlan.self,
                configurations: ModelConfiguration(schema: schema, url: url)
            )
            let context = ModelContext(container)
            let routines = try context.fetch(FetchDescriptor<Routine>())
            #expect(Set(routines.map(\.id)) == [manualID, generatedID, legacyID])
            #expect(routines.allSatisfy { $0.savedTrainingPlanId == nil && $0.planDayIndex == nil })
            #expect(routines.first { $0.id == manualID }?.isPinned == true)
            #expect(routines.first { $0.id == generatedID }?.origin == .workoutGenerated)
            #expect(routines.first { $0.id == legacyID }?.origin == .userSaved)
            #expect(try context.fetchCount(FetchDescriptor<Step>()) == 1)
            #expect(try context.fetchCount(FetchDescriptor<SavedTrainingPlan>()) == 0)

            // The migrated store is usable: a plan written now survives reopening.
            context.insert(SavedTrainingPlan(name: "移行後", goalRaw: "hypertrophy", splitRaw: "upperLower", daysPerWeek: 4))
            try context.save()
        }

        do {
            let schema = Schema(versionedSchema: PulseCueSchemaV11.self)
            let container = try ModelContainer(
                for: schema, migrationPlan: PulseCueMigrationPlan.self,
                configurations: ModelConfiguration(schema: schema, url: url)
            )
            let context = ModelContext(container)
            #expect(try context.fetch(FetchDescriptor<SavedTrainingPlan>()).map(\.name) == ["移行後"])
            #expect(try context.fetchCount(FetchDescriptor<Routine>()) == 3)
        }
    }
}

// MARK: - V11 → V12 migration

@MainActor
struct StepResultWeightMigrationTests {

    @Test("V12 only swaps the V6 StepResult for the V12 one with weightKg")
    func v12OnlyReplacesStepResult() {
        let v11 = Set(PulseCueSchemaV11.models.map { ObjectIdentifier($0) })
        let v12 = Set(PulseCueSchemaV12.models.map { ObjectIdentifier($0) })
        #expect(v12.subtracting(v11) == [ObjectIdentifier(PulseCueSchemaV12.StepResult.self)])
        #expect(v11.subtracting(v12) == [ObjectIdentifier(PulseCueSchemaV6.StepResult.self)])
        // V6–V11 still describe the pre-V12 on-disk StepResult.
        let v11Names = Set(Schema(versionedSchema: PulseCueSchemaV11.self).entitiesByName["StepResult"]?.properties.map(\.name) ?? [])
        #expect(v11Names.contains("ownerAccountID"))
        #expect(!v11Names.contains("weightKg"))
        let v12Names = Set(Schema(versionedSchema: PulseCueSchemaV12.self).entitiesByName["StepResult"]?.properties.map(\.name) ?? [])
        #expect(v12Names.contains("weightKg"))
    }

    @Test("V11 → V12 keeps every result and its reps; weight starts as nil")
    func migrationPreservesResults() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsecue-v12migtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("store.sqlite")
        let owner = UUID(), sessionID = UUID(), stepID = UUID(), routineID = UUID()

        do {
            let schema = Schema(versionedSchema: PulseCueSchemaV11.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            context.insert(Routine(id: routineID, name: "既存"))
            context.insert(Step(id: stepID, routineId: routineID, order: 0, title: "ベンチ", sets: 2, repsTarget: 10, restSeconds: 60))
            context.insert(Session(id: sessionID, routineId: routineID, dayDate: Date(), ownerAccountID: owner))
            context.insert(PulseCueSchemaV6.StepResult(sessionId: sessionID, stepId: stepID, setIndex: 0, done: true, actualReps: 10, memo: "m", ownerAccountID: owner))
            context.insert(PulseCueSchemaV6.StepResult(sessionId: sessionID, stepId: stepID, setIndex: 1, done: false))
            context.insert(SavedTrainingPlan(name: "週4", goalRaw: "hypertrophy", splitRaw: "upperLower", daysPerWeek: 4))
            try context.save()
        }

        do {
            let schema = Schema(versionedSchema: PulseCueSchemaV12.self)
            let container = try ModelContainer(
                for: schema, migrationPlan: PulseCueMigrationPlan.self,
                configurations: ModelConfiguration(schema: schema, url: url)
            )
            let context = ModelContext(container)
            let results = try context.fetch(FetchDescriptor<PulseCueSchemaV12.StepResult>()).sorted { $0.setIndex < $1.setIndex }
            #expect(results.map(\.actualReps) == [10, nil])
            #expect(results.map(\.done) == [true, false])
            #expect(results.map(\.weightKg) == [nil, nil])
            #expect(results.first?.memo == "m")
            #expect(results.first?.ownerAccountID == owner)
            #expect(try context.fetchCount(FetchDescriptor<Session>()) == 1)
            #expect(try context.fetchCount(FetchDescriptor<Step>()) == 1)
            #expect(try context.fetchCount(FetchDescriptor<Routine>()) == 1)
            #expect(try context.fetchCount(FetchDescriptor<SavedTrainingPlan>()) == 1)

            results[0].weightKg = 62.5
            try context.save()
        }

        do {
            let schema = Schema(versionedSchema: PulseCueSchemaV12.self)
            let container = try ModelContainer(
                for: schema, migrationPlan: PulseCueMigrationPlan.self,
                configurations: ModelConfiguration(schema: schema, url: url)
            )
            let context = ModelContext(container)
            let results = try context.fetch(FetchDescriptor<PulseCueSchemaV12.StepResult>()).sorted { $0.setIndex < $1.setIndex }
            #expect(results.map(\.weightKg) == [62.5, nil])
        }
    }
}

// MARK: - V12 → V13 migration

@MainActor
struct StepResultPlannedSetsMigrationTests {

    /// (name, optional, unique, type) of every StepResult attribute in a schema.
    private static func stepResultShape(_ schema: any VersionedSchema.Type) -> Set<String> {
        let attributes = Schema(versionedSchema: schema).entitiesByName["StepResult"]?.attributes ?? []
        return Set(attributes.map { "\($0.name)|\($0.isOptional)|\($0.isUnique)|\(String(describing: $0.valueType))" })
    }

    @Test("V13 only swaps the frozen V12 StepResult for the frozen V13 one")
    func v13OnlyReplacesStepResult() {
        let v12 = Set(PulseCueSchemaV12.models.map { ObjectIdentifier($0) })
        let v13 = Set(PulseCueSchemaV13.models.map { ObjectIdentifier($0) })
        #expect(v13.subtracting(v12) == [ObjectIdentifier(PulseCueSchemaV13.StepResult.self)])
        #expect(v12.subtracting(v13) == [ObjectIdentifier(PulseCueSchemaV12.StepResult.self)])
        #expect(PulseCueSchemaV12.versionIdentifier == Schema.Version(12, 0, 0))
        #expect(PulseCueSchemaV13.versionIdentifier == Schema.Version(13, 0, 0))
    }

    @Test("Frozen V12 StepResult is exactly the shipped V12 shape")
    func frozenV12MatchesTheShippedShape() {
        let v12 = Self.stepResultShape(PulseCueSchemaV12.self)
        // Shipped V12 = V6–V11's StepResult plus an optional Double `weightKg`.
        let v11 = Self.stepResultShape(PulseCueSchemaV11.self)
        #expect(v12.subtracting(v11).count == 1)
        #expect(v12.subtracting(v11).first?.hasPrefix("weightKg|true|false|") == true)
        #expect(v11.isSubset(of: v12))
        #expect(Set(v12.map { String($0.prefix { $0 != "|" }) }) == [
            "id", "sessionId", "stepId", "setIndex", "done", "actualReps", "memo", "ownerAccountID", "weightKg",
        ])
        #expect(v12.contains { $0.hasPrefix("id|false|true|") })
        // V13 adds exactly one optional attribute and changes nothing else.
        let v13 = Self.stepResultShape(PulseCueSchemaV13.self)
        #expect(v12.isSubset(of: v13))
        #expect(v13.subtracting(v12).count == 1)
        #expect(v13.subtracting(v12).first?.hasPrefix("plannedSetsAtExecution|true|false|") == true)
    }

    @Test("V12 → V13 keeps every result; the planned-sets snapshot starts nil and then persists")
    func migrationPreservesResultsAndStartsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsecue-v13migtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("store.sqlite")
        let owner = UUID(), sessionID = UUID(), stepID = UUID(), routineID = UUID()

        // A store genuinely stamped V12 (V12 schema only, no plan).
        do {
            let schema = Schema(versionedSchema: PulseCueSchemaV12.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            context.insert(Routine(id: routineID, name: "既存"))
            context.insert(Step(id: stepID, routineId: routineID, order: 0, title: "ベンチ", sets: 3, repsTarget: 10, restSeconds: 60))
            context.insert(Session(id: sessionID, routineId: routineID, dayDate: Date(), ownerAccountID: owner))
            context.insert(PulseCueSchemaV12.StepResult(sessionId: sessionID, stepId: stepID, setIndex: 0, done: true, actualReps: 10, memo: "m", ownerAccountID: owner, weightKg: 60))
            context.insert(PulseCueSchemaV12.StepResult(sessionId: sessionID, stepId: stepID, setIndex: 1, done: false, ownerAccountID: owner))
            try context.save()
        }

        do {
            let schema = Schema(versionedSchema: PulseCueSchemaV13.self)
            let container = try ModelContainer(
                for: schema, migrationPlan: PulseCueMigrationPlan.self,
                configurations: ModelConfiguration(schema: schema, url: url)
            )
            let context = ModelContext(container)
            let results = try context.fetch(FetchDescriptor<PulseCueSchemaV13.StepResult>()).sorted { $0.setIndex < $1.setIndex }
            #expect(results.map(\.sessionId) == [sessionID, sessionID])
            #expect(results.map(\.stepId) == [stepID, stepID])
            #expect(results.map(\.done) == [true, false])
            #expect(results.map(\.actualReps) == [10, nil])
            #expect(results.map(\.weightKg) == [60, nil])
            #expect(results.map(\.ownerAccountID) == [owner, owner])
            #expect(results.first?.memo == "m")
            // Legacy results are unknown, never backfilled from Step.sets (3).
            #expect(results.map(\.plannedSetsAtExecution) == [nil, nil])
            #expect(try context.fetchCount(FetchDescriptor<Session>()) == 1)
            #expect(try context.fetchCount(FetchDescriptor<Step>()) == 1)
            #expect(try context.fetchCount(FetchDescriptor<Routine>()) == 1)

            context.insert(PulseCueSchemaV13.StepResult(sessionId: UUID(), stepId: stepID, setIndex: 0, done: true, actualReps: 8, plannedSetsAtExecution: 4))
            try context.save()
        }

        do {
            let schema = Schema(versionedSchema: PulseCueSchemaV13.self)
            let container = try ModelContainer(
                for: schema, migrationPlan: PulseCueMigrationPlan.self,
                configurations: ModelConfiguration(schema: schema, url: url)
            )
            let context = ModelContext(container)
            let planned = try context.fetch(FetchDescriptor<PulseCueSchemaV13.StepResult>()).map(\.plannedSetsAtExecution)
            #expect(planned.sorted { ($0 ?? -1) < ($1 ?? -1) } == [nil, nil, 4])
        }
    }
}

// MARK: - V13 → V14 migration

@MainActor
struct StepResultExerciseSnapshotMigrationTests {

    /// (name, optional, unique, type) of every attribute of `entity` in a schema.
    private static func shape(_ schema: any VersionedSchema.Type, _ entity: String = "StepResult") -> Set<String> {
        let attributes = Schema(versionedSchema: schema).entitiesByName[entity]?.attributes ?? []
        return Set(attributes.map { "\($0.name)|\($0.isOptional)|\($0.isUnique)|\(String(describing: $0.valueType))" })
    }

    @Test("V14 only swaps the frozen V13 StepResult for the frozen V14 one")
    func v14OnlyReplacesStepResult() {
        let v13 = Set(PulseCueSchemaV13.models.map { ObjectIdentifier($0) })
        let v14 = Set(PulseCueSchemaV14.models.map { ObjectIdentifier($0) })
        #expect(v14.subtracting(v13) == [ObjectIdentifier(PulseCueSchemaV14.StepResult.self)])
        #expect(v13.subtracting(v14) == [ObjectIdentifier(PulseCueSchemaV13.StepResult.self)])
        #expect(PulseCueSchemaV13.models.count == PulseCueSchemaV14.models.count)
        #expect(PulseCueMigrationPlan.stages.count == PulseCueMigrationPlan.schemas.count - 1)
        #expect(PulseCueSchemaV13.versionIdentifier == Schema.Version(13, 0, 0))
        #expect(PulseCueSchemaV14.versionIdentifier == Schema.Version(14, 0, 0))
    }

    @Test("Frozen V13 StepResult is exactly the shipped V13 shape")
    func frozenV13MatchesTheShippedShape() {
        let v12 = Self.shape(PulseCueSchemaV12.self)
        let v13 = Self.shape(PulseCueSchemaV13.self)
        // Shipped V13 = frozen V12 plus an optional Int `plannedSetsAtExecution`.
        #expect(v12.isSubset(of: v13))
        #expect(v13.subtracting(v12) == ["plannedSetsAtExecution|true|false|\(String(describing: Optional<Int>.self))"])
        #expect(Set(v13.map { String($0.prefix { $0 != "|" }) }) == [
            "id", "sessionId", "stepId", "setIndex", "done", "actualReps", "memo", "ownerAccountID", "weightKg",
            "plannedSetsAtExecution",
        ])
        #expect(v13.contains { $0.hasPrefix("id|false|true|") })
        #expect(Schema(versionedSchema: PulseCueSchemaV13.self).entitiesByName["StepResult"]?.relationships.isEmpty == true)
        // V14 adds exactly two optional Strings and changes nothing else.
        let v14 = Self.shape(PulseCueSchemaV14.self)
        #expect(v13.isSubset(of: v14))
        let optionalString = String(describing: Optional<String>.self)
        #expect(v14.subtracting(v13) == [
            "exerciseIdAtExecution|true|false|\(optionalString)",
            "exerciseTitleAtExecution|true|false|\(optionalString)",
        ])
        // Every other entity is byte-for-byte the same model in V13 and V14.
        let names = Schema(versionedSchema: PulseCueSchemaV13.self).entitiesByName.keys.filter { $0 != "StepResult" }
        #expect(Set(names) == Set(Schema(versionedSchema: PulseCueSchemaV14.self).entitiesByName.keys.filter { $0 != "StepResult" }))
        for name in names {
            #expect(Self.shape(PulseCueSchemaV13.self, name) == Self.shape(PulseCueSchemaV14.self, name), "\(name)")
        }
    }

    @Test("V13 → V14 keeps every result; the exercise snapshot starts nil and then persists")
    func migrationPreservesResultsAndStartsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsecue-v14migtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("store.sqlite")
        let owner = UUID(), sessionID = UUID(), stepID = UUID(), routineID = UUID()

        // A store genuinely stamped V13 (V13 schema only, no plan).
        do {
            let schema = Schema(versionedSchema: PulseCueSchemaV13.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            context.insert(Routine(id: routineID, name: "既存"))
            context.insert(Step(id: stepID, routineId: routineID, order: 0, title: "ベンチ", sets: 3, repsTarget: 10, restSeconds: 60, exerciseId: "bench_press"))
            context.insert(Session(id: sessionID, routineId: routineID, dayDate: Date(), ownerAccountID: owner))
            context.insert(PulseCueSchemaV13.StepResult(sessionId: sessionID, stepId: stepID, setIndex: 0, done: true, actualReps: 10, memo: "m", ownerAccountID: owner, weightKg: 60, plannedSetsAtExecution: 3))
            context.insert(PulseCueSchemaV13.StepResult(sessionId: sessionID, stepId: stepID, setIndex: 1, done: false, ownerAccountID: owner))
            try context.save()
        }

        do {
            let schema = Schema(versionedSchema: PulseCueSchemaV14.self)
            let container = try ModelContainer(
                for: schema, migrationPlan: PulseCueMigrationPlan.self,
                configurations: ModelConfiguration(schema: schema, url: url)
            )
            let context = ModelContext(container)
            let results = try context.fetch(FetchDescriptor<PulseCueSchemaV14.StepResult>()).sorted { $0.setIndex < $1.setIndex }
            #expect(results.map(\.sessionId) == [sessionID, sessionID])
            #expect(results.map(\.stepId) == [stepID, stepID])
            #expect(results.map(\.done) == [true, false])
            #expect(results.map(\.actualReps) == [10, nil])
            #expect(results.map(\.weightKg) == [60, nil])
            #expect(results.map(\.ownerAccountID) == [owner, owner])
            #expect(results.map(\.plannedSetsAtExecution) == [3, nil])
            #expect(results.first?.memo == "m")
            // Legacy results are unknown, never backfilled from the live step.
            #expect(results.map(\.exerciseIdAtExecution) == [nil, nil])
            #expect(results.map(\.exerciseTitleAtExecution) == [nil, nil])
            #expect(try context.fetch(FetchDescriptor<Step>()).first?.exerciseId == "bench_press")
            #expect(try context.fetchCount(FetchDescriptor<Session>()) == 1)
            #expect(try context.fetchCount(FetchDescriptor<Routine>()) == 1)

            context.insert(PulseCueSchemaV14.StepResult(sessionId: UUID(), stepId: stepID, setIndex: 0, done: true, actualReps: 8, plannedSetsAtExecution: 3, exerciseIdAtExecution: "machine_chest_press", exerciseTitleAtExecution: "チェストプレス"))
            try context.save()
        }

        do {
            let schema = Schema(versionedSchema: PulseCueSchemaV14.self)
            let container = try ModelContainer(
                for: schema, migrationPlan: PulseCueMigrationPlan.self,
                configurations: ModelConfiguration(schema: schema, url: url)
            )
            let context = ModelContext(container)
            let results = try context.fetch(FetchDescriptor<PulseCueSchemaV14.StepResult>())
            #expect(results.count == 3)
            #expect(results.compactMap(\.exerciseIdAtExecution) == ["machine_chest_press"])
            #expect(results.compactMap(\.exerciseTitleAtExecution) == ["チェストプレス"])
        }
    }
}

// MARK: - V14 → V15 migration

@MainActor
struct StepResultDurationMigrationTests {

    private static func shape(_ schema: any VersionedSchema.Type, _ entity: String = "StepResult") -> Set<String> {
        let attributes = Schema(versionedSchema: schema).entitiesByName[entity]?.attributes ?? []
        return Set(attributes.map { "\($0.name)|\($0.isOptional)|\($0.isUnique)|\(String(describing: $0.valueType))" })
    }

    @Test("V15 adds exactly one optional Int to StepResult and changes nothing else")
    func v15OnlyAddsTheDuration() {
        let v14 = Self.shape(PulseCueSchemaV14.self)
        let v15 = Self.shape(PulseCueSchemaV15.self)
        #expect(v14.isSubset(of: v15))
        #expect(v15.subtracting(v14) == ["actualDurationSeconds|true|false|\(String(describing: Optional<Int>.self))"])
        let names = Schema(versionedSchema: PulseCueSchemaV14.self).entitiesByName.keys.filter { $0 != "StepResult" }
        #expect(Set(names) == Set(Schema(versionedSchema: PulseCueSchemaV15.self).entitiesByName.keys.filter { $0 != "StepResult" }))
        for name in names {
            #expect(Self.shape(PulseCueSchemaV14.self, name) == Self.shape(PulseCueSchemaV15.self, name), "\(name)")
        }
        let v14Models = Set(PulseCueSchemaV14.models.map { ObjectIdentifier($0) })
        let v15Models = Set(PulseCueSchemaV15.models.map { ObjectIdentifier($0) })
        #expect(v15Models.subtracting(v14Models) == [ObjectIdentifier(PulseCueSchemaV15.StepResult.self)])
        #expect(v14Models.subtracting(v15Models) == [ObjectIdentifier(PulseCueSchemaV14.StepResult.self)])
    }

    @Test("V14 → V15 keeps timed and weighted results as they were; the duration starts nil")
    func migrationKeepsResultsAndStartsDurationNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsecue-v15migtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("store.sqlite")
        let owner = UUID(), sessionID = UUID(), routineID = UUID(), treadmillStep = UUID(), benchStep = UUID()

        // A store genuinely stamped V14 (V14 schema only, no plan).
        do {
            let schema = Schema(versionedSchema: PulseCueSchemaV14.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            context.insert(Routine(id: routineID, name: "既存"))
            context.insert(Session(id: sessionID, routineId: routineID, dayDate: Date(), ownerAccountID: owner))
            // An older timed result that still carries a rep count.
            context.insert(PulseCueSchemaV14.StepResult(sessionId: sessionID, stepId: treadmillStep, setIndex: 0, done: true, actualReps: 10, ownerAccountID: owner, plannedSetsAtExecution: 1, exerciseIdAtExecution: "treadmill_warmup", exerciseTitleAtExecution: "トレッドミルウォームアップ"))
            context.insert(PulseCueSchemaV14.StepResult(sessionId: sessionID, stepId: benchStep, setIndex: 0, done: true, actualReps: 10, memo: "m", ownerAccountID: owner, weightKg: 80, plannedSetsAtExecution: 3, exerciseIdAtExecution: "bench_press", exerciseTitleAtExecution: "ベンチプレス"))
            try context.save()
        }

        do {
            let schema = Schema(versionedSchema: PulseCueSchemaV15.self)
            let container = try ModelContainer(
                for: schema, migrationPlan: PulseCueMigrationPlan.self,
                configurations: ModelConfiguration(schema: schema, url: url)
            )
            let context = ModelContext(container)
            let results = try context.fetch(FetchDescriptor<PulseCueSchemaV15.StepResult>())
            #expect(results.count == 2)
            let timed = try #require(results.first { $0.stepId == treadmillStep })
            #expect(timed.done)
            #expect(timed.actualReps == 10)                 // kept as stored, never converted
            #expect(timed.actualDurationSeconds == nil)
            #expect(timed.exerciseIdAtExecution == "treadmill_warmup")
            #expect(timed.exerciseTitleAtExecution == "トレッドミルウォームアップ")
            #expect(timed.plannedSetsAtExecution == 1)
            #expect(timed.sessionId == sessionID)
            #expect(timed.ownerAccountID == owner)

            let bench = try #require(results.first { $0.stepId == benchStep })
            #expect(bench.done)
            #expect(bench.actualReps == 10)
            #expect(bench.weightKg == 80)
            #expect(bench.memo == "m")
            #expect(bench.plannedSetsAtExecution == 3)
            #expect(bench.exerciseIdAtExecution == "bench_press")
            #expect(bench.exerciseTitleAtExecution == "ベンチプレス")
            #expect(bench.ownerAccountID == owner)
            #expect(bench.actualDurationSeconds == nil)
            #expect(try context.fetchCount(FetchDescriptor<Session>()) == 1)

            timed.actualDurationSeconds = 750
            try context.save()
        }

        do {
            let schema = Schema(versionedSchema: PulseCueSchemaV15.self)
            let container = try ModelContainer(
                for: schema, migrationPlan: PulseCueMigrationPlan.self,
                configurations: ModelConfiguration(schema: schema, url: url)
            )
            let results = try ModelContext(container).fetch(FetchDescriptor<PulseCueSchemaV15.StepResult>())
            #expect(results.compactMap(\.actualDurationSeconds) == [750])
        }
    }
}

// MARK: - V15 → V16 migration

@MainActor
struct StepResultRepsInReserveMigrationTests {

    private static func shape(_ schema: any VersionedSchema.Type, _ entity: String = "StepResult") -> Set<String> {
        let attributes = Schema(versionedSchema: schema).entitiesByName[entity]?.attributes ?? []
        return Set(attributes.map { "\($0.name)|\($0.isOptional)|\($0.isUnique)|\(String(describing: $0.valueType))" })
    }

    @Test("V16 adds exactly one optional Int to StepResult and changes nothing else")
    func v16OnlyAddsRepsInReserve() {
        let v15 = Self.shape(PulseCueSchemaV15.self)
        let v16 = Self.shape(PulseCueSchemaV16.self)
        #expect(v15.isSubset(of: v16))
        #expect(v16.subtracting(v15) == ["repsInReserve|true|false|\(String(describing: Optional<Int>.self))"])
        let names = Schema(versionedSchema: PulseCueSchemaV15.self).entitiesByName.keys.filter { $0 != "StepResult" }
        #expect(Set(names) == Set(Schema(versionedSchema: PulseCueSchemaV16.self).entitiesByName.keys.filter { $0 != "StepResult" }))
        for name in names {
            #expect(Self.shape(PulseCueSchemaV15.self, name) == Self.shape(PulseCueSchemaV16.self, name), "\(name)")
        }
        let v15Models = Set(PulseCueSchemaV15.models.map { ObjectIdentifier($0) })
        let v16Models = Set(PulseCueSchemaV16.models.map { ObjectIdentifier($0) })
        #expect(v16Models.subtracting(v15Models) == [ObjectIdentifier(PulseCueSchemaV16.StepResult.self)])
        #expect(v15Models.subtracting(v16Models) == [ObjectIdentifier(PulseCueSchemaV15.StepResult.self)])
    }

    @Test("V15 → V16 keeps every result as it was; reps in reserve starts nil")
    func migrationKeepsResultsAndStartsRepsInReserveNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsecue-v16migtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("store.sqlite")
        let owner = UUID(), sessionID = UUID(), routineID = UUID(), treadmillStep = UUID(), benchStep = UUID()

        // A store genuinely stamped V15 (V15 schema only, no plan).
        do {
            let schema = Schema(versionedSchema: PulseCueSchemaV15.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            context.insert(Routine(id: routineID, name: "既存"))
            context.insert(Session(id: sessionID, routineId: routineID, dayDate: Date(), ownerAccountID: owner))
            context.insert(PulseCueSchemaV15.StepResult(sessionId: sessionID, stepId: treadmillStep, setIndex: 0, done: true, ownerAccountID: owner, plannedSetsAtExecution: 1, exerciseIdAtExecution: "treadmill_warmup", exerciseTitleAtExecution: "トレッドミルウォームアップ", actualDurationSeconds: 750))
            context.insert(PulseCueSchemaV15.StepResult(sessionId: sessionID, stepId: benchStep, setIndex: 0, done: true, actualReps: 10, memo: "m", ownerAccountID: owner, weightKg: 80, plannedSetsAtExecution: 3, exerciseIdAtExecution: "bench_press", exerciseTitleAtExecution: "ベンチプレス"))
            context.insert(PulseCueSchemaV15.StepResult(sessionId: sessionID, stepId: benchStep, setIndex: 1, done: false, ownerAccountID: owner, plannedSetsAtExecution: 3, exerciseIdAtExecution: "bench_press", exerciseTitleAtExecution: "ベンチプレス"))
            try context.save()
        }

        do {
            let schema = Schema(versionedSchema: PulseCueSchemaV16.self)
            let container = try ModelContainer(
                for: schema, migrationPlan: PulseCueMigrationPlan.self,
                configurations: ModelConfiguration(schema: schema, url: url)
            )
            let context = ModelContext(container)
            let results = try context.fetch(FetchDescriptor<PulseCueSchemaV16.StepResult>())
            #expect(results.count == 3)
            #expect(results.allSatisfy { $0.repsInReserve == nil })     // never guessed

            let timed = try #require(results.first { $0.stepId == treadmillStep })
            #expect(timed.done && timed.actualReps == nil && timed.actualDurationSeconds == 750)
            #expect(timed.exerciseIdAtExecution == "treadmill_warmup" && timed.plannedSetsAtExecution == 1)
            #expect(timed.ownerAccountID == owner && timed.sessionId == sessionID)

            let bench = try #require(results.first { $0.stepId == benchStep && $0.setIndex == 0 })
            #expect(bench.done && bench.actualReps == 10 && bench.weightKg == 80 && bench.memo == "m")
            #expect(bench.plannedSetsAtExecution == 3 && bench.actualDurationSeconds == nil)
            #expect(bench.exerciseIdAtExecution == "bench_press" && bench.exerciseTitleAtExecution == "ベンチプレス")

            let skipped = try #require(results.first { $0.stepId == benchStep && $0.setIndex == 1 })
            #expect(!skipped.done && skipped.actualReps == nil && skipped.weightKg == nil)
            #expect(try context.fetchCount(FetchDescriptor<Session>()) == 1)

            bench.repsInReserve = 2
            try context.save()
        }

        do {
            let schema = Schema(versionedSchema: PulseCueSchemaV16.self)
            let container = try ModelContainer(
                for: schema, migrationPlan: PulseCueMigrationPlan.self,
                configurations: ModelConfiguration(schema: schema, url: url)
            )
            let results = try ModelContext(container).fetch(FetchDescriptor<PulseCueSchemaV16.StepResult>())
            #expect(results.compactMap(\.repsInReserve) == [2])
        }
    }

    @Test("A V14 store opens at V16 through V15, every result intact")
    func v14StoreReachesV16() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsecue-v14to16-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("store.sqlite")
        let sessionID = UUID(), routineID = UUID(), benchStep = UUID()
        do {
            let schema = Schema(versionedSchema: PulseCueSchemaV14.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            context.insert(Routine(id: routineID, name: "既存"))
            context.insert(Session(id: sessionID, routineId: routineID, dayDate: Date()))
            context.insert(PulseCueSchemaV14.StepResult(sessionId: sessionID, stepId: benchStep, setIndex: 0, done: true, actualReps: 8, weightKg: 60, plannedSetsAtExecution: 3, exerciseIdAtExecution: "bench_press", exerciseTitleAtExecution: "ベンチプレス"))
            try context.save()
        }
        let schema = Schema(versionedSchema: PulseCueSchemaV16.self)
        let container = try ModelContainer(
            for: schema, migrationPlan: PulseCueMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: url)
        )
        let result = try #require(try ModelContext(container).fetch(FetchDescriptor<PulseCueSchemaV16.StepResult>()).first)
        #expect(result.actualReps == 8 && result.weightKg == 60 && result.done)
        #expect(result.actualDurationSeconds == nil && result.repsInReserve == nil)
        #expect(result.exerciseIdAtExecution == "bench_press")
    }
}

// MARK: - V16 → V17 migration

@MainActor
struct StepResultSetTypeMigrationTests {

    private static func shape(_ schema: any VersionedSchema.Type, _ entity: String = "StepResult") -> Set<String> {
        let attributes = Schema(versionedSchema: schema).entitiesByName[entity]?.attributes ?? []
        return Set(attributes.map { "\($0.name)|\($0.isOptional)|\($0.isUnique)|\(String(describing: $0.valueType))" })
    }

    private static func storeURL(_ tag: String) throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsecue-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent("store.sqlite"))
    }

    private static func openCurrent(_ url: URL) throws -> ModelContext {
        let schema = Schema(versionedSchema: PulseCueSchemaV17.self)
        let container = try ModelContainer(
            for: schema, migrationPlan: PulseCueMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: url)
        )
        return ModelContext(container)
    }

    @Test("V17 adds exactly one optional String to StepResult and changes nothing else")
    func v17OnlyAddsSetTypeRaw() {
        let v16 = Self.shape(PulseCueSchemaV16.self)
        let v17 = Self.shape(PulseCueSchemaV17.self)
        #expect(v16.isSubset(of: v17))
        #expect(v17.subtracting(v16) == ["setTypeRaw|true|false|\(String(describing: Optional<String>.self))"])
        let names = Schema(versionedSchema: PulseCueSchemaV16.self).entitiesByName.keys.filter { $0 != "StepResult" }
        #expect(Set(names) == Set(Schema(versionedSchema: PulseCueSchemaV17.self).entitiesByName.keys.filter { $0 != "StepResult" }))
        for name in names {
            #expect(Self.shape(PulseCueSchemaV16.self, name) == Self.shape(PulseCueSchemaV17.self, name), "\(name)")
        }
        let v16Models = Set(PulseCueSchemaV16.models.map { ObjectIdentifier($0) })
        let v17Models = Set(PulseCueSchemaV17.models.map { ObjectIdentifier($0) })
        #expect(v17Models.subtracting(v16Models) == [ObjectIdentifier(StepResult.self)])
        #expect(v16Models.subtracting(v17Models) == [ObjectIdentifier(PulseCueSchemaV16.StepResult.self)])
    }

    @Test("V16 → V17 keeps every result as it was; every set reads as working")
    func v16StoreReachesV17() throws {
        let (dir, url) = try Self.storeURL("v16to17")
        defer { try? FileManager.default.removeItem(at: dir) }
        let owner = UUID(), sessionID = UUID(), routineID = UUID(), treadmillStep = UUID(), benchStep = UUID()
        do {
            let schema = Schema(versionedSchema: PulseCueSchemaV16.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            context.insert(Routine(id: routineID, name: "既存"))
            context.insert(Session(id: sessionID, routineId: routineID, dayDate: Date(), ownerAccountID: owner))
            context.insert(PulseCueSchemaV16.StepResult(sessionId: sessionID, stepId: treadmillStep, setIndex: 0, done: true, ownerAccountID: owner, plannedSetsAtExecution: 1, exerciseIdAtExecution: "treadmill_warmup", exerciseTitleAtExecution: "トレッドミルウォームアップ", actualDurationSeconds: 750))
            context.insert(PulseCueSchemaV16.StepResult(sessionId: sessionID, stepId: benchStep, setIndex: 0, done: true, actualReps: 10, memo: "m", ownerAccountID: owner, weightKg: 80, plannedSetsAtExecution: 3, exerciseIdAtExecution: "bench_press", exerciseTitleAtExecution: "ベンチプレス", repsInReserve: 2))
            context.insert(PulseCueSchemaV16.StepResult(sessionId: sessionID, stepId: benchStep, setIndex: 1, done: false, ownerAccountID: owner, plannedSetsAtExecution: 3, exerciseIdAtExecution: "bench_press", exerciseTitleAtExecution: "ベンチプレス"))
            try context.save()
        }

        do {
            let context = try Self.openCurrent(url)
            let results = try context.fetch(FetchDescriptor<StepResult>())
            #expect(results.count == 3)
            #expect(results.allSatisfy { $0.setTypeRaw == nil && $0.setType == .working })     // never guessed

            let timed = try #require(results.first { $0.stepId == treadmillStep })
            #expect(timed.done && timed.actualReps == nil && timed.actualDurationSeconds == 750)
            #expect(timed.exerciseIdAtExecution == "treadmill_warmup" && timed.plannedSetsAtExecution == 1)
            #expect(timed.ownerAccountID == owner && timed.sessionId == sessionID)

            let bench = try #require(results.first { $0.stepId == benchStep && $0.setIndex == 0 })
            #expect(bench.done && bench.actualReps == 10 && bench.weightKg == 80 && bench.memo == "m")
            #expect(bench.repsInReserve == 2 && bench.ownerAccountID == owner)
            #expect(bench.plannedSetsAtExecution == 3 && bench.actualDurationSeconds == nil)
            #expect(bench.exerciseIdAtExecution == "bench_press" && bench.exerciseTitleAtExecution == "ベンチプレス")

            let skipped = try #require(results.first { $0.stepId == benchStep && $0.setIndex == 1 })
            #expect(!skipped.done && skipped.actualReps == nil && skipped.weightKg == nil && skipped.repsInReserve == nil)
            let session = try #require(try context.fetch(FetchDescriptor<Session>()).first)
            #expect(session.id == sessionID && session.ownerAccountID == owner)

            bench.setTypeRaw = WorkoutSetType.warmup.storedRawValue
            try context.save()
        }

        let reopened = try Self.openCurrent(url).fetch(FetchDescriptor<StepResult>())
        #expect(reopened.compactMap(\.setTypeRaw) == ["warmup"])
    }

    @Test("A V15 store opens at V17 through V16, every result intact")
    func v15StoreReachesV17() throws {
        let (dir, url) = try Self.storeURL("v15to17")
        defer { try? FileManager.default.removeItem(at: dir) }
        let owner = UUID(), sessionID = UUID(), routineID = UUID(), benchStep = UUID(), plankStep = UUID()
        do {
            let schema = Schema(versionedSchema: PulseCueSchemaV15.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            context.insert(Routine(id: routineID, name: "既存"))
            context.insert(Session(id: sessionID, routineId: routineID, dayDate: Date(), ownerAccountID: owner))
            context.insert(PulseCueSchemaV15.StepResult(sessionId: sessionID, stepId: benchStep, setIndex: 0, done: true, actualReps: 8, ownerAccountID: owner, weightKg: 60, plannedSetsAtExecution: 3, exerciseIdAtExecution: "bench_press", exerciseTitleAtExecution: "ベンチプレス"))
            context.insert(PulseCueSchemaV15.StepResult(sessionId: sessionID, stepId: plankStep, setIndex: 0, done: true, ownerAccountID: owner, plannedSetsAtExecution: 1, exerciseIdAtExecution: "treadmill_warmup", exerciseTitleAtExecution: "トレッドミルウォームアップ", actualDurationSeconds: 90))
            try context.save()
        }
        let context = try Self.openCurrent(url)
        let results = try context.fetch(FetchDescriptor<StepResult>())
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.setTypeRaw == nil && $0.setType == .working && $0.repsInReserve == nil })
        let bench = try #require(results.first { $0.stepId == benchStep })
        #expect(bench.actualReps == 8 && bench.weightKg == 60 && bench.done && bench.ownerAccountID == owner)
        #expect(bench.plannedSetsAtExecution == 3 && bench.exerciseTitleAtExecution == "ベンチプレス")
        #expect(results.first { $0.stepId == plankStep }?.actualDurationSeconds == 90)
        #expect(try context.fetchCount(FetchDescriptor<Session>()) == 1)
    }

    @Test("A V14 store opens at V17 through V15 and V16, every result intact")
    func v14StoreReachesV17() throws {
        let (dir, url) = try Self.storeURL("v14to17")
        defer { try? FileManager.default.removeItem(at: dir) }
        let owner = UUID(), sessionID = UUID(), routineID = UUID(), benchStep = UUID()
        do {
            let schema = Schema(versionedSchema: PulseCueSchemaV14.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(container)
            context.insert(Routine(id: routineID, name: "既存"))
            context.insert(Session(id: sessionID, routineId: routineID, dayDate: Date(), ownerAccountID: owner))
            context.insert(PulseCueSchemaV14.StepResult(sessionId: sessionID, stepId: benchStep, setIndex: 0, done: true, actualReps: 8, ownerAccountID: owner, weightKg: 60, plannedSetsAtExecution: 3, exerciseIdAtExecution: "bench_press", exerciseTitleAtExecution: "ベンチプレス"))
            try context.save()
        }
        let context = try Self.openCurrent(url)
        let result = try #require(try context.fetch(FetchDescriptor<StepResult>()).first)
        #expect(result.actualReps == 8 && result.weightKg == 60 && result.done && result.ownerAccountID == owner)
        #expect(result.actualDurationSeconds == nil && result.repsInReserve == nil)
        #expect(result.setTypeRaw == nil && result.setType == .working)
        #expect(result.exerciseIdAtExecution == "bench_press" && result.plannedSetsAtExecution == 3)
        #expect(try context.fetchCount(FetchDescriptor<Session>()) == 1)
    }
}
