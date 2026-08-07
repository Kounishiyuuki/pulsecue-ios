#if DEBUG
import SwiftData
import SwiftUI

/// DEBUG-only launch destinations used for deterministic visual QA.
enum GlassUIVisualQARoute: String, CaseIterable {
    case home
    case myGymActive = "mygym-active"
    case myGymEmpty = "mygym-empty"
    case myGymMultiple = "mygym-multiple"
    case machineSelection = "machine-selection"
    case machineSelectionNoneSelected = "machine-selection-none-selected"
    case customMachineAdd = "custom-machine-add"
    case customMachineEdit = "custom-machine-edit"
    case planner
    case quickPlanCondition = "quick-plan-condition"
    case quickPlanPreview = "quick-plan-preview"
    case replacementSheet = "replacement-sheet"
    case replacementSheetEmpty = "replacement-sheet-empty"
    case previewSingle = "preview-single"
    case previewWeeklyBeforeGeneration = "preview-weekly-before-generation"
    case previewWeekly = "preview-weekly"
    case plannerUnavailableTarget = "planner-unavailable-target"
    case exerciseLibrarySearchResults = "exercise-library-search-results"
    case exerciseLibraryNoResults = "exercise-library-no-results"
    case historyPopulated = "history-populated"
    case historyDetail = "history-detail"
    case runnerActive = "runner-active"
    case runnerActiveLaterSet = "runner-active-later-set"
    case runnerRest = "runner-rest"
    case routineSelection = "routine-selection"
    case routineDetail = "routine-detail"
    case daylogSleepInput = "daylog-sleep-input"
    case daylogWeightInput = "daylog-weight-input"
    case exerciseLibrary = "exercise-library"
    case formGuide = "form-guide"
    case formGuideInstructionsExpanded = "form-guide-instructions-expanded"
    case onboarding
    case login
}

/// An isolated root that seeds only its in-memory container. It never reaches
/// `ContentView`, production sample seeding, or a network path, and the route
/// itself has no UserDefaults dependency.
struct GlassUIVisualQARoot: View {
    let route: GlassUIVisualQARoute

    @Environment(\.modelContext) private var modelContext
    @Query private var gyms: [Gym]
    @Query private var sessions: [Session]
    @State private var seedingFailed = false

    var body: some View {
        Group {
            if let gym = gyms.first(where: { $0.id == GlassUIVisualQAFixture.gymID }) {
                destination(gym: gym)
            } else if seedingFailed {
                ContentUnavailableView(
                    "Visual QA fixture unavailable",
                    systemImage: "exclamationmark.triangle"
                )
            } else {
                ProgressView("Visual QA fixtureを準備中…")
            }
        }
        .task {
            guard gyms.isEmpty else { return }
            do {
                try GlassUIVisualQAFixture.seed(into: modelContext)
            } catch {
                seedingFailed = true
            }
        }
    }

