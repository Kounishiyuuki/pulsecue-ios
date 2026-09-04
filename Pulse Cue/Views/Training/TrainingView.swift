//
//  TrainingView.swift
//  Pulse Cue
//
//  The root of the トレーニング tab.
//
//  Opening Training used to mean opening a routine picker — 「ルーティンを選択」
//  and a list. That is the right screen for choosing what to do *next week*,
//  but not for the question people actually arrive with, which is whether
//  they are training today and how far through it they are. The answer was
//  only on Home.
//
//  So the order is now: today, then the plan behind it, then everything else.
//
//    Today    what is running or ready to start, and the one action for it
//    Plan     the routine library — the same cards, one section lower
//    History  a tap away in the toolbar, where it has been since the tab
//             bar reorganisation
//    More     Gym, the exercise library, progress and AI planning
//
//  「More」 is not a junk drawer; it is where the training features that were
//  living in **Settings** belong. Registering a gym, browsing form guides and
//  reviewing a weekly plan are training tasks, and reaching them through
//  マイページ → 設定 meant the app filed them under app configuration. They
//  are unchanged — only findable from the module they serve.
//
//  The Today card is `TodayTrainingCard`, the same component Home uses. Not
//  for reuse's sake: it owns the rule that there is one primary action and
//  which one it is, and a second implementation here is exactly how Home and
//  Training would come to disagree about whether you can start a workout.
//

import SwiftData
import SwiftUI

struct TrainingView: View {
    @EnvironmentObject private var runnerViewModel: RunnerViewModel

    /// Re-present the Runner for an already-active workout. Owned by
    /// `ContentView`, exactly as Home's is, so starting from either tab is
    /// the same lifecycle and neither creates a second Session.
    let onResumeRunner: () -> Void

    /// The tab's routines, and the only query over them on this screen.
    ///
    /// Three things need them — the Today card's "is there anything to
    /// start", the progress summary's routine names, and the library below —
    /// and each of those used to be free to fetch its own. Same descriptor as
    /// the library's was, so ordering is unchanged.
    @Query(sort: [SortDescriptor(\Routine.updatedAt, order: .reverse)])
    private var routines: [Routine]
    @Query(sort: [SortDescriptor(\Session.startedAt, order: .reverse)])
    private var sessions: [Session]
    @Query private var stepResults: [StepResult]

    @State private var progressSummary: HomeProgressSummary = .empty
    @State private var showRoutinePicker = false
    @State private var pendingRoutine: Routine?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.deepSpace.opacity(0.95), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    TodayTrainingCard(
                        summary: trainingSummary,
                        onPrimaryAction: primaryAction
                    )

                    planSection

                    moreSection

                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("トレーニング")
        .navigationBarTitleDisplayMode(.large)
        // History stays one tap away, where the tab-bar reorganisation put it.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    HistoryView()
                } label: {
                    Label("履歴", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityLabel("履歴")
            }
        }
        .sheet(isPresented: $showRoutinePicker, onDismiss: startPendingRoutine) {
            RoutinePickerSheet(onSelect: { pendingRoutine = $0 })
        }
        .task { recomputeProgressSummary() }
        .onChange(of: progressSignature) { _, _ in recomputeProgressSummary() }
        .preferredColorScheme(.dark)
    }

    // MARK: - Today

    /// The same summary Home builds, through the same constructor.
    private var trainingSummary: HomeTrainingSummary {
        HomeTrainingSummary.make(
            runner: runnerViewModel,
            routines: routines,
            lastWorkoutName: progressSummary.lastWorkout?.routineName
        )
    }

    /// Resume an active workout, or open the picker. Never both, and never a
    /// second Session — the decision belongs to `TodayTrainingCard`.
    private func primaryAction() {
        if runnerViewModel.isRunning {
            onResumeRunner()
        } else {
            showRoutinePicker = true
        }
    }

    private func startPendingRoutine() {
        guard let routine = pendingRoutine else { return }
        pendingRoutine = nil
        runnerViewModel.start(routine: routine)
    }

    /// Refresh signal for the cached summary.
    ///
    /// Counting rows missed two things the summary shows: the completion of a
    /// workout, which mutates an existing `Session` rather than adding one,
    /// and the name of the routine it was — see `changeSignature`.
    private var progressSignature: HomeProgressSummary.ChangeSignature {
        HomeProgressSummary.changeSignature(
            sessions: sessions, results: stepResults, routines: routines
        )
    }

    private func recomputeProgressSummary() {
        progressSummary = HomeProgressSummary.make(
            sessions: sessions, results: stepResults, routines: routines
        )
    }

    // MARK: - Plan

    /// The routine library, unchanged and one section below today's action.
    ///
    /// Embedded rather than pushed: the routines *are* the plan, and hiding
    /// them behind another tap would trade one problem for a worse one. What
    /// changed is only that they no longer arrive before the question of
    /// whether you are training right now.
    private var planSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            PulseSectionHeader("プラン", icon: "list.bullet.rectangle")
            RoutineLibrarySection(routines: routines)
        }
    }

    // MARK: - More

    private var moreSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            PulseSectionHeader("その他の機能", icon: "ellipsis.circle")
            TrainingMoreSection()
        }
    }
}
