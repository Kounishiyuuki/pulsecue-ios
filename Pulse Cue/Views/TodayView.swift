//
//  TodayView.swift
//  Pulse Cue
//
//  Created by Codex.
//
//  Premium liquid-glass dashboard. Layout:
//  - Hero card: PulseCue mark + 今日の状態 + コンディション (derived
//    from how many of today's four DayLog fields are filled).
//  - ワークアウトを開始 / 再開: prominent gradient button, the day's
//    primary call-to-action.
//  - 2×2 frosted metric grid: 摂取 / 消費 / 睡眠 / 体重. Missing
//    fields surface as a small red dot + "入力 +" inside the card.
//  - バランスカード: today's balance (intake − exercise) + 7-day
//    average + 3-segment proportional bar (食事 / 運動 / 休息) +
//    "週間サマリーを見る →" link.
//
//  All existing functions are preserved: quick-input sheet on tap,
//  `@Query`-driven instant updates, `DayLogStore.fetchOrCreateToday`
//  guarantees one record per local date, runner resume routes to the
//  Runner tab.
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

    /// The weight the calorie target is computed from.
    ///
    /// Resolved through the shared resolver rather than read out of
    /// `recentLogs`: that query is bounded to the fourteen days this
    /// dashboard displays, and using a presentation window inside a
    /// calculation made Home and Nutrition disagree whenever the last weigh-in
    /// was older than a fortnight.
    ///
    /// Cached rather than fetched per render, and refreshed when the logs
    /// change.
    @State private var targetWeightKg: Double?

    /// Latest weight for *display* in the personal status row. Unbounded
    /// likewise, so the row and the target never describe different weigh-ins.
    private var latestLoggedWeight: Double? { targetWeightKg }

    var body: some View {
        ZStack {
            backgroundLayer.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    CompactPersonalStatus(
                        recordedCount: filledMetricCount,
                        totalCount: 4,
                        weightText: latestLoggedWeight.map { "\(formatWeight($0)) kg" },
                        goalDifferenceText: weightGoalSubtitle()?.differenceText,
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
            targetWeightKg = LatestBodyWeightResolver.latestWeightKg(
                modelContext: modelContext
            )
            ensureTodayLogExists()
            _ = UserProfileStore.fetchOrCreate(modelContext: modelContext)
            recomputeProgressSummary()
        }
        // Refreshed on any DayLog change, not just one inside the fourteen
        // days this screen renders. `allLogIds` exists solely as that trigger:
        // a weigh-in backfilled outside the window changes it, where
        // `recentLogs` would not notice.
        .onChange(of: allDayLogs) { _, _ in
            targetWeightKg = LatestBodyWeightResolver.latestWeightKg(
                modelContext: modelContext
            )
        }
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
        DailyNutritionSummary.make(
            dayLog: todayLog,
            mealsForDay: todaysMeals,
            manualTargetKcal: resolvedTargets.intakeCalories,
            profileTargetKcal: profiles.first?.targetIntake(
                currentWeightKg: latestLoggedWeight
            )
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
            metricsGrid
            weeklySummaryLink
            homeWorkoutProgressCard
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

    private var conditionHeadline: String {
        TodayConditionCopy.headline(filledCount: filledMetricCount)
    }

    private var conditionSubhead: String {
        TodayConditionCopy.subhead(filledCount: filledMetricCount)
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

    // MARK: - Metrics grid

    private var metricsGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
        let targets = resolvedTargets
        return LazyVGrid(columns: columns, spacing: 12) {
            // Shows the same figure as the card above and as the Nutrition
            // tab. It used to read `DayLog.intakeCalories` directly, so on a
            // day with confirmed meals Home displayed two different intake
            // numbers — and tapping this one opened an editor whose value no
            // screen would ever show.
            metricCard(
                icon: "fork.knife",
                title: "摂取",
                value: HomeIntakeTile.displayedKcal(for: nutritionSummary)
                    .map { formatInt($0) },
                unit: "kcal",
                accent: Color(red: 0.32, green: 0.66, blue: 0.97),
                field: .nutrition,
                targetSubtitle: kcalSubtitle(
                    current: HomeIntakeTile.displayedKcal(for: nutritionSummary),
                    target: nutritionSummary.targetKcal
                ),
                action: HomeIntakeTile.opensNutrition(for: nutritionSummary)
                    ? onOpenNutrition
                    : nil,
                actionHint: HomeIntakeTile.accessibilityHint(for: nutritionSummary)
            )
            metricCard(
                icon: "flame.fill",
                title: "消費",
                value: todayLog?.exerciseCalories.map { formatInt($0) },
                unit: "kcal",
                accent: Color(red: 0.41, green: 0.56, blue: 0.96),
                field: .workout,
                targetSubtitle: kcalSubtitle(
                    current: todayLog?.exerciseCalories,
                    target: targets.exerciseCalories
                )
            )
            metricCard(
                icon: "moon.fill",
                title: "睡眠",
                value: todayLog?.sleepMinutes.map { formatSleep(minutes: $0) },
                unit: nil,
                accent: Color(red: 0.49, green: 0.45, blue: 0.97),
                field: .sleep,
                targetSubtitle: sleepSubtitle(
                    current: todayLog?.sleepMinutes,
                    target: targets.sleepMinutes
                )
            )
            metricCard(
                icon: "scalemass.fill",
                title: "体重",
                value: todayLog?.weightKg.map { formatWeight($0) },
                unit: "kg",
                accent: Color(red: 0.67, green: 0.45, blue: 0.96),
                field: .weight,
                targetSubtitle: weightGoalSubtitle()
            )
        }
    }

    /// "目標 X kcal · あと Y kcal" subtitle for kcal-based metrics.
    /// Returns nil when no target is configured or the user hasn't
    /// logged a value yet — caller preserves the existing display.
    private func kcalSubtitle(current: Int?, target: Int?) -> TargetSubtitle? {
        guard let target,
              let diff = HealthTargetDifference.formatKcal(current: current, target: target) else {
            return nil
        }
        return TargetSubtitle(
            targetText: "目標 \(formatInt(target)) kcal",
            differenceText: diff.label,
            direction: diff.direction
        )
    }

    private func sleepSubtitle(current: Int?, target: Int?) -> TargetSubtitle? {
        guard let target,
              let diff = HealthTargetDifference.formatSleepMinutes(current: current, target: target) else {
            return nil
        }
        return TargetSubtitle(
            targetText: "目標 \(formatSleep(minutes: target))",
            differenceText: diff.label,
            direction: diff.direction
        )
    }

    /// Subtitle for the 体重 card. Sources its target from
    /// `UserProfile.goalWeightKg` rather than `HealthTargets` because
    /// weight has a single long-running goal (not a daily one) and is
    /// already managed by the existing profile flow.
    private func weightGoalSubtitle() -> TargetSubtitle? {
        guard let current = todayLog?.weightKg,
              let profile = profiles.first,
              let diff = WeightTargetDifference.goalDifference(
                current: current,
                goal: profile.goalWeightKg
              ) else {
            return nil
        }
        return TargetSubtitle(
            targetText: "目標 \(formatWeight(profile.goalWeightKg)) kg",
            differenceText: diff.label,
            direction: diff.direction
        )
    }

    /// Compact value object passed into metric cards to avoid sprinkling
    /// optional-handling at each call site.
    private struct TargetSubtitle {
        let targetText: String
        let differenceText: String
        let direction: HealthTargetDifference.Direction
    }

    private func metricCard(
        icon: String,
        title: String,
        value: String?,
        unit: String?,
        accent: Color,
        field: DayLogField,
        targetSubtitle: TargetSubtitle?,
        /// Overrides the default quick-input action. Used where manual entry
        /// would not be honoured.
        action: (() -> Void)? = nil,
        actionHint: String? = nil
    ) -> some View {
        let isMissing = (value == nil)
        return Button {
            if let action {
                action()
            } else {
                openField(field)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    ZStack {
                        Circle()
                            .fill(accent.opacity(0.16))
                            .frame(width: 30, height: 30)
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(accent)
                    }
                    Spacer()
                    if isMissing {
                        Circle()
                            .fill(Color.red.opacity(0.75))
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                    }
                }

                Spacer(minLength: 8)

                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let value = value {
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(value)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if let unit = unit {
                            Text(unit)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    HStack(spacing: 4) {
                        Text("入力")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(accent)
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                }

                if let subtitle = targetSubtitle {
                    targetSubtitleRow(subtitle)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 110)
            .padding(14)
            .background(glassBackground)
            .overlay(glassStroke)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(metricAccessibilityLabel(title: title, value: value, unit: unit, subtitle: targetSubtitle))
        .accessibilityHint(actionHint ?? "\(title)を入力")
    }

    @ViewBuilder
    private func targetSubtitleRow(_ subtitle: TargetSubtitle) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(subtitle.targetText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 3) {
                Image(systemName: targetIcon(subtitle.direction))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(targetColor(subtitle.direction))
                Text(subtitle.differenceText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(targetColor(subtitle.direction))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    private func targetColor(_ direction: HealthTargetDifference.Direction) -> Color {
        switch direction {
        case .onTarget: return .green
        case .over: return .orange
        case .under: return Color(red: 0.27, green: 0.62, blue: 0.95)
        }
    }

    private func targetIcon(_ direction: HealthTargetDifference.Direction) -> String {
        switch direction {
        case .onTarget: return "checkmark.circle.fill"
        case .over: return "arrow.up.circle.fill"
        case .under: return "arrow.down.circle.fill"
        }
    }

    private func metricAccessibilityLabel(
        title: String,
        value: String?,
        unit: String?,
        subtitle: TargetSubtitle?
    ) -> String {
        let base: String
        if let value {
            base = "\(title) \(value)\(unit ?? "")"
        } else {
            base = "\(title) 未入力"
        }
        if let subtitle {
            return "\(base)、\(subtitle.targetText)、\(subtitle.differenceText)"
        }
        return base
    }

    // MARK: - Workout progress (Home)

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "M月d日"; return f
    }()

    /// Compact "continue + this week + progress" block. Hidden entirely until
    /// there is workout history, so a first-time Home leads with Quick Plan.
    @ViewBuilder
    private var homeWorkoutProgressCard: some View {
        if progressSummary.hasHistory {
            VStack(alignment: .leading, spacing: 14) {
                PulseSectionHeader("トレーニング", icon: "figure.strengthtraining.traditional")

                if let last = progressSummary.lastWorkout {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("最後のトレーニング")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.accent)
                        HStack(spacing: 8) {
                            Text(Self.shortDateFormatter.string(from: last.date))
                                .font(.subheadline.weight(.semibold))
                            Text(last.routineName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(DateUtils.formatDuration(seconds: max(0, last.durationSeconds)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            repeatLastWorkout()
                        } label: {
                            Label("前回のメニューをもう一度", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .tint(AppTheme.accent)
                    }
                }

                weeklyProgressRow

                NavigationLink {
                    WorkoutProgressView()
                } label: {
                    HStack(spacing: 6) {
                        Text("進捗を見る")
                        Image(systemName: "chevron.right").font(.caption2)
                        Spacer(minLength: 0)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(minHeight: 44)
                }
            }
            .padding(16)
            .pulseCard()
        }
    }

    private var weeklyProgressRow: some View {
        HStack(spacing: 10) {
            weeklyStat("\(progressSummary.weeklyWorkoutCount)", "今週の回数")
            weeklyStat("\(progressSummary.weeklyTrainingDays)", "日数")
            weeklyStat("\(progressSummary.weeklyCompletedSets)", "セット")
            weeklyStat(DateUtils.formatDuration(seconds: max(0, progressSummary.weeklyDurationSeconds)), "合計時間")
        }
    }

    private func weeklyStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.weight(.bold)).foregroundStyle(.primary)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Glass surfaces

    private var glassBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.regularMaterial)
            .shadow(color: .black.opacity(0.05), radius: 14, x: 0, y: 8)
    }

    private var glassStroke: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.7), .white.opacity(0.1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.6
            )
    }

    // MARK: - Helpers

    private func formatInt(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formatSleep(minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    private func formatWeight(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }

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
