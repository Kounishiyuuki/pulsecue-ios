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
                RunnerView()
            }
            .tabItem {
                Label("ランナー", systemImage: "figure.strengthtraining.traditional")
            }
            .tag(AppTab.runner)

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
            SampleDataSeeder.seedIfNeeded(modelContext: modelContext)
        }
        .fullScreenCover(isPresented: onboardingPresented) {
            OnboardingView {
                settings.completeOnboarding()
            }
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

#Preview {
    ContentView()
        .modelContainer(for: [Routine.self, Step.self, Session.self, StepResult.self, DayLog.self], inMemory: true)
        .environmentObject(SettingsStore())
        .environmentObject(RunnerViewModel(settings: SettingsStore()))
}