    @ViewBuilder
    private func destination(gym: Gym) -> some View {
        NavigationStack {
            switch route {
            case .home:
                ScreenshotHomeHost(modelContext: modelContext)
            case .myGymActive:
                MyGymHomeView()
            case .myGymEmpty:
                ScreenshotGymHost(mode: .empty)
            case .myGymMultiple:
                ScreenshotGymHost(mode: .multiple)
            case .machineSelectionNoneSelected:
                ScreenshotGymHost(mode: .noneSelected)
            case .customMachineAdd:
                ScreenshotGymHost(mode: .customAdd)
            case .customMachineEdit:
                ScreenshotGymHost(mode: .customEdit)
            case .machineSelection:
                ManualMachineSelectionView(gym: gym)
            case .planner:
                TargetBodyPartSelectionView(gym: gym)
            case .quickPlanCondition:
                QuickPlanConditionView(gym: gym)
            case .quickPlanPreview:
                GeneratedPlanPreviewView(
                    gym: gym,
                    request: QuickPlanRequest(
                        bodyParts: [.chest, .back],
                        duration: .standardPlus,
                        intensity: .standard
                    )
                )
            case .replacementSheet:
                ExerciseReplacementSheet(
                    originalName: "ベンチプレス",
                    originalMachineId: "bench_press",
                    candidates: WorkoutPlanGenerator.alternatives(
                        toMachineId: "bench_press",
                        bodyParts: [.chest],
                        usableEquipment: ["chest_press", "pec_deck", "incline_chest_press", "cable_machine"]
                            .compactMap { MachineCatalog.entry(for: $0) }
                            .map { AvailableEquipment(entry: $0) }
                    ),
                    onSelect: { _ in }
                )
            case .replacementSheetEmpty:
                ExerciseReplacementSheet(
                    originalName: "ベンチプレス",
                    originalMachineId: "bench_press",
                    candidates: [],
                    onSelect: { _ in }
                )
            case .previewSingle:
                GeneratedPlanPreviewView(gym: gym, bodyPart: .chest)
            case .previewWeeklyBeforeGeneration:
                WeeklyTrainingPlanCandidateReviewView()
            case .previewWeekly:
                WeeklyTrainingPlanCandidateReviewView(
                    debugCandidate: GlassUIVisualQAFixture.weeklyCandidate,
                    debugRequest: GlassUIVisualQAFixture.weeklyRequest
                )
            case .plannerUnavailableTarget:
                WeeklyTrainingPlanCandidateReviewView(
                    debugEquipmentNotice: WeeklyPlanEquipmentProvider.needsActiveGymMessage
                )
            case .exerciseLibrarySearchResults:
                ExerciseLibraryView(debugInitialSearch: "プレス")
            case .exerciseLibraryNoResults:
                ExerciseLibraryView(debugInitialSearch: "スイム")
            case .historyPopulated:
                HistoryView()
            case .historyDetail:
                if let session = sessions.first(where: {
                    $0.id == GlassUIVisualQAFixture.featuredSessionID
                }) {
                    SessionDetailView(session: session)
                } else {
                    ContentUnavailableView(
                        "Visual QA session unavailable",
                        systemImage: "exclamationmark.triangle"
                    )
                }
            case .runnerActive:
                ScreenshotRunnerHost(modelContext: modelContext, target: .exercise)
            case .runnerActiveLaterSet:
                ScreenshotRunnerHost(modelContext: modelContext, target: .laterSet)
            case .runnerRest:
                ScreenshotRunnerHost(modelContext: modelContext, target: .rest)
            case .routineSelection:
                ScreenshotRoutineSelectionHost(modelContext: modelContext)
            case .routineDetail:
                ScreenshotRoutineDetailHost()
            case .daylogSleepInput:
                ScreenshotDayLogInputHost(field: .sleep)
            case .daylogWeightInput:
                ScreenshotDayLogInputHost(field: .weight)
            case .exerciseLibrary:
                ExerciseLibraryView()
            case .formGuide:
                ExerciseGuideView(
                    exerciseId: "machine_chest_press",
                    debugStaticProgress: 0.35
                )
            case .formGuideInstructionsExpanded:
                ExerciseGuideView(
                    exerciseId: "machine_chest_press",
                    debugStaticProgress: 0.35,
                    debugInstructionsExpanded: true
                )
            case .onboarding:
                OnboardingView(onPrimary: {})
            case .login:
                LoginView(authSession: AuthSessionStore())
            }
        }
    }
}

/// DEBUG-only hosts for deterministic routine selection/detail layout checks.
/// They use the shared in-memory fixture and an isolated settings suite.
private struct ScreenshotRoutineSelectionHost: View {
    @StateObject private var settings: SettingsStore
    @StateObject private var runnerViewModel: RunnerViewModel

    init(modelContext: ModelContext) {
        let ephemeral = makeScreenshotSettings()
        _settings = StateObject(wrappedValue: ephemeral)
        let runner = RunnerViewModel(settings: ephemeral)
        runner.configure(modelContext: modelContext)
        _runnerViewModel = StateObject(wrappedValue: runner)
    }

    var body: some View {
        WorkoutView()
            .environmentObject(settings)
            .environmentObject(runnerViewModel)
    }
}

