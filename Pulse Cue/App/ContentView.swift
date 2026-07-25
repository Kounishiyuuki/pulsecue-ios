//
//  ContentView.swift
//  Pulse Cue
//
//  Created by yuuki kounishi on 2026/02/06.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var runnerViewModel: RunnerViewModel
    @EnvironmentObject var settings: SettingsStore

    @State private var selectedTab: AppTab = .today

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                TodayView(selectedTab: $selectedTab)
            }
            .tabItem {
                Label("今日", systemImage: "sun.max")
            }
            .tag(AppTab.today)

            NavigationStack {
                WorkoutView()
            }
            .tabItem {
                Label("ワークアウト", systemImage: "list.bullet.rectangle")
            }
            .tag(AppTab.workout)

            NavigationStack {
                HistoryView()
            }
            .tabItem {
                Label("履歴", systemImage: "clock.arrow.circlepath")
            }
            .tag(AppTab.history)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("設定", systemImage: "gearshape")
            }
            .tag(AppTab.settings)
        }
        .task {
            runnerViewModel.configure(modelContext: modelContext)
            PulseCueUITestFixtureSeeder.seedIfNeeded(modelContext: modelContext)
            SampleDataSeeder.seedIfNeeded(modelContext: modelContext)
        }
        .fullScreenCover(isPresented: onboardingPresented) {
            OnboardingView {
                settings.completeOnboarding()
            }
        }
        // Runner is a focused, full-screen workout mode rather than a
        // persistent tab: it appears while a session is running and
        // dismisses when the session ends. The RunnerViewModel state machine
        // is unchanged — only its presentation moved off the tab bar.
        .fullScreenCover(isPresented: runnerPresented) {
            NavigationStack {
                RunnerView()
            }
            .environmentObject(runnerViewModel)
            .environmentObject(settings)
        }
    }

    /// Driven solely by `runnerViewModel.isRunning`. The setter is a no-op:
    /// the session is ended only from inside Runner (which flips the state
    /// machine to `.done`), so the cover cannot be swiped away mid-workout.
    private var runnerPresented: Binding<Bool> {
        Binding(
            get: { runnerViewModel.isRunning },
            set: { _ in }
        )
    }

    /// Presents the first-launch onboarding until the user starts as a guest.
    /// The setter is a no-op: dismissal is driven solely by
    /// `settings.completeOnboarding()` flipping `hasCompletedOnboarding`, so
    /// the cover cannot be swiped away without entering the app.
    private var onboardingPresented: Binding<Bool> {
        Binding(
            get: { !settings.hasCompletedOnboarding },
            set: { _ in }
        )
    }
}

@MainActor
private enum PulseCueUITestFixtureSeeder {
    static func seedIfNeeded(modelContext: ModelContext) {
        guard ProcessInfo.processInfo.arguments.contains(PulseCueUITestSupport.customMachineFlowArgument) else {
            return
        }

        let repository = GymRepository(modelContext: modelContext)
        if repository.allGyms().isEmpty {
            _ = repository.createGym(name: "UIテストジム", makeActive: true)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Routine.self, Step.self, Session.self, StepResult.self, DayLog.self], inMemory: true)
        .environmentObject(SettingsStore())
        .environmentObject(RunnerViewModel(settings: SettingsStore()))
        .environmentObject(AuthSessionStore())
}
