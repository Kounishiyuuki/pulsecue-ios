//
//  Pulse_CueApp.swift
//  Pulse Cue
//
//  Created by yuuki kounishi on 2026/02/06.
//

import SwiftUI
import UIKit
import SwiftData
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

@main
struct Pulse_CueApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var runnerViewModel: RunnerViewModel
    // Local auth *shell* state (PR #112). Provided so future PRs (Login/Register
    // UI, Apple, Google) have a ready place to read account state. It does not
    // gate any existing feature and persists nothing.
    @StateObject private var authSession = AuthSessionStore()
    // The PulseCue *server* account, which is a different thing from the local
    // provider link above. With no API base URL configured — the shipped state
    // today — this sits in `.notConfigured` and touches nothing: Guest and
    // every local feature behave exactly as before.
    @StateObject private var serverAccount = ServerAccountStore(
        api: PulseCueAccountAPIClient(configuration: .fromMainBundle()),
        tokenStore: KeychainServerSessionTokenStore(),
        deviceName: UIDevice.current.name
    )

    var sharedModelContainer: ModelContainer = {
        // In-memory (never opening the user's persistent V4 store) for the
        // deterministic UI-test / QA fixtures. These are ALL DEBUG-only launch
        // arguments: Release never honours them, so a production build always
        // opens the real persistent store regardless of any argument.
        var inMemory = false
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(PulseCueUITestSupport.customMachineFlowArgument)
            || ProcessInfo.processInfo.arguments.contains(PulseCueUITestSupport.completionFlowArgument)
            || PulseCueUITestSupport.isFormGuideDebugRoute()
            || PulseCueUITestSupport.requestedGlassUIRoute() != nil {
            inMemory = true
        }
        #endif
        let modelConfiguration = ModelConfiguration(
            schema: Schema(versionedSchema: PulseCueSchemaV5.self),
            isStoredInMemoryOnly: inMemory
        )

        do {
            return try ModelContainer(
                for: Schema(versionedSchema: PulseCueSchemaV5.self),
                migrationPlan: PulseCueMigrationPlan.self,
                configurations: modelConfiguration
            )
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        let settings = SettingsStore()
        if PulseCueUITestSupport.shouldCompleteCustomMachineOnboarding() {
            // Custom-machine UI fixture skips onboarding. The Form Guide debug
            // route does NOT write onboarding — it uses a separate root.
            settings.completeOnboarding()
        }
        _settings = StateObject(wrappedValue: settings)
        _runnerViewModel = StateObject(wrappedValue: RunnerViewModel(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .onOpenURL { url in
                    // GoogleSignIn URL callback only. No other app flow uses
                    // custom URL schemes, so this is scoped to the SDK.
                    handleOpenURL(url)
                }
        }
        .modelContainer(sharedModelContainer)
    }

    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
        if let route = PulseCueUITestSupport.requestedGlassUIRoute() {
            GlassUIVisualQARoot(route: route)
        } else if let exerciseId = PulseCueUITestSupport.requestedFormGuideExerciseId() {
            // Isolated debug root: no ContentView, no SampleDataSeeder, no
            // onboarding, in-memory store only.
            FormGuide3DDebugRoot(
                exerciseId: exerciseId,
                staticProgress: PulseCueUITestSupport.requestedFormGuideProgress()
            )
        } else {
            normalRoot
        }
        #else
        normalRoot
        #endif
    }

    private var normalRoot: some View {
        ContentView()
            .environmentObject(settings)
            .environmentObject(runnerViewModel)
            .environmentObject(authSession)
            .environmentObject(serverAccount)
    }

    /// Routes incoming URLs to GoogleSignIn only. Returns immediately when the
    /// SDK is unavailable, so the app builds and runs without it.
    private func handleOpenURL(_ url: URL) {
        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.handle(url)
        #endif
    }
}

enum PulseCueUITestSupport {
    static let customMachineFlowArgument = "-pulsecue-ui-test-custom-machine-flow"
    /// Seeds an active gym with a few available machines so the Today card
    /// shows the Quick Plan entry, and (like the custom-machine fixture)
    /// skips onboarding. DEBUG-only; compiled out of Release.
    static let quickPlanFlowArgument = "-pulsecue-ui-test-quick-plan-flow"
    /// Seeds a single one-set, zero-rest routine into an in-memory store and
    /// skips onboarding, so the Workout Completion flow can be driven end to
    /// end (start → Complete/種目をスキップ → completion → 履歴) in a few taps
    /// without waiting on a rest timer. DEBUG-only; compiled out of Release.
    static let completionFlowArgument = "-pulsecue-ui-test-completion-flow"