private struct ScreenshotRoutineDetailHost: View {
    @Query private var routines: [Routine]
    @StateObject private var settings = makeScreenshotSettings()

    var body: some View {
        if let routine = routines.first(where: { $0.id == GlassUIVisualQAFixture.routineID }) {
            RoutineEditorView(routine: routine, onStart: { _ in })
                .environmentObject(settings)
        } else {
            ProgressView("ルーティンを準備中…")
        }
    }
}

/// DEBUG-only host that renders the keyboard-free sleep/weight quick-input
/// sheet over an isolated in-memory `DayLog` seeded with a representative value
/// (7h17m / 72.5 kg), so the wheels and the "記録を削除" affordance are visible.
private struct ScreenshotDayLogInputHost: View {
    let field: DayLogField
    @State private var container: ModelContainer

    init(field: DayLogField) {
        self.field = field
        let built = try! ModelContainer(
            for: DayLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let log = DayLog(
            date: Date(timeIntervalSince1970: 1_735_689_600),
            sleepMinutes: 437,
            weightKg: 72.5
        )
        built.mainContext.insert(log)
        _container = State(initialValue: built)
    }

    var body: some View {
        content.modelContainer(container)
    }

    @ViewBuilder
    private var content: some View {
        if let log = try? container.mainContext.fetch(FetchDescriptor<DayLog>()).first {
            DayLogQuickInputSheet(field: field, dayLog: log)
        } else {
            ProgressView("準備中…")
        }
    }
}

/// DEBUG-only host that drives a `RunnerViewModel` into a deterministic
/// ACTIVE (exercise) or REST state for App Store screenshots, using the seeded
/// fixture routine. It uses ONLY the existing public Runner API — it does not
/// change the Runner state machine. Storage is the isolated in-memory QA
/// context; settings use an ephemeral, throwaway UserDefaults suite so the
/// user's real preferences are never read or written. `start()` is
/// authoritative, so the shown state does not depend on any restored session.
/// Fixed, throwaway UserDefaults suite for screenshot hosts. A *fixed* name
/// (not per-UUID) is reused across launches, so it can never accumulate an
/// unbounded number of orphan preference files. It is never `.standard`, so
/// the user's real preferences are untouched. The capture script also clears
/// this domain after a run (see Docs/app-store-screenshot-plan.md).
private let screenshotDefaultsSuite = "com.pulsecue.screenshot-visualqa"

private func makeScreenshotSettings() -> SettingsStore {
    let store = SettingsStore(defaults: UserDefaults(suiteName: screenshotDefaultsSuite)!)
    store.notificationsEnabled = false
    return store
}

private struct ScreenshotRunnerHost: View {
    enum Target { case exercise, rest, laterSet }

    let modelContext: ModelContext
    let target: Target
    @StateObject private var settings: SettingsStore
    @StateObject private var runnerViewModel: RunnerViewModel
    @State private var started = false

    init(modelContext: ModelContext, target: Target) {
        self.modelContext = modelContext
        self.target = target
        let ephemeral = makeScreenshotSettings()
        _settings = StateObject(wrappedValue: ephemeral)
        _runnerViewModel = StateObject(wrappedValue: RunnerViewModel(settings: ephemeral))
    }

