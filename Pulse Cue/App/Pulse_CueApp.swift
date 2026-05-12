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
        let schema = Schema([
            Routine.self,
            Step.self,
            Session.self,
            StepResult.self,
            DayLog.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
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