    /// The custom-machine, quick-plan, and completion fixtures are the only
    /// launch modes allowed to update onboarding. Isolated DEBUG roots win when
    /// arguments are accidentally combined, preserving their
    /// no-UserDefaults-write guarantee.
    static func shouldCompleteCustomMachineOnboarding(
        _ args: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        // DEBUG-only fixture: Release never skips onboarding via a launch
        // argument, so a production build always shows the real first-run flow.
        #if DEBUG
        guard args.contains(customMachineFlowArgument)
            || args.contains(quickPlanFlowArgument)
            || args.contains(completionFlowArgument)
        else { return false }
        return requestedGlassUIRoute(args) == nil && !isFormGuideDebugRoute(args)
        #else
        return false
        #endif
    }

    /// Test/development-only: opens a deterministic 3D Form Guide directly at
    /// launch for visual/screenshot review. Recognized only in DEBUG builds
    /// (see `ContentView`); it presents an existing guide, persists nothing,
    /// and never appears on any normal user path.
    static let formGuide3DArgument = "-pulsecue-ui-test-form-guide-3d"
    /// Optional companion: `-pulsecue-ui-test-exercise-id <exerciseId>` selects
    /// which of the 10 guided exercises to open (defaults to chest press).
    static let formGuide3DExerciseIdArgument = "-pulsecue-ui-test-exercise-id"

    /// Optional companion: `-pulsecue-ui-test-progress <0..1>` freezes the
    /// guide at a static cycle progress for deterministic screenshots.
    static let formGuide3DProgressArgument = "-pulsecue-ui-test-progress"

    #if DEBUG
    /// Opens one isolated, deterministic Glass UI state. The argument and
    /// route values are compiled out of Release builds.
    static let glassUIRouteArgument = "-pulsecue-debug-glass-ui-route"

    static func requestedGlassUIRoute(
        _ args: [String] = ProcessInfo.processInfo.arguments
    ) -> GlassUIVisualQARoute? {
        guard let index = args.firstIndex(of: glassUIRouteArgument),
              args.indices.contains(index + 1)
        else { return nil }
        return GlassUIVisualQARoute(rawValue: args[index + 1])
    }
    #endif

    /// Pure launch-mode selection (testable): the requested exercise id for
    /// the deterministic guide route, or `nil` when the route argument is
    /// absent. Whether this is honored is gated by `#if DEBUG` at the call
    /// site — in Release the route has no effect.
    static func requestedFormGuideExerciseId(_ args: [String] = ProcessInfo.processInfo.arguments) -> String? {
        guard args.contains(formGuide3DArgument) else { return nil }
        if let i = args.firstIndex(of: formGuide3DExerciseIdArgument), i + 1 < args.count {
            return args[i + 1]
        }
        return "machine_chest_press"
    }

    /// Optional static progress for the guide route (`nil` = animate normally).
    static func requestedFormGuideProgress(_ args: [String] = ProcessInfo.processInfo.arguments) -> Float? {
        guard args.contains(formGuide3DArgument),
              let i = args.firstIndex(of: formGuide3DProgressArgument), i + 1 < args.count,
              let v = Float(args[i + 1]) else { return nil }
        return min(max(v, 0), 1)
    }

    /// Whether launching straight into the isolated debug guide root. This is
    /// the ONE predicate the app uses to fork startup — always evaluated
    /// inside `#if DEBUG`, so Release never forks.
    static func isFormGuideDebugRoute(_ args: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        args.contains(formGuide3DArgument)
    }
}

// MARK: - SwiftData schema versioning
//
// Adding the gym workout flow introduced `Gym` and `GymMachine` to
// the SwiftData store. SwiftData on iOS 17/18 can lightweight-migrate
// purely additive schema changes when an explicit `VersionedSchema`
// + `SchemaMigrationPlan` is provided. Without a plan, opening an
// existing on-disk store created by V1 can `fatalError` at launch,
// which is what manifested as a black launch screen on devices with
// any prior install of the app.
//
// V1 → V2 is additive only (two new entities); no data transform is
// required, so the stage is `.lightweight`.
//
// V2 → V3 adds `CustomMachine` (user-created gym equipment). It is a
// single new entity with no change to any existing model, so it is again
// purely additive and lightweight — existing rows are not enumerated or
// mutated. See Docs for the V3 schema / rollback note.
//
// V3 → V4 adds ONE optional attribute, `Step.exerciseId: String?`. Unlike
// V1→V2 / V2→V3 (which added whole new *entities*), this changes an
// existing entity's shape. Historical V1/V2/V3 must keep the pre-V4 `Step`
// shape so their on-disk schema hashes stay identical to what already
// shipped. Since every prior version referenced the same shared top-level
// `Step`, adding a property there would silently mutate the historical
// schemas too. To avoid that, V1/V2/V3 pin a version-specific legacy Step
// (`PulseCueSchemaV1.Step`, same entity name "Step", pre-V4 attributes),
// and only V4 uses the current top-level `Step` (with `exerciseId`). The
// added attribute is optional, so V3 → V4 is `.lightweight`: existing rows
// gain `exerciseId == nil` with no enumeration, transform, or title
// backfill. Proven both by a synthetic historical-schema migration test and
// by migrating a fixture generated with the actual pre-PR #132 source at
// commit 1974ab87200d4f9e023e57b2815717885b0f6cc7.