    var body: some View {
        RunnerView()
            .environmentObject(runnerViewModel)
            .environmentObject(settings)
            .task {
                guard !started else { return }
                started = true
                runnerViewModel.configure(modelContext: modelContext)
                let routineID = GlassUIVisualQAFixture.routineID
                let descriptor = FetchDescriptor<Routine>(
                    predicate: #Predicate { $0.id == routineID }
                )
                guard let routine = try? modelContext.fetch(descriptor).first else { return }
                // Phase-bound public API only — no state-machine change.
                // ACTIVE first set = exercise phase (static, no ticking timer).
                // REST = one Complete → rest hero. LATER SET = Complete (record
                // set 1 → rest) then Complete (finish rest → set 2 exercise),
                // yielding a static exercise phase advanced past the first set.
                runnerViewModel.start(routine: routine)
                switch target {
                case .exercise:
                    break
                case .rest:
                    if let context = runnerViewModel.completeContext {
                        runnerViewModel.handle(action: .complete, context: context)
                    }
                case .laterSet:
                    if let exerciseContext = runnerViewModel.completeContext {
                        runnerViewModel.handle(action: .complete, context: exerciseContext)
                    }
                    if let restContext = runnerViewModel.completeContext {
                        runnerViewModel.handle(action: .complete, context: restContext)
                    }
                }
            }
    }
}

/// DEBUG-only host for the App Store **Home** screenshot. Renders the real
/// production `TodayView` over the seeded fixture (active gym
/// "Pulse Fitness 渋谷" with machines), so the image shows a polished,
/// truthful current-main Home — never the UI-test "UIテストジム" empty state.
/// No production Home logic is changed; only presentation env is provided.
private struct ScreenshotHomeHost: View {
    let modelContext: ModelContext
    @StateObject private var settings: SettingsStore
    @StateObject private var runnerViewModel: RunnerViewModel

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        let ephemeral = makeScreenshotSettings()
        _settings = StateObject(wrappedValue: ephemeral)
        _runnerViewModel = StateObject(wrappedValue: RunnerViewModel(settings: ephemeral))
    }

    var body: some View {
        TodayView(onResumeRunner: {})
            .environmentObject(runnerViewModel)
            .environmentObject(settings)
    }
}

/// DEBUG-only host for the My Gym / machine / Custom Machine inventory states.
/// Builds its OWN isolated in-memory container per mode and renders the real
/// production views — no production store write, no `UserDefaults.standard`.
private struct ScreenshotGymHost: View {
    let mode: GlassUIVisualQAFixture.GymInventoryMode
    @State private var container: ModelContainer

    init(mode: GlassUIVisualQAFixture.GymInventoryMode) {
        self.mode = mode
        let schema = Schema(versionedSchema: PulseCueSchemaV4.self)
        let built = try! ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        GlassUIVisualQAFixture.seedGymInventory(mode: mode, into: built.mainContext)
        _container = State(initialValue: built)
    }

    var body: some View {
        content.modelContainer(container)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .empty, .multiple:
            MyGymHomeView()
        case .noneSelected:
            if let gym = firstGym {
                ManualMachineSelectionView(gym: gym)
            } else {
                unavailable
            }
        case .customAdd:
            if let gym = firstGym {
                CustomMachineFormView(gym: gym)
            } else {
                unavailable
            }
        case .customEdit:
            if let gym = firstGym, let machine = firstCustomMachine {
                CustomMachineFormView(gym: gym, editing: machine)
            } else {
                unavailable
            }
        }
    }

    private var unavailable: some View {
        ContentUnavailableView("Inventory fixture unavailable", systemImage: "exclamationmark.triangle")
    }

    private var firstGym: Gym? {
        try? container.mainContext.fetch(FetchDescriptor<Gym>()).first
    }
    private var firstCustomMachine: CustomMachine? {
        try? container.mainContext.fetch(FetchDescriptor<CustomMachine>()).first
    }
}

enum GlassUIVisualQAFixture {
    static let gymID = UUID(uuidString: "B134D9F0-25D8-4AA7-A5B9-1FE6DAB54E10")!
    static let featuredSessionID = UUID(uuidString: "B134D9F0-25D8-4AA7-A5B9-1FE6DAB55001")!
    private static let timestamp = Date(timeIntervalSince1970: 1_735_689_600)
    /// Exposed (not private) so the DEBUG screenshot Runner host can start the
    /// seeded routine deterministically.
    static let routineID = UUID(uuidString: "B134D9F0-25D8-4AA7-A5B9-1FE6DAB54001")!
    private static let stepIDs = [
        UUID(uuidString: "B134D9F0-25D8-4AA7-A5B9-1FE6DAB54101")!,
        UUID(uuidString: "B134D9F0-25D8-4AA7-A5B9-1FE6DAB54102")!,
        UUID(uuidString: "B134D9F0-25D8-4AA7-A5B9-1FE6DAB54103")!,
    ]
    private static let sessionIDs = [
        featuredSessionID,
        UUID(uuidString: "B134D9F0-25D8-4AA7-A5B9-1FE6DAB55002")!,
        UUID(uuidString: "B134D9F0-25D8-4AA7-A5B9-1FE6DAB55003")!,
    ]

