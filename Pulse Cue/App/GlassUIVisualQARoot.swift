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
}

/// An isolated root that seeds only its in-memory container. It never reaches
/// `ContentView`, production sample seeding, or a network path, and the route
/// itself has no UserDefaults dependency.
struct GlassUIVisualQARoot: View {
    let route: GlassUIVisualQARoute

    @Environment(\.modelContext) private var modelContext
    @Query private var gyms: [Gym]
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
                WeeklyTrainingPlanCandidateReviewView()
            }
        }
    }
}

enum GlassUIVisualQAFixture {
    static let gymID = UUID(uuidString: "B134D9F0-25D8-4AA7-A5B9-1FE6DAB54E10")!
    private static let timestamp = Date(timeIntervalSince1970: 1_735_689_600)

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
        try context.save()
    }

    private static func stableMachineID(index: Int) -> UUID {
        UUID(uuidString: String(format: "B134D9F0-25D8-4AA7-A5B9-%012X", index + 1))!
    }
}
#endif