enum PulseCueSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    /// Version-specific historical `Step` (schemas V1–V3). Mirrors the
    /// pre-V4 shipped `Step` exactly — same entity name "Step" and the same
    /// attributes, with NO `exerciseId`. Referenced by V1/V2/V3 so their
    /// schema shape remains compatible with already-shipped stores; V4 uses
    /// the current top-level `Step`. Compatibility is guarded by an actual
    /// pre-PR #132 source-generated V3 fixture. Not used by app code.
    @Model
    final class Step {
        @Attribute(.unique) var id: UUID
        var routineId: UUID
        var order: Int
        var title: String
        var sets: Int
        var repsTarget: Int
        var restSeconds: Int
        var note: String
        var isWarmup: Bool

        init(
            id: UUID = UUID(),
            routineId: UUID,
            order: Int,
            title: String,
            sets: Int,
            repsTarget: Int,
            restSeconds: Int,
            note: String = "",
            isWarmup: Bool = false
        ) {
            self.id = id
            self.routineId = routineId
            self.order = order
            self.title = title
            self.sets = sets
            self.repsTarget = repsTarget
            self.restSeconds = restSeconds
            self.note = note
            self.isWarmup = isWarmup
        }
    }

    /// Version-specific historical `Routine` (schemas V1–V4). Mirrors the
    /// pre-V5 shipped `Routine` exactly — same entity name "Routine" and the
    /// same attributes, with NO `origin`. V5 uses the current top-level
    /// `Routine`, which adds `origin`. Not used by app code.
    @Model
    final class Routine {
        @Attribute(.unique) var id: UUID
        var name: String
        var createdAt: Date
        var updatedAt: Date
        var isPinned: Bool

        init(
            id: UUID = UUID(),
            name: String,
            createdAt: Date = Date(),
            updatedAt: Date = Date(),
            isPinned: Bool = false
        ) {
            self.id = id
            self.name = name
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.isPinned = isPinned
        }
    }

    static var models: [any PersistentModel.Type] {
        [
            PulseCueSchemaV1.Routine.self,
            PulseCueSchemaV1.Step.self,
            Session.self,
            StepResult.self,
            DayLog.self,
            MealEntry.self,
            UserProfile.self
        ]
    }
}

enum PulseCueSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            PulseCueSchemaV1.Routine.self,
            PulseCueSchemaV1.Step.self,
            Session.self,
            StepResult.self,
            DayLog.self,
            MealEntry.self,
            UserProfile.self,
            Gym.self,
            GymMachine.self
        ]
    }
}

enum PulseCueSchemaV3: VersionedSchema {
    static var versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            PulseCueSchemaV1.Routine.self,
            PulseCueSchemaV1.Step.self,
            Session.self,
            StepResult.self,
            DayLog.self,
            MealEntry.self,
            UserProfile.self,
            Gym.self,
            GymMachine.self,
            CustomMachine.self
        ]
    }
}

enum PulseCueSchemaV4: VersionedSchema {
    static var versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            PulseCueSchemaV1.Routine.self,
            Step.self,
            Session.self,
            StepResult.self,
            DayLog.self,
            MealEntry.self,
            UserProfile.self,
            Gym.self,
            GymMachine.self,
            CustomMachine.self
        ]
    }
}

/// Adds `Routine.storedOrigin` so workout-generated routines can be kept out
/// of the library. Lightweight: the new attribute is optional, so existing
/// rows migrate to nil, which `Routine.origin` reads as `.userSaved` — every
/// pre-V5 routine stays visible.
enum PulseCueSchemaV5: VersionedSchema {
    static var versionIdentifier = Schema.Version(5, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Routine.self,
            Step.self,
            Session.self,
            StepResult.self,
            DayLog.self,
            MealEntry.self,
            UserProfile.self,
            Gym.self,
            GymMachine.self,
            CustomMachine.self
        ]
    }
}

enum PulseCueMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            PulseCueSchemaV1.self,
            PulseCueSchemaV2.self,
            PulseCueSchemaV3.self,
            PulseCueSchemaV4.self,
            PulseCueSchemaV5.self
        ]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: PulseCueSchemaV1.self,
                toVersion: PulseCueSchemaV2.self
            ),
            .lightweight(
                fromVersion: PulseCueSchemaV2.self,
                toVersion: PulseCueSchemaV3.self
            ),
            .lightweight(
                fromVersion: PulseCueSchemaV3.self,
                toVersion: PulseCueSchemaV4.self
            ),
            .lightweight(
                fromVersion: PulseCueSchemaV4.self,
                toVersion: PulseCueSchemaV5.self
            )
        ]
    }
}