    /// Seeds real catalog entries in catalog order with stable model IDs.
    /// The selected set spans every planner category and includes several
    /// chest entries, guaranteeing a non-empty single-workout preview.
    static let machineIDs = [
        "chest_press",
        "incline_chest_press",
        "pec_deck",
        "lat_pulldown",
        "seated_row",
        "shoulder_press",
        "arm_curl_machine",
        "leg_press",
        "leg_curl",
        "abdominal_machine",
        "treadmill",
    ]

    /// The request that produces `weeklyCandidate`. Kept as the single source
    /// of truth so the DEBUG review screen can seed its input controls to match
    /// the shown candidate (no input/candidate mismatch).
    static let weeklyRequest = TrainingPlanGenerationRequest(
        goal: .hypertrophy,
        daysPerWeek: 3,
        targetBodyParts: [.chest, .back, .legs],
        experienceLevel: .intermediate,
        preferredSplit: .upperLower
    )

    static let weeklyCandidate = RuleBasedWeeklyPlanGenerator.generate(
        request: weeklyRequest
    )

    @MainActor
    static func seed(into context: ModelContext) throws {
        let gym = Gym(
            id: gymID,
            name: "Pulse Fitness 渋谷",
            officialUrl: nil,
            isActive: true,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        context.insert(gym)

        for (index, machineID) in machineIDs.enumerated() {
            guard let entry = MachineCatalog.entry(for: machineID) else {
                assertionFailure("Unknown visual QA machine: \(machineID)")
                continue
            }
            context.insert(
                GymMachine(
                    id: stableMachineID(index: index),
                    gymId: gymID,
                    machineId: entry.id,
                    displayName: entry.displayName,
                    isAvailable: true,
                    addedAt: timestamp
                )
            )
        }

        let routine = Routine(
            id: routineID,
            name: "上半身プッシュ",
            createdAt: timestamp.addingTimeInterval(-14 * 86_400),
            updatedAt: timestamp,
            isPinned: true
        )
        context.insert(routine)

        let steps = [
            Step(
                id: stepIDs[0],
                routineId: routineID,
                order: 0,
                title: "チェストプレス",
                sets: 3,
                repsTarget: 10,
                restSeconds: 90,
                exerciseId: "machine_chest_press"
            ),
            Step(
                id: stepIDs[1],
                routineId: routineID,
                order: 1,
                title: "ショルダープレス",
                sets: 3,
                repsTarget: 10,
                restSeconds: 90,
                exerciseId: "machine_shoulder_press"
            ),
            Step(
                id: stepIDs[2],
                routineId: routineID,
                order: 2,
                title: "ペックデック",
                sets: 2,
                repsTarget: 12,
                restSeconds: 60,
                exerciseId: "machine_pec_deck"
            ),
        ]
        steps.forEach(context.insert)

        let sessions = [
            Session(
                id: sessionIDs[0],
                routineId: routineID,
                dayDate: timestamp,
                startedAt: timestamp.addingTimeInterval(18 * 3_600),
                endedAt: timestamp.addingTimeInterval(18 * 3_600 + 3_180),
                status: .completed,
                totalSeconds: 3_180
            ),
            Session(
                id: sessionIDs[1],
                routineId: routineID,
                dayDate: timestamp.addingTimeInterval(-3 * 86_400),
                startedAt: timestamp.addingTimeInterval(-3 * 86_400 + 18 * 3_600),
                endedAt: timestamp.addingTimeInterval(-3 * 86_400 + 18 * 3_600 + 2_940),
                status: .completed,
                totalSeconds: 2_940
            ),
            Session(
                id: sessionIDs[2],
                routineId: routineID,
                dayDate: timestamp.addingTimeInterval(-7 * 86_400),
                startedAt: timestamp.addingTimeInterval(-7 * 86_400 + 18 * 3_600),
                endedAt: timestamp.addingTimeInterval(-7 * 86_400 + 18 * 3_600 + 2_760),
                status: .completed,
                totalSeconds: 2_760
            ),
        ]
        sessions.forEach(context.insert)

        for (sessionIndex, session) in sessions.enumerated() {
            for (stepIndex, step) in steps.enumerated() {
                for setIndex in 0..<step.sets {
                    context.insert(
                        StepResult(
                            id: stableResultID(
                                sessionIndex: sessionIndex,
                                stepIndex: stepIndex,
                                setIndex: setIndex
                            ),
                            sessionId: session.id,
                            stepId: step.id,
                            setIndex: setIndex,
                            done: true,
                            actualReps: step.repsTarget - min(sessionIndex, 1)
                        )
                    )
                }
            }
        }
        try context.save()
    }

    private static func stableMachineID(index: Int) -> UUID {
        UUID(uuidString: String(format: "B134D9F0-25D8-4AA7-A5B9-%012X", index + 1))!
    }

    // MARK: - My Gym inventory (Slice 3)

    static let secondGymID = UUID(uuidString: "B134D9F0-25D8-4AA7-A5B9-1FE6DAB54E20")!
    static let customMachineID = UUID(uuidString: "B134D9F0-25D8-4AA7-A5B9-1FE6DAB54E30")!

    enum GymInventoryMode { case empty, multiple, noneSelected, customAdd, customEdit }

    /// Seeds deterministic Gym / GymMachine / CustomMachine data for the My Gym
    /// inventory routes. All gyms use `officialUrl == nil` (no example.com).
    /// In-memory only; the caller provides an isolated container's context.
    @MainActor
    static func seedGymInventory(mode: GymInventoryMode, into context: ModelContext) {
        func makeGym(_ id: UUID, _ name: String, active: Bool) -> Gym {
            Gym(id: id, name: name, officialUrl: nil, isActive: active,
                createdAt: timestamp, updatedAt: timestamp)
        }
        func addMachines(_ gymId: UUID, count: Int, indexOffset: Int) {
            for (i, machineID) in machineIDs.prefix(count).enumerated() {
                guard let entry = MachineCatalog.entry(for: machineID) else { continue }
                context.insert(GymMachine(
                    id: stableMachineID(index: indexOffset + i),
                    gymId: gymId, machineId: entry.id, displayName: entry.displayName,
                    isAvailable: true, addedAt: timestamp
                ))
            }
        }
        switch mode {
        case .empty:
            break
        case .multiple:
            context.insert(makeGym(gymID, "Pulse Fitness 渋谷", active: true))
            addMachines(gymID, count: 11, indexOffset: 0)
            context.insert(makeGym(secondGymID, "Central Training Lab", active: false))
            addMachines(secondGymID, count: 6, indexOffset: 100)
        case .noneSelected:
            context.insert(makeGym(gymID, "Pulse Fitness 渋谷", active: true))
        case .customAdd:
            context.insert(makeGym(gymID, "Pulse Fitness 渋谷", active: true))
        case .customEdit:
            context.insert(makeGym(gymID, "Pulse Fitness 渋谷", active: true))
            context.insert(CustomMachine(
                id: customMachineID, gymId: gymID, displayName: "ケーブルロー",
                bodyParts: [BodyPart.back.rawValue],
                equipmentType: EquipmentType.cable.rawValue,
                notes: "フォーム確認用", isAvailable: true,
                createdAt: timestamp, updatedAt: timestamp
            ))
        }
        try? context.save()
    }

    private static func stableResultID(
        sessionIndex: Int,
        stepIndex: Int,
        setIndex: Int
    ) -> UUID {
        let suffix = 0x5600 + sessionIndex * 0x100 + stepIndex * 0x10 + setIndex
        return UUID(
            uuidString: String(format: "B134D9F0-25D8-4AA7-A5B9-%012X", suffix)
        )!
    }
}
#endif
