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
    @EnvironmentObject var authSession: AuthSessionStore
    @EnvironmentObject var serverAccount: ServerAccountStore

    @State private var selectedTab: AppTab = PrimaryNavigation.defaultTab
    @StateObject private var runnerPresenter = RunnerPresenter()

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                TodayView(onResumeRunner: { runnerPresenter.resume(isRunning: runnerViewModel.isRunning) })
            }
            .tabItem {
                Label(
                    PrimaryNavigation.label(for: .home),
                    systemImage: PrimaryNavigation.icon(for: .home)
                )
            }
            .tag(AppTab.home)

            // Routine selection is the root of Training; History lives inside
            // it, one tap from here, because you look at past workouts in the
            // course of deciding what to do next.
            NavigationStack {
                WorkoutView()
            }
            .tabItem {
                Label(
                    PrimaryNavigation.label(for: .training),
                    systemImage: PrimaryNavigation.icon(for: .training)
                )
            }
            .tag(AppTab.training)

            NavigationStack {
                NutritionView()
            }
            .tabItem {
                Label(
                    PrimaryNavigation.label(for: .nutrition),
                    systemImage: PrimaryNavigation.icon(for: .nutrition)
                )
            }
            .tag(AppTab.nutrition)

            NavigationStack {
                MeView()
            }
            .tabItem {
                Label(
                    PrimaryNavigation.label(for: .me),
                    systemImage: PrimaryNavigation.icon(for: .me)
                )
            }
            .tag(AppTab.me)
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
            runnerPresenter.syncPresentation(shouldPresent: runnerViewModel.shouldPresentRunner)
            // Ask the provider whether a stored Apple / Google link is still
            // good, and restore the linked display if so. Nothing is requested
            // from the user here: this only re-reads a link they already made,
            // and a link the provider no longer honours quietly falls back to
            // guest.
            await authSession.restoreLinkedAccount()
            // Confirm any stored PulseCue session with the server. A rejected
            // session is discarded; a network failure keeps it and leaves the
            // account state unknown rather than signing the user out for
            // being offline. Neither outcome affects local features.
            await serverAccount.restore()
        }
        // Keep the cover's presentation in lock-step with the authoritative
        // workout state: a workout becoming active presents it; a finished one
        // keeps it until its Completion summary is dismissed. The workout is
        // never started/ended from here.
        .onChange(of: runnerViewModel.shouldPresentRunner) { _, shouldPresent in
            runnerPresenter.syncPresentation(shouldPresent: shouldPresent)
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
        let args = ProcessInfo.processInfo.arguments
        let wantsCustomMachine = args.contains(PulseCueUITestSupport.customMachineFlowArgument)
        let wantsQuickPlan = args.contains(PulseCueUITestSupport.quickPlanFlowArgument)
        let wantsCompletion = args.contains(PulseCueUITestSupport.completionFlowArgument)

        // The completion fixture needs no gym — just the shortest possible
        // real routine, so the Runner reaches its end after a single Complete
        // (or a single 種目をスキップ) with no rest timer in between.
        if wantsCompletion {
            seedCompletionRoutine(modelContext: modelContext)
        }

        guard wantsCustomMachine || wantsQuickPlan else { return }

        let repository = GymRepository(modelContext: modelContext)
        let gym: Gym
        if let existing = repository.allGyms().first {
            gym = existing
        } else {
            gym = repository.createGym(name: "UIテストジム", makeActive: true)
        }

        // The Quick Plan fixture also selects a few machines so the Today card
        // reaches its "active gym with machines" state and the generator has
        // real candidates to work with.
        if wantsQuickPlan {
            // A generous chest/back set so a generated plan leaves spare
            // machines for Exercise Replacement to offer as alternatives.
            // Set unconditionally (the simulator persists app data across UI
            // test launches, so an isEmpty guard would keep a stale set).
            repository.setMachines(
                ["bench_press", "chest_press", "pec_deck", "incline_chest_press",
                 "cable_machine", "smith_machine", "dumbbells", "lat_pulldown", "seated_row"],
                for: gym
            )
        }
        #endif
    }

    #if DEBUG
    /// One routine, one exercise, one set, no rest. Inserted only into the
    /// completion fixture's in-memory store (see `completionFlowArgument`).
    private static func seedCompletionRoutine(modelContext: ModelContext) {
        let existing = (try? modelContext.fetchCount(FetchDescriptor<Routine>())) ?? 0
        guard existing == 0 else { return }
        let routine = Routine(name: "完了フローテスト")
        modelContext.insert(routine)
        modelContext.insert(
            Step(
                routineId: routine.id,
                order: 0,
                title: "チェストプレス",
                sets: 1,
                repsTarget: 10,
                restSeconds: 0
            )
        )
        try? modelContext.save()
    }
    #endif
}

#Preview {
    ContentView()
        .modelContainer(for: [Routine.self, Step.self, Session.self, StepResult.self, DayLog.self], inMemory: true)
        .environmentObject(SettingsStore())
        .environmentObject(RunnerViewModel(settings: SettingsStore()))
        .environmentObject(AuthSessionStore())
        .environmentObject(
            ServerAccountStore(
                api: PulseCueAccountAPIClient(configuration: PulseCueAPIConfiguration(rawValue: nil)),
                tokenStore: InMemoryServerSessionTokenStore()
            )
        )
}
