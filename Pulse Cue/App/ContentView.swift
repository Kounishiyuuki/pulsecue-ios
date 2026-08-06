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
    @StateObject private var runnerPresenter = RunnerPresenter()

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                TodayView(onResumeRunner: { runnerPresenter.resume(isRunning: runnerViewModel.isRunning) })
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
        .tint(AppTheme.accent)
        .toolbarBackground(AppTheme.cardBackground.opacity(0.96), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .preferredColorScheme(.dark)
        .task {
            runnerViewModel.configure(modelContext: modelContext)
            PulseCueUITestFixtureSeeder.seedIfNeeded(modelContext: modelContext)
            SampleDataSeeder.seedIfNeeded(modelContext: modelContext)
            // `configure` may recover a session persisted from a previous
            // launch. `onChange` only fires on *transitions*, so mirror the
            // recovered state once here to re-present the Runner if needed.
            runnerPresenter.syncPresentation(isRunning: runnerViewModel.isRunning)
        }
        // Keep the cover's presentation in lock-step with the authoritative
        // workout state: a workout becoming active presents it; ending it
        // dismisses it. The workout is never started/ended from here.
        .onChange(of: runnerViewModel.isRunning) { _, running in
            runnerPresenter.syncPresentation(isRunning: running)
        }
        .fullScreenCover(isPresented: onboardingPresented) {
            OnboardingView {
                settings.completeOnboarding()
            }
        }
        // Runner is a focused, full-screen workout mode rather than a
        // persistent tab: it appears while a session is running and
        // dismisses when the session ends. Presentation is an explicit UI
        // state (`RunnerPresenter`) synchronised to `isRunning`;
        // `interactiveDismissDisabled` prevents an active workout from ever
        // being left with no visible, recoverable Runner.
        .fullScreenCover(isPresented: $runnerPresenter.isRunnerCovered) {
            NavigationStack {
                RunnerView()
            }
            .environmentObject(runnerViewModel)
            .environmentObject(settings)
            .interactiveDismissDisabled(runnerViewModel.isRunning)
        }
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
        // DEBUG-only: the custom-machine UI fixture seeds a throwaway gym into
        // the in-memory store. Compiled out of Release so no launch argument
        // can ever seed fixture data into a production build.
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains(PulseCueUITestSupport.customMachineFlowArgument) else {
            return
        }

        let repository = GymRepository(modelContext: modelContext)
        if repository.allGyms().isEmpty {
            _ = repository.createGym(name: "UIテストジム", makeActive: true)
        }
        #endif
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Routine.self, Step.self, Session.self, StepResult.self, DayLog.self], inMemory: true)
        .environmentObject(SettingsStore())
        .environmentObject(RunnerViewModel(settings: SettingsStore()))
        .environmentObject(AuthSessionStore())
}
