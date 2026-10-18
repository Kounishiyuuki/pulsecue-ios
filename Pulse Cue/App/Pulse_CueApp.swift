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
    @StateObject private var serverAccount: ServerAccountStore
    // Whose workout data the app is showing and resuming, derived from the
    // account state above. Read-only with respect to the account: it observes
    // and never writes back, so sign-in, sign-out and deletion are untouched.
    @StateObject private var dataScope: WorkoutDataScopeResolver

    var sharedModelContainer: ModelContainer = {
        // In-memory (never opening the user's persistent V4 store) for the
        // deterministic UI-test / QA fixtures. These are ALL DEBUG-only launch
        // arguments: Release never honours them, so a production build always
        // opens the real persistent store regardless of any argument.
        var inMemory = false
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(PulseCueUITestSupport.customMachineFlowArgument)
            || ProcessInfo.processInfo.arguments.contains(PulseCueUITestSupport.completionFlowArgument)
            || PulseCueUITestSupport.requestedTrainingRoutineCount() != nil
            || PulseCueUITestSupport.isFormGuideDebugRoute()
            || PulseCueUITestSupport.requestedGlassUIRoute() != nil {
            inMemory = true
        }
        #endif
        let modelConfiguration = ModelConfiguration(
            schema: Schema(versionedSchema: PulseCueSchemaV8.self),
            isStoredInMemoryOnly: inMemory
        )

        do {
            let container = try ModelContainer(
                for: Schema(versionedSchema: PulseCueSchemaV8.self),
                migrationPlan: PulseCueMigrationPlan.self,
                configurations: modelConfiguration
            )
            try PulseCueSchemaV8.backfillScopedDayKeys(in: ModelContext(container))
            return container
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
        let account = ServerAccountStore(
            api: PulseCueAccountAPIClient(configuration: .fromMainBundle()),
            tokenStore: KeychainServerSessionTokenStore(),
            deviceName: UIDevice.current.name,
            recordConfirmedDeletion: { AccountLocalDataCleanup.recordConfirmedDeletion(of: $0) }
        )
        _serverAccount = StateObject(wrappedValue: account)
        _dataScope = StateObject(wrappedValue: WorkoutDataScopeResolver(account: account))
        // A deleted account's cleanup that a crash or failed save interrupted.
        // Its rows are already out of every scope; this finishes removing them.
        AccountLocalDataCleanup(container: sharedModelContainer).resumePending()
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
            // Applied before the environment objects below, so the prompt's
            // own body is inside them rather than wrapped around them.
            .guestWorkoutAdoptionPrompt()
            .environmentObject(settings)
            .environmentObject(runnerViewModel)
            .environmentObject(authSession)
            .environmentObject(serverAccount)
            .environmentObject(dataScope)
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

    /// Seeds an exact number of user-saved routines into an in-memory store
    /// and skips onboarding: `-pulsecue-ui-test-training-routines <n>`.
    ///
    /// The quick-plan fixture reads the *persistent* store, so how many
    /// routines Training shows there depends on whatever the simulator was
    /// left holding. That is fine for tests about a screen existing and
    /// useless for tests about what a list of a given length does to the
    /// screen around it. DEBUG-only; Release honours no launch argument.
    static let trainingRoutinesArgument = "-pulsecue-ui-test-training-routines"

    /// The requested count, or nil when the fixture was not asked for.
    /// A count of 0 is meaningful — it is the empty-library state.
    static func requestedTrainingRoutineCount(
        _ args: [String] = ProcessInfo.processInfo.arguments
    ) -> Int? {
        #if DEBUG
        guard let index = args.firstIndex(of: trainingRoutinesArgument),
              args.indices.contains(index + 1),
              let count = Int(args[index + 1]),
              count >= 0
        else { return nil }
        return count
        #else
        return nil
        #endif
    }

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
            || requestedTrainingRoutineCount(args) != nil
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

    /// Version-specific historical `Session` (schemas V1–V5). Mirrors the
    /// pre-V6 shipped `Session` exactly — same entity name "Session" and the
    /// same attributes, with NO `ownerAccountID`. V6 uses the current
    /// top-level `Session`. Not used by app code.
    @Model
    final class Session {
        @Attribute(.unique) var id: UUID
        var routineId: UUID
        var dayDate: Date
        var startedAt: Date
        var endedAt: Date?
        var status: SessionStatus
        var totalSeconds: Int

        init(
            id: UUID = UUID(),
            routineId: UUID,
            dayDate: Date,
            startedAt: Date = Date(),
            endedAt: Date? = nil,
            status: SessionStatus = .inProgress,
            totalSeconds: Int = 0
        ) {
            self.id = id
            self.routineId = routineId
            self.dayDate = dayDate
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.status = status
            self.totalSeconds = totalSeconds
        }
    }

    /// Version-specific historical `StepResult` (schemas V1–V5). Mirrors the
    /// pre-V6 shipped `StepResult` exactly, with NO `ownerAccountID`. Not used
    /// by app code.
    @Model
    final class StepResult {
        @Attribute(.unique) var id: UUID
        var sessionId: UUID
        var stepId: UUID
        var setIndex: Int
        var done: Bool
        var actualReps: Int?
        var memo: String?

        init(
            id: UUID = UUID(),
            sessionId: UUID,
            stepId: UUID,
            setIndex: Int,
            done: Bool,
            actualReps: Int? = nil,
            memo: String? = nil
        ) {
            self.id = id
            self.sessionId = sessionId
            self.stepId = stepId
            self.setIndex = setIndex
            self.done = done
            self.actualReps = actualReps
            self.memo = memo
        }
    }

    /// Version-specific historical health models (schemas V1–V7). Each mirrors
    /// the pre-V8 shipped model exactly — same entity name, same attributes,
    /// same `.unique` — with NO `ownerAccountID`, and `DayLog.date` still
    /// globally unique. None of the three changed shape between V1 and V7
    /// (verified against git history), so one pinned copy serves all seven
    /// versions. V8 uses the current top-level models. Not used by app code.
    @Model
    final class DayLog {
        @Attribute(.unique) var date: Date
        var intakeCalories: Int?
        var exerciseCalories: Int?
        var sleepMinutes: Int?
        var weightKg: Double?
        var note: String?

        init(
            date: Date,
            intakeCalories: Int? = nil,
            exerciseCalories: Int? = nil,
            sleepMinutes: Int? = nil,
            weightKg: Double? = nil,
            note: String? = nil
        ) {
            self.date = date
            self.intakeCalories = intakeCalories
            self.exerciseCalories = exerciseCalories
            self.sleepMinutes = sleepMinutes
            self.weightKg = weightKg
            self.note = note
        }
    }

    @Model
    final class MealEntry {
        @Attribute(.unique) var id: UUID
        var dayDate: Date
        var slotRaw: String
        var name: String
        var kcal: Int
        var proteinGrams: Int?
        var carbGrams: Int?
        var fatGrams: Int?
        var statusRaw: String
        var sourceRaw: String
        var note: String?
        var createdAt: Date

        init(
            id: UUID = UUID(),
            dayDate: Date,
            slotRaw: String,
            name: String,
            kcal: Int,
            proteinGrams: Int? = nil,
            carbGrams: Int? = nil,
            fatGrams: Int? = nil,
            statusRaw: String,
            sourceRaw: String,
            note: String? = nil,
            createdAt: Date
        ) {
            self.id = id
            self.dayDate = dayDate
            self.slotRaw = slotRaw
            self.name = name
            self.kcal = kcal
            self.proteinGrams = proteinGrams
            self.carbGrams = carbGrams
            self.fatGrams = fatGrams
            self.statusRaw = statusRaw
            self.sourceRaw = sourceRaw
            self.note = note
            self.createdAt = createdAt
        }
    }

    @Model
    final class UserProfile {
        @Attribute(.unique) var id: UUID
        var heightCm: Int
        var ageYears: Int
        var biologicalSexRaw: String
        var activityFactorRaw: String
        var goalWeightKg: Double
        var weeklyChangeKg: Double
        var updatedAt: Date

        init(
            id: UUID = UUID(),
            heightCm: Int,
            ageYears: Int,
            biologicalSexRaw: String,
            activityFactorRaw: String,
            goalWeightKg: Double,
            weeklyChangeKg: Double,
            updatedAt: Date
        ) {
            self.id = id
            self.heightCm = heightCm
            self.ageYears = ageYears
            self.biologicalSexRaw = biologicalSexRaw
            self.activityFactorRaw = activityFactorRaw
            self.goalWeightKg = goalWeightKg
            self.weeklyChangeKg = weeklyChangeKg
            self.updatedAt = updatedAt
        }
    }

    static var models: [any PersistentModel.Type] {
        [
            PulseCueSchemaV1.Routine.self,
            PulseCueSchemaV1.Step.self,
            PulseCueSchemaV1.Session.self,
            PulseCueSchemaV1.StepResult.self,
            PulseCueSchemaV1.DayLog.self,
            PulseCueSchemaV1.MealEntry.self,
            PulseCueSchemaV1.UserProfile.self
        ]
    }
}

enum PulseCueSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            PulseCueSchemaV1.Routine.self,
            PulseCueSchemaV1.Step.self,
            PulseCueSchemaV1.Session.self,
            PulseCueSchemaV1.StepResult.self,
            PulseCueSchemaV1.DayLog.self,
            PulseCueSchemaV1.MealEntry.self,
            PulseCueSchemaV1.UserProfile.self,
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
            PulseCueSchemaV1.Session.self,
            PulseCueSchemaV1.StepResult.self,
            PulseCueSchemaV1.DayLog.self,
            PulseCueSchemaV1.MealEntry.self,
            PulseCueSchemaV1.UserProfile.self,
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
            PulseCueSchemaV1.Session.self,
            PulseCueSchemaV1.StepResult.self,
            PulseCueSchemaV1.DayLog.self,
            PulseCueSchemaV1.MealEntry.self,
            PulseCueSchemaV1.UserProfile.self,
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
            PulseCueSchemaV1.Session.self,
            PulseCueSchemaV1.StepResult.self,
            PulseCueSchemaV1.DayLog.self,
            PulseCueSchemaV1.MealEntry.self,
            PulseCueSchemaV1.UserProfile.self,
            Gym.self,
            GymMachine.self,
            CustomMachine.self
        ]
    }
}

