//
//  Pulse_CueApp.swift
//  Pulse Cue
//
//  Created by yuuki kounishi on 2026/02/06.
//

import SwiftUI
import SwiftData

@main
struct Pulse_CueApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var runnerViewModel: RunnerViewModel

    var sharedModelContainer: ModelContainer = {
        let modelConfiguration = ModelConfiguration(
            schema: Schema(versionedSchema: PulseCueSchemaV2.self),
            isStoredInMemoryOnly: false
        )

        do {
            return try ModelContainer(
                for: Schema(versionedSchema: PulseCueSchemaV2.self),
                migrationPlan: PulseCueMigrationPlan.self,
                configurations: modelConfiguration
            )
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        let settings = SettingsStore()
        _settings = StateObject(wrappedValue: settings)
        _runnerViewModel = StateObject(wrappedValue: RunnerViewModel(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(runnerViewModel)
        }
        .modelContainer(sharedModelContainer)
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

enum PulseCueSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Routine.self,
            Step.self,
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
            Routine.self,
            Step.self,
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

enum PulseCueMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [PulseCueSchemaV1.self, PulseCueSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: PulseCueSchemaV1.self,
                toVersion: PulseCueSchemaV2.self
            )
        ]
    }
}
