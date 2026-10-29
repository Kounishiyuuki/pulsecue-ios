#if DEBUG
import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

// Serialized so the many in-memory `ModelContainer` fixtures aren't all built
// concurrently (parallel SwiftData container creation is flaky under the test
// runner). Test-only; does not affect app behavior.
@Suite(.serialized)
@MainActor
struct GlassUIVisualQARouteTests {
    private let argument = "-pulsecue-debug-glass-ui-route"

    @Test func routeIsAbsentWithoutExactArgumentAndValue() {
        #expect(PulseCueUITestSupport.requestedGlassUIRoute([]) == nil)
        #expect(PulseCueUITestSupport.requestedGlassUIRoute([argument]) == nil)
        #expect(PulseCueUITestSupport.requestedGlassUIRoute(["preview-single"]) == nil)
    }

    @Test func everyRepresentativeRouteParsesDeterministically() {
        #expect(Set(GlassUIVisualQARoute.allCases.map(\.rawValue)) == [
            "home",
            "progress",
            "nutrition",
            "mygym-active",
            "mygym-empty",
            "mygym-multiple",
            "machine-selection",
            "machine-selection-none-selected",
            "custom-machine-add",
            "custom-machine-edit",
            "planner",
            "quick-plan-condition",
            "quick-plan-preview",
            "replacement-sheet",
            "replacement-sheet-empty",
            "preview-single",
            "preview-weekly-before-generation",
            "preview-weekly",
            "planner-unavailable-target",
            "exercise-library-search-results",
            "exercise-library-no-results",
            "history-populated",
            "history-detail",
            "runner-active",
            "runner-active-previous-performance",
            "runner-active-later-set",
            "runner-rest",
            "workout-completion",
            "workout-completion-skipped",
            "routine-selection",
            "routine-detail",
            "daylog-sleep-input",
            "daylog-weight-input",
            "exercise-library",
            "form-guide",
            "form-guide-instructions-expanded",
            "onboarding",
            "first-launch-waiting",
            "login",
        ])
        for route in GlassUIVisualQARoute.allCases {
            let args = ["Pulse Cue", argument, route.rawValue]
            #expect(PulseCueUITestSupport.requestedGlassUIRoute(args) == route)
            #expect(PulseCueUITestSupport.requestedGlassUIRoute(args) == route)
        }
    }

    @Test func unknownAndEmptyValuesDoNotForkStartup() {
        #expect(PulseCueUITestSupport.requestedGlassUIRoute([argument, ""]) == nil)
        #expect(PulseCueUITestSupport.requestedGlassUIRoute([argument, "unknown"]) == nil)
    }

    @Test func isolatedRouteWinsWithoutCustomMachineOnboardingWrite() {
        let combined = [
            "-pulsecue-ui-test-custom-machine-flow",
            argument,
            GlassUIVisualQARoute.myGymActive.rawValue,
        ]
        #expect(PulseCueUITestSupport.requestedGlassUIRoute(combined) == .myGymActive)
        #expect(!PulseCueUITestSupport.shouldCompleteCustomMachineOnboarding(combined))
        #expect(PulseCueUITestSupport.shouldCompleteCustomMachineOnboarding([
            "-pulsecue-ui-test-custom-machine-flow",
        ]))
    }

    @Test func fixtureUsesRealCatalogEntriesIncludingChestEquipment() {
        let entries = GlassUIVisualQAFixture.machineIDs.compactMap(MachineCatalog.entry(for:))
        #expect(entries.count == GlassUIVisualQAFixture.machineIDs.count)
        #expect(entries.contains { $0.bodyParts.contains(.chest) })
    }

    @Test func historyFixtureHasStableConnectedRecords() throws {
        let schema = Schema(versionedSchema: PulseCueSchemaV6.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        try GlassUIVisualQAFixture.seed(into: context)

        let routines = try context.fetch(FetchDescriptor<Routine>())
        let steps = try context.fetch(FetchDescriptor<Step>())
        let sessions = try context.fetch(FetchDescriptor<Session>())
        let results = try context.fetch(FetchDescriptor<StepResult>())

        #expect(routines.count == 1)
        #expect(steps.count == 3)
        #expect(sessions.count == 3)
        #expect(results.count == 24)
        #expect(sessions.contains { $0.id == GlassUIVisualQAFixture.featuredSessionID })

        let routineIDs = Set(routines.map(\.id))
        let sessionIDs = Set(sessions.map(\.id))
        let stepIDs = Set(steps.map(\.id))
        #expect(steps.allSatisfy { routineIDs.contains($0.routineId) })
        #expect(sessions.allSatisfy { routineIDs.contains($0.routineId) })
        #expect(results.allSatisfy {
            sessionIDs.contains($0.sessionId) && stepIDs.contains($0.stepId)
        })
    }

    /// Returns a retained in-memory container (the caller MUST keep it alive —
    /// `mainContext` dangles if the container deallocates).
    private func inventoryContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: PulseCueSchemaV6.self)
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
    }

    @Test func screenshotGymFixturesHaveNoExampleComAndNilURL() throws {
        // The shared fixture gym must not expose example.com in any screenshot.
        let container = try inventoryContainer()
        let context = container.mainContext
        try GlassUIVisualQAFixture.seed(into: context)
        for gym in try context.fetch(FetchDescriptor<Gym>()) {
            #expect(gym.officialUrl == nil)
        }
    }

    @Test func emptyGymInventoryModeSeedsNoGym() throws {
        let container = try inventoryContainer()
        let context = container.mainContext
        GlassUIVisualQAFixture.seedGymInventory(mode: .empty, into: context)
        #expect(try context.fetch(FetchDescriptor<Gym>()).isEmpty)
    }

    @Test func multipleGymInventoryModeIsDeterministic() throws {
        let container = try inventoryContainer()
        let context = container.mainContext
        GlassUIVisualQAFixture.seedGymInventory(mode: .multiple, into: context)
        let gyms = try context.fetch(FetchDescriptor<Gym>())
        #expect(gyms.count == 2)
        #expect(gyms.allSatisfy { $0.officialUrl == nil })
        #expect(gyms.contains { $0.name == "Pulse Fitness 渋谷" && $0.isActive })
        #expect(gyms.contains { $0.name == "Central Training Lab" && !$0.isActive })
        #expect(gyms.allSatisfy { !$0.name.contains("UIテスト") && !$0.name.contains("テスト用") })
    }

    @Test func noneSelectedInventoryModeHasGymWithoutMachines() throws {
        let container = try inventoryContainer()
        let context = container.mainContext
        GlassUIVisualQAFixture.seedGymInventory(mode: .noneSelected, into: context)
        #expect(try context.fetch(FetchDescriptor<Gym>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<GymMachine>()).isEmpty)
    }

    @Test func customEditInventoryModeSeedsPopulatedCustomMachine() throws {
        let container = try inventoryContainer()
        let context = container.mainContext
        GlassUIVisualQAFixture.seedGymInventory(mode: .customEdit, into: context)
        let machine = try #require(try context.fetch(FetchDescriptor<CustomMachine>()).first)
        #expect(machine.displayName == "ケーブルロー")
        #expect(machine.bodyParts == [BodyPart.back.rawValue])
        #expect(machine.equipmentType == EquipmentType.cable.rawValue)
        #expect(machine.notes == "フォーム確認用")
    }

    @Test func exerciseLibrarySearchFixtureQueriesAreMeaningful() {
        // The library lists only guided exercises. The inventory search route
        // "プレス" must match ≥1, and the no-results route "スイム" must match 0,
        // using the real current catalog (no fixture rows fabricated).
        let guided = ExerciseLibrary.all.filter { FormGuideLibrary.hasGuide(for: $0.id) }
        #expect(guided.contains { $0.displayName.contains("プレス") })
        #expect(!guided.contains { $0.displayName.contains("スイム") })
    }

    @Test func formGuideSupportMappingIsUnchanged() {
        // Every guided exercise has a 3D motion profile in current main, so
        // there is no "guide without 3D" (unsupported) state to capture. This
        // pins that mapping so a regression would be caught.
        let guidedIDs = Set(ExerciseLibrary.all.map(\.id).filter { FormGuideLibrary.hasGuide(for: $0) })
        for id in guidedIDs {
            #expect(ExerciseMotionLibrary.hasProfile(for: id))
        }
        #expect(guidedIDs.count == 10)
    }

    @Test func weeklyPreviewFixtureIsGeneratedAndNonEmpty() {
        let candidate = GlassUIVisualQAFixture.weeklyCandidate
        #expect(candidate.daysPerWeek == 3)
        #expect(candidate.sessions.count == 3)
        #expect(!candidate.isEmpty)
    }

    /// The Home screenshot route renders `TodayView` over this fixture. It must
    /// present a polished, active gym with machines — never the UI-test
    /// "UIテストジム" empty-machine state that the review rejected.
    @Test func homeScreenshotFixtureUsesPolishedActiveGymWithMachines() throws {
        let schema = Schema(versionedSchema: PulseCueSchemaV6.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        try GlassUIVisualQAFixture.seed(into: context)

        let gyms = try context.fetch(FetchDescriptor<Gym>())
        #expect(gyms.count == 1)
        let gym = try #require(gyms.first)
        #expect(gym.name == "Pulse Fitness 渋谷")
        #expect(gym.name != "UIテストジム")
        #expect(gym.isActive)

        let gymID = gym.id
        let machines = try context.fetch(FetchDescriptor<GymMachine>(
            predicate: #Predicate { $0.gymId == gymID }
        ))
        #expect(machines.count == GlassUIVisualQAFixture.machineIDs.count)
        #expect(machines.count > 0)
    }

    /// Drives a RunnerViewModel exactly like the DEBUG screenshot host so the
    /// runner-active / runner-rest routes are deterministic from the fixture.
    /// Uses only the existing public Runner API (no state-machine change).
    @Test func screenshotRunnerRoutesAreDeterministicFromFixture() throws {
        let schema = Schema(versionedSchema: PulseCueSchemaV6.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        try GlassUIVisualQAFixture.seed(into: context)

        let routineID = GlassUIVisualQAFixture.routineID
        let routine = try #require(
            context.fetch(FetchDescriptor<Routine>(
                predicate: #Predicate { $0.id == routineID }
            )).first
        )

        RunnerPersistence.clear()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.screenshot.runner.\(UUID().uuidString)")!)
        settings.notificationsEnabled = false
        let vm = RunnerViewModel(settings: settings)
        vm.configure(modelContext: context)

        // ACTIVE (exercise phase) — first step, first set, static.
        vm.start(routine: routine)
        #expect(vm.phase == .exercise)
        #expect(vm.isRunning)
        #expect(vm.currentStep?.title == "チェストプレス")
        #expect(vm.currentSetIndex == 0)

        // REST — one Complete enters the rest hero.
        let exerciseContext = try #require(vm.completeContext)
        vm.handle(action: .complete, context: exerciseContext)
        #expect(vm.phase == .rest)
        #expect(vm.isRunning)
    }

    /// LATER SET: phase-bound Completes (record set 1 → rest → finish rest) land on a
    /// static exercise phase advanced past the first set — visually distinct
    /// from `runner-active`. Uses only the public Runner API.
    @Test func screenshotRunnerLaterSetIsDeterministicAndAdvanced() throws {
        let schema = Schema(versionedSchema: PulseCueSchemaV6.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        try GlassUIVisualQAFixture.seed(into: context)
        let routineID = GlassUIVisualQAFixture.routineID
        let routine = try #require(
            context.fetch(FetchDescriptor<Routine>(predicate: #Predicate { $0.id == routineID })).first
        )

        RunnerPersistence.clear()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.screenshot.later.\(UUID().uuidString)")!)
        settings.notificationsEnabled = false
        let vm = RunnerViewModel(settings: settings)
        vm.configure(modelContext: context)

        vm.start(routine: routine)
        let exerciseContext = try #require(vm.completeContext)
        vm.handle(action: .complete, context: exerciseContext) // set 1 done → rest
        let restContext = try #require(vm.completeContext)
        vm.handle(action: .complete, context: restContext) // finish rest → next set exercise

        #expect(vm.phase == .exercise)
        #expect(vm.isRunning)
        // Advanced past the very first set (later set of same step, or next step).
        #expect(vm.currentSetIndex >= 1 || vm.currentStepIndex >= 1)
    }

    /// The App Store Progress shot must show a non-empty week. Days 0/2/4
    /// share a calendar week whenever "now" is Wednesday or later.
    @Test func sessionsFillTheCurrentWeekFromWednesday() throws {
        let schema = Schema(versionedSchema: PulseCueSchemaV6.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        try GlassUIVisualQAFixture.seed(into: context)

        let sessions = try context.fetch(FetchDescriptor<Session>())
        let calendar = Calendar.current
        #expect(sessions.allSatisfy { $0.startedAt <= Date() })
        #expect(sessions.map { calendar.startOfDay(for: $0.startedAt) }.max() ?? .distantPast
            >= calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))!)

        var friday = Calendar(identifier: .gregorian)
        friday.firstWeekday = 1
        let now = try #require(friday.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 21)))
        let shifted = [0, 2, 4].map { GlassUIVisualQAFixture.sessionStart(daysAgo: $0, now: now) }
        let week = try #require(friday.dateInterval(of: .weekOfYear, for: now))
        #expect(shifted.allSatisfy { week.contains($0) && $0 <= now })
    }

    /// Nutrition shot: three confirmed meals today (1,650 kcal / 110 g) under a
    /// profile-calculated target that leaves a sensible remainder.
    @Test func nutritionFixtureShowsARecordedDayUnderTarget() throws {
        let schema = Schema(versionedSchema: PulseCueSchemaV10.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        try GlassUIVisualQAFixture.seedNutrition(into: context)

        let meals = try context.fetch(FetchDescriptor<MealEntry>())
        let profile = try #require(context.fetch(FetchDescriptor<UserProfile>()).first)
        let log = try #require(context.fetch(FetchDescriptor<DayLog>()).first)
        #expect(meals.count == 3)
        #expect(meals.allSatisfy { $0.status == .confirmed && Calendar.current.isDateInToday($0.dayDate) })
        #expect(meals.allSatisfy { $0.ownerAccountID == nil })

        let summary = DailyNutritionSummary.make(
            dayLog: log,
            mealsForDay: meals,
            manualTargetKcal: nil,
            profileTargetKcal: profile.targetIntake(currentWeightKg: log.weightKg)
        )
        #expect(summary.consumedKcal == 1_650)
        #expect(summary.proteinGrams == 110)
        let target = try #require(summary.targetKcal)
        #expect((1_900...2_600).contains(target))
    }

    /// The weekly shot is generated from the fixture gym's machines only.
    @Test func weeklyPreviewUsesOnlyTheFixtureGymMachines() {
        let gymMachines = Set(GlassUIVisualQAFixture.machineIDs)
        let exercises = GlassUIVisualQAFixture.weeklyCandidate.sessions.flatMap(\.exercises)
        #expect(!exercises.isEmpty)
        #expect(exercises.allSatisfy { gymMachines.contains($0.machineId) })
    }
}
#endif