/// Adds the account-scoped sync foundation: `Session.ownerAccountID` and
/// `StepResult.ownerAccountID`, plus the `SyncCursor` and `SyncOutboxItem`
/// entities.
///
/// Lightweight on both counts. The two attributes are optional, so every row
/// that already exists migrates to `nil` — which `AccountScopedSyncStore`
/// reads as guest, unowned data. That is the only safe default: history
/// recorded before this version says nothing about which account it belongs
/// to, and assigning it to whoever happens to be signed in is exactly the
/// move this whole foundation exists to make impossible. It becomes owned
/// only through an explicit `adoptGuestWorkoutData` call. The two new
/// entities are additive, like V1→V2 and V2→V3 before them.
enum PulseCueSchemaV6: VersionedSchema {
    static var versionIdentifier = Schema.Version(6, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Routine.self,
            Step.self,
            Session.self,
            StepResult.self,
            PulseCueSchemaV1.DayLog.self,
            PulseCueSchemaV1.MealEntry.self,
            PulseCueSchemaV1.UserProfile.self,
            Gym.self,
            GymMachine.self,
            CustomMachine.self,
            SyncCursor.self,
            SyncOutboxItem.self
        ]
    }
}

/// Adds `SyncTombstone`: which entities an account has deleted, for good.
///
/// Purely additive — one new entity, no change to any existing model — so it
/// is lightweight and existing rows are never enumerated. Nothing is
/// backfilled: a store upgrading to V7 has no tombstones, which is correct,
/// because nothing has been uploaded yet and so nothing has been deleted
/// server-side to remember.
enum PulseCueSchemaV7: VersionedSchema {
    static var versionIdentifier = Schema.Version(7, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Routine.self,
            Step.self,
            Session.self,
            StepResult.self,
            PulseCueSchemaV1.DayLog.self,
            PulseCueSchemaV1.MealEntry.self,
            PulseCueSchemaV1.UserProfile.self,
            Gym.self,
            GymMachine.self,
            CustomMachine.self,
            SyncCursor.self,
            SyncOutboxItem.self,
            SyncTombstone.self
        ]
    }
}

