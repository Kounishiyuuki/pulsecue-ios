//
//  TodayView.swift
//  Pulse Cue
//
//  The root of the ホーム tab: what today looks like, in the order it matters.
//
//    Personal status   weight, and how far it is from the goal
//    Today Training    what is running or ready to start, and its one action
//    Today Nutrition   what is left of the day's calories
//    記録を入力         the four quick inputs, the weekly link, progress
//
//  Composition and wiring only. The two cards at the top are the same
//  components Training and Nutrition use — not for reuse's sake, but because
//  each owns a rule (which action is primary; what the day's intake is) that
//  a second implementation here would eventually contradict.
//
//  What is left in this file is what a root owns: the queries, the sheets,
//  and the two summaries the cards are built from.
//

import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject var runnerViewModel: RunnerViewModel
    @EnvironmentObject var settings: SettingsStore

    /// Re-present the Runner cover for an already-active workout. Owned by
    /// ContentView (`RunnerPresenter.resume`) so no new Session is created.
    let onResumeRunner: () -> Void

    /// Switch to the Nutrition tab.
    ///
    /// Home used to `NavigationLink` to `NutritionView`, which was fine when
    /// Nutrition had no tab of its own. Now it does, and pushing it inside
    /// Home's stack would leave two live copies of the same screen with
    /// separate scroll positions and separate input state. Selecting the tab
    /// keeps one.
    let onOpenNutrition: () -> Void

    @Query private var recentLogs: [DayLog]
    @Query(sort: [SortDescriptor(\UserProfile.updatedAt, order: .reverse)])
    private var profiles: [UserProfile]

    // Workout history for the Home progress summary / "repeat" action. Derived
    // read-only via `WorkoutProgress`; never mutated here.
    @Query(sort: [SortDescriptor(\Session.startedAt, order: .reverse)])
    private var sessions: [Session]
    @Query private var stepResults: [StepResult]
    @Query private var routines: [Routine]
    @Query private var allSteps: [Step]
    /// Every day log, used only as a change trigger for the weight cache.
    ///
    /// `recentLogs` is bounded to the fourteen days this screen renders, so a
    /// weigh-in backfilled outside that window would not disturb it and the
    /// cached weight would go stale while the user sat on Home.
    ///
    /// This does load every row rather than just their ids — SwiftData has no
    /// projection for that — but a `DayLog` is one small row per day, so the
    /// cost is bounded by the calendar rather than by usage. The meal query
    /// above is the one where that distinction mattered.
    @Query(sort: [SortDescriptor(\DayLog.date, order: .reverse)])
    private var allDayLogs: [DayLog]

    /// Today's meals only. Read-only; Home never writes a meal.
    ///
    /// Date-bounded in the query rather than fetched whole and filtered:
    /// Home rendered every meal the user has ever logged in order to add up
    /// one day, and that cost grows with the history forever.
    @Query private var todaysMeals: [MealEntry]

    @StateObject private var targetStore = HealthTargetStore()
    /// Stateless UserDefaults accessor (same as WorkoutView), for the shared
    /// Runner-start path used by "前回のメニューをもう一度".
    @State private var restStore = RoutineRestPreferenceStore()
    /// Cached so the summary is recomputed only on appear / History change,
    /// not on every body render (see `recomputeProgressSummary`).
    @State private var progressSummary: HomeProgressSummary = .empty

    @State private var activeField: DayLogField?
    @State private var showRoutinePicker = false
    /// Routine chosen in the picker, started in the sheet's `onDismiss` so the
    /// picker is fully gone before the Runner cover presents.
    @State private var pendingRoutine: Routine?

    init(
        onResumeRunner: @escaping () -> Void,
        onOpenNutrition: @escaping () -> Void = {}
    ) {
        self.onResumeRunner = onResumeRunner
        self.onOpenNutrition = onOpenNutrition
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -13, to: today) ?? today
        self._recentLogs = Query(
            filter: #Predicate<DayLog> { $0.date >= start },
            sort: [SortDescriptor(\DayLog.date, order: .reverse)]
        )
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today) ?? today
        self._todaysMeals = Query(
            filter: #Predicate<MealEntry> { $0.dayDate >= today && $0.dayDate < tomorrow }
        )
    }

    private var summary: HealthSummary {
        HealthSummary(logs: recentLogs)
    }

    private var todayLog: DayLog? { summary.todayLog }

    /// Today's resolved targets via HealthTargetResolver. Each metric
    /// independently walks the priority chain (date override → weekday
    /// override → default). Nil entries mean the user hasn't set a
    /// target for that metric — the UI preserves the prior display in
    /// that case.
    private var resolvedTargets: HealthTargets {
        HealthTargetResolver.resolveAll(date: Date(), settings: targetStore.settings)
    }

    /// The latest weigh-in — both the figure the personal status row shows and
    /// the one the calorie target is computed from. One value, so the row and
    /// the target can never describe different weigh-ins.
    ///
    /// Resolved through the shared resolver rather than read out of
    /// `recentLogs`: that query is bounded to the fourteen days this dashboard
    /// displays, and using a presentation window inside a calculation made
    /// Home and Nutrition disagree whenever the last weigh-in was older than a
    /// fortnight.
    ///
    /// Cached rather than fetched per render, and refreshed when the logs
    /// change.
    @State private var latestWeightKg: Double?

    /// Refresh signal for the cached weight.
    ///
    /// `onChange(of: allDayLogs)` compared `@Model` rows by identity, so
    /// editing a weight in place left the array equal and this screen kept
    /// showing a weight no longer on disk.
    private var latestWeightSignature: String {
        LatestBodyWeightResolver.changeSignature(for: allDayLogs)
    }

    private func refreshLatestWeight() {
        latestWeightKg = LatestBodyWeightResolver.latestWeightKg(
            modelContext: modelContext
        )
    }

    var body: some View {
        ZStack {
            backgroundLayer.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    CompactPersonalStatus(
                        recordedCount: filledMetricCount,
                        totalCount: 4,
                        weightText: latestWeightKg.map { "\(NumberFormat.weight($0)) kg" },
                        goalDifferenceText: goalDifferenceText,
                        onTapWeight: { activeField = .weight }
                    )

                    TodayTrainingCard(
                        summary: trainingSummary,
                        onPrimaryAction: workoutAction
                    )

                    TodayNutritionCard(
                        summary: nutritionSummary,
                        onRecordMeal: onOpenNutrition
                    )

                    secondarySection

                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .navigationTitle("今日")
        .navigationBarTitleDisplayMode(.large)
        .sheet(item: $activeField) { field in
            if let dayLog = todayLog {
                DayLogQuickInputSheet(field: field, dayLog: dayLog)
            }
        }
        .sheet(isPresented: $showRoutinePicker, onDismiss: startPendingRoutine) {
            RoutinePickerSheet(onSelect: { pendingRoutine = $0 })
        }
        .task {
            refreshLatestWeight()
            ensureTodayLogExists()
            _ = UserProfileStore.fetchOrCreate(modelContext: modelContext)
            recomputeProgressSummary()
        }
        .onChange(of: latestWeightSignature) { _, _ in refreshLatestWeight() }
        .onChange(of: sessions.count) { _, _ in recomputeProgressSummary() }
        .onChange(of: stepResults.count) { _, _ in recomputeProgressSummary() }
    }

    // MARK: - Home summaries

    /// Today's training, as Home needs it. Derived only; nothing is computed
    /// here that the app did not already know.
    private var trainingSummary: HomeTrainingSummary {
        HomeTrainingSummary(
            isRunning: runnerViewModel.isRunning,
            currentStepTitle: runnerViewModel.currentStep?.title,
            currentSet: runnerViewModel.currentStep.map { _ in
                runnerViewModel.currentSetIndex + 1
            },
            totalSets: runnerViewModel.currentStep?.sets,
            hasRoutines: RoutineLibrary.hasStartable(routines),
            lastWorkoutName: progressSummary.lastWorkout?.routineName
        )
    }

    /// Today's nutrition.
    ///
    /// Built by `DailyNutritionSummary`, which the Nutrition tab uses too, so
    /// the two screens cannot report different numbers for the same day.
    private var nutritionSummary: DailyNutritionSummary {
        DailyNutritionSummary.forDay(
            Date(),
            dayLog: todayLog,
            mealsForDay: todaysMeals,
            profile: profiles.first,
            currentWeightKg: latestWeightKg,
            targetSettings: targetStore.settings
        )
    }

    // MARK: - Secondary content

    /// Everything that is useful but not a decision for today.
    ///
    /// Nothing was deleted on the way down here: the four quick inputs, the
    /// weekly summary link and the training progress block all still work
    /// exactly as before. They simply stopped competing with Training and
    /// Nutrition for the first screenful.
    private var secondarySection: some View {
        VStack(spacing: 16) {
            PulseSectionHeader("記録を入力", icon: "square.and.pencil")
            HomeMetricsGrid(
                todayLog: todayLog,
                targets: resolvedTargets,
                nutritionSummary: nutritionSummary,
                goalWeightKg: profiles.first?.goalWeightKg,
                onOpenNutrition: onOpenNutrition,
                onOpenField: openField
            )
            weeklySummaryLink
            HomeWorkoutProgressCard(
                summary: progressSummary,
                onRepeatLastWorkout: repeatLastWorkout
            )
        }
    }

    private var weeklySummaryLink: some View {
        NavigationLink {
            HealthSummaryView()
        } label: {
            HStack(spacing: 6) {
                Text("週間サマリーを見る")
                    .font(.subheadline.weight(.medium))
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(AppTheme.accent)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("週間サマリーを見る")
    }

    private func recomputeProgressSummary() {
        progressSummary = HomeProgressSummary.make(
            sessions: sessions, results: stepResults, routines: routines
        )
    }

    /// Starts a brand-new workout from the most recent completed session's
    /// routine, through the same `WorkoutStarter` path the routine list uses.
    /// History is never reused or mutated; a fresh Session is created.
    private func repeatLastWorkout() {
        guard let last = progressSummary.lastWorkout,
              let routine = routines.first(where: { $0.id == last.routineId }) else { return }
        let steps = allSteps.filter { $0.routineId == routine.id }
        WorkoutStarter.start(
            routine: routine,
            steps: steps,
            modelContext: modelContext,
            restStore: restStore,
            appDefaultRestSeconds: settings.defaultRestSeconds,
            runner: runnerViewModel
        )
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        PulseAtmosphericBackground()
    }

    private var filledMetricCount: Int {
        guard let log = todayLog else { return 0 }
        var count = 0
        if log.intakeCalories != nil { count += 1 }
        if log.exerciseCalories != nil { count += 1 }
        if log.sleepMinutes != nil { count += 1 }
        if log.weightKg != nil { count += 1 }
        return count
    }

    private func workoutAction() {
        if runnerViewModel.isRunning {
            // Active workout: re-present the existing Runner cover. Never
            // opens the picker and never starts a second Session.
            onResumeRunner()
        } else {
            showRoutinePicker = true
        }
    }

    /// Starts the routine chosen in the picker, invoked from the sheet's
    /// `onDismiss` (i.e. once the picker is fully dismissed). Starting here —
    /// not from inside the picker row — keeps the Session start and the
    /// Runner cover presentation off the picker's modal transition.
    private func startPendingRoutine() {
        guard let routine = pendingRoutine else { return }
        pendingRoutine = nil
        runnerViewModel.start(routine: routine)
    }

    /// How far today's weigh-in is from the profile's goal, for the status
    /// row. The same figure the 体重 card shows, through the same helper —
    /// two spellings of "distance to goal" on one screen is how they come to
    /// disagree about the sign.
    private var goalDifferenceText: String? {
        guard let current = todayLog?.weightKg,
              let goal = profiles.first?.goalWeightKg,
              let diff = WeightTargetDifference.goalDifference(current: current, goal: goal)
        else { return nil }
        return diff.label
    }

    // MARK: - Helpers

    private func ensureTodayLogExists() {
        if todayLog == nil {
            _ = DayLogStore.fetchOrCreateToday(modelContext: modelContext)
        }
    }

    private func openField(_ field: DayLogField) {
        ensureTodayLogExists()
        activeField = field
    }
}

/// Home "今日の状態" copy, derived purely from how many of today's four
/// DayLog fields have been recorded (0...4).
///
/// This intentionally describes **recording completeness**, not health,
/// readiness, or physiological quality — the app has no such signal. Kept as
/// a standalone, pure mapping so it is unit-testable and so a future
/// signature readiness visualisation can replace the presentation without
/// reworking this text contract.
enum TodayConditionCopy {
    static func headline(filledCount: Int) -> String {
        switch filledCount {
        case ...0: return "今日をはじめよう"
        case 1, 2: return "今日を記録中"
        case 3: return "記録がそろってきました"
        default: return "今日の記録がそろいました"
        }
    }

    static func subhead(filledCount: Int) -> String {
        switch filledCount {
        case ...0: return "コンディションを記録して1日を始めましょう"
        case 1: return "記録を続けましょう"
        case 2: return "半分ほど記録できました"
        case 3: return "あと1項目で今日の記録が完了します"
        default: return "本日のコンディション記録は完了です"
        }
    }
}
