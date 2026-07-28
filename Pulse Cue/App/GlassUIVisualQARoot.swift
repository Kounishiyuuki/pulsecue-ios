#if DEBUG
import SwiftData
import SwiftUI

/// DEBUG-only launch destinations used for deterministic visual QA.
enum GlassUIVisualQARoute: String, CaseIterable {
    case myGymActive = "mygym-active"
    case machineSelection = "machine-selection"
    case planner
    case previewSingle = "preview-single"
    case previewWeekly = "preview-weekly"
    case historyPopulated = "history-populated"
    case historyDetail = "history-detail"
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
            case .myGymActive:
                MyGymHomeView()
            case .machineSelection:
                ManualMachineSelectionView(gym: gym)
            case .planner:
                TargetBodyPartSelectionView(gym: gym)
            case .previewSingle:
                GeneratedPlanPreviewView(gym: gym, bodyPart: .chest)
            case .previewWeekly:
                WeeklyTrainingPlanCandidateReviewView(
                    debugCandidate: GlassUIVisualQAFixture.weeklyCandidate,
                    debugRequest: GlassUIVisualQAFixture.weeklyRequest
                )
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

enum GlassUIVisualQAFixture {
    static let gymID = UUID(uuidString: "B134D9F0-25D8-4AA7-A5B9-1FE6DAB54E10")!
    static let featuredSessionID = UUID(uuidString: "B134D9F0-25D8-4AA7-A5B9-1FE6DAB55001")!
    private static let timestamp = Date(timeIntervalSince1970: 1_735_689_600)
    private static let routineID = UUID(uuidString: "B134D9F0-25D8-4AA7-A5B9-1FE6DAB54001")!
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
            officialUrl: "https://example.com/pulse-fitness-shibuya",
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