/// Adds account ownership to health and nutrition data: `ownerAccountID` on
/// `DayLog`, `MealEntry` and `UserProfile` (V1–V7 keep the owner-less pinned
/// `PulseCueSchemaV1` copies, so their shipped hashes are untouched).
///
/// - Every pre-existing row migrates to `ownerAccountID == nil` — guest data.
///   Nothing is attributed to whoever is signed in; that only ever happens
///   through an explicit guest adoption (not part of this version).
/// - `DayLog.date` loses its global `.unique`. Guest, A and B each need their
///   own log for the same day. Per-owner uniqueness moves to the new
///   `DayLog.scopedDayKey` (`.unique`, "<owner or guest>|<exact date bits>"),
///   which collides exactly when (owner, date) does — the same upsert
///   semantics `date` had, now scoped. iOS 17 has no compound `#Unique`.
/// - `MealEntry.id` / `UserProfile.id` stay globally unique. One profile per
///   owner is left to the repository; the schema does not enforce it.
///
/// Lightweight stage: it adds the optional columns and drops the `date`
/// constraint. Legacy DayLogs come out with `scopedDayKey == nil`, and
/// `backfillScopedDayKeys` fills them as soon as the container opens. That
/// cannot collide: pre-V8 dates were globally unique and every legacy row is
/// guest. It is not a `.custom` stage because a custom stage in the plan makes
/// every container opened at an intermediate version through the plan fail
/// to load (observed on the V2–V7 migration tests). Owners are never touched.
enum PulseCueSchemaV8: VersionedSchema {
    static var versionIdentifier = Schema.Version(8, 0, 0)

    /// Idempotent; a no-op once every DayLog has its key.
    static func backfillScopedDayKeys(in context: ModelContext) throws {
        let pending = try context.fetch(FetchDescriptor<DayLog>(
            predicate: #Predicate { $0.scopedDayKey == nil }
        ))
        guard !pending.isEmpty else { return }
        for log in pending {
            log.refreshScopedDayKey()
        }
        try context.save()
    }
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
            CustomMachine.self,
            SyncCursor.self,
            SyncOutboxItem.self,
            SyncTombstone.self
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
            PulseCueSchemaV5.self,
            PulseCueSchemaV6.self,
            PulseCueSchemaV7.self,
            PulseCueSchemaV8.self
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
            ),
            .lightweight(
                fromVersion: PulseCueSchemaV5.self,
                toVersion: PulseCueSchemaV6.self
            ),
            .lightweight(
                fromVersion: PulseCueSchemaV6.self,
                toVersion: PulseCueSchemaV7.self
            ),
            .lightweight(
                fromVersion: PulseCueSchemaV7.self,
                toVersion: PulseCueSchemaV8.self
            )
        ]
    }
}
