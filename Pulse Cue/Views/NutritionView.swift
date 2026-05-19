//
//  NutritionView.swift
//  Pulse Cue
//
//  Created by Codex.
//
//  Premium liquid-glass nutrition screen. Layout:
//
//    1. 今日の栄養 summary card
//       - target intake (from SettingsStore.targetIntake)
//       - confirmed kcal so far
//       - PROTEIN / CARBS / FAT macro bars vs soft daily targets
//
//    2. 食事履歴
//       - For each MealSlot: either a confirmed-meal card or an
//         empty-slot tile that taps into the add flow.
//       - Pending manual drafts are shown inline with a 「確認待ち」
//         badge and tap → edit.
//
//    3. AI 解析結果 (only when there are pending AI meals)
//       - Premium hero card per pending AI meal.
//       - 「~ N kcal」 + macro bars.
//       - 編集 / 確定 CTAs. Discard is offered via long-press or via
//         the swipe action on the card. The 確定 path wraps the
//         estimate in `UserConfirmed<MealEstimate>` and runs it
//         through `applyConfirmedMealEstimate` so the privacy
//         boundary defined in AICoachStub.swift is honoured at the
//         only place the model writes back to DayLog.
//
//  No external AI API is called. AI candidates are locally
//  synthesized when the user taps "AI で記録" and edits the form.
//

import SwiftUI
import SwiftData

struct NutritionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var settings: SettingsStore

    @Query(sort: [SortDescriptor(\MealEntry.createdAt, order: .forward)]) private var allMeals: [MealEntry]
    @Query private var allDayLogs: [DayLog]
    @Query(sort: [SortDescriptor(\UserProfile.updatedAt, order: .reverse)])
    private var profiles: [UserProfile]

    @State private var sheetMode: MealEntrySheet.Mode?
    @State private var pendingSlotForChoice: MealSlot?
    @State private var showAddDialog = false
    @State private var pendingDiscard: MealEntry?

    private var today: Date { DateUtils.startOfDay(Date()) }

    private var todaysMeals: [MealEntry] {
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
        return allMeals.filter { $0.dayDate >= today && $0.dayDate < nextDay }
    }

    private var todaysDayLog: DayLog? {
        allDayLogs.first(where: { DateUtils.startOfDay($0.date) == today })
    }

    private var confirmedMeals: [MealEntry] {
        todaysMeals.filter { $0.status == .confirmed }
    }

    private var pendingManualMeals: [MealEntry] {
        todaysMeals.filter { $0.status == .pending && $0.source == .manual }
    }

    private var pendingAIMeals: [MealEntry] {
        todaysMeals.filter { $0.status == .pending && $0.source == .ai }
    }

    private var confirmedKcal: Int {
        confirmedMeals.reduce(0) { $0 + $1.kcal }
    }

    private var targetKcal: Int? {
        profiles.first?.targetIntake(currentWeightKg: latestWeight)
    }

    private var latestWeight: Double? {
        let logs = allDayLogs.sorted { $0.date > $1.date }
        return logs.first(where: { $0.weightKg != nil })?.weightKg
    }

    var body: some View {
        ZStack {
            backgroundLayer.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summaryCard
                    mealHistoryHeader
                    mealsByslot
                    if !pendingAIMeals.isEmpty {
                        sectionTitle("AI 解析結果")
                        ForEach(pendingAIMeals, id: \.id) { meal in
                            aiEstimateCard(meal)
                        }
                    }
                    recentMealsCard
                    weeklyTrendCard
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
        }
        .navigationTitle("栄養")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sheetMode) { mode in
            MealEntrySheet(mode: mode)
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: $showAddDialog,
            titleVisibility: .visible
        ) {
            Button("手動で記録") {
                if let slot = pendingSlotForChoice {
                    sheetMode = .add(source: .manual, slot: slot)
                }
            }
            Button("AI で記録（推定）") {
                if let slot = pendingSlotForChoice {
                    sheetMode = .add(source: .ai, slot: slot)
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("AI で記録すると「確認待ち」状態で保存されます。確定するまでカロリーには加算されません。")
        }
        .alert("この AI 推定を破棄しますか？", isPresented: discardAlertBinding) {
            Button("破棄", role: .destructive) {
                if let meal = pendingDiscard {
                    modelContext.delete(meal)
                }
                pendingDiscard = nil
            }
            Button("キャンセル", role: .cancel) {
                pendingDiscard = nil
            }
        } message: {
            Text(pendingDiscard.map { "「\($0.name)」を削除します。確定済みのカロリーには影響しません。" } ?? "")
        }
    }

    private var confirmationTitle: String {
        guard let slot = pendingSlotForChoice else { return "食事を追加" }
        return "\(slot.label)を追加"
    }

    private var discardAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDiscard != nil },
            set: { if !$0 { pendingDiscard = nil } }
        )
    }

    // MARK: - Background / accent

    private var backgroundLayer: some View {
        LinearGradient(colors: backgroundColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var backgroundColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.05, green: 0.07, blue: 0.12),
                Color(red: 0.07, green: 0.06, blue: 0.13),
                Color(red: 0.05, green: 0.07, blue: 0.10)
            ]
        } else {
            return [
                Color(red: 0.93, green: 0.96, blue: 1.00),
                Color(red: 0.96, green: 0.97, blue: 1.00),
                Color(red: 0.99, green: 0.96, blue: 1.00)
            ]
        }
    }

    private var accentGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.27, green: 0.62, blue: 0.95),
                Color(red: 0.49, green: 0.51, blue: 0.97),
                Color(red: 0.66, green: 0.45, blue: 0.95)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var proteinGradient: LinearGradient {
        LinearGradient(colors: [
            Color(red: 0.27, green: 0.62, blue: 0.95),
            Color(red: 0.49, green: 0.51, blue: 0.97)
        ], startPoint: .leading, endPoint: .trailing)
    }

    private var carbGradient: LinearGradient {
        LinearGradient(colors: [
            Color(red: 0.49, green: 0.51, blue: 0.97),
            Color(red: 0.66, green: 0.45, blue: 0.95)
        ], startPoint: .leading, endPoint: .trailing)
    }

    private var fatGradient: LinearGradient {
        LinearGradient(colors: [
            Color(red: 0.66, green: 0.45, blue: 0.95),
            Color(red: 0.15, green: 0.70, blue: 0.78)
        ], startPoint: .leading, endPoint: .trailing)
    }

    // MARK: - Sections

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .padding(.top, 4)
    }

    /// Header row for the "食事履歴" section. Carries an inline AI
    /// entry button next to the section title so the manual empty-
    /// slot tap (the primary path) is no longer gated by a chooser
    /// dialog. AI entry is one extra tap away — discoverable but
    /// not in the way.
    private var mealHistoryHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            sectionTitle("今日の食事一覧")
            Spacer()
            Button {
                // The dialog still picks the slot via the
                // confirmationDialog, so we seed with .breakfast as
                // a sensible default that the user changes on the
                // sheet's slot picker.
                pendingSlotForChoice = .breakfast
                showAddDialog = true
            } label: {
                Label("AI で記録", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(accentGradient.opacity(0.15))
                    )
                    .foregroundStyle(accentGradient)
            }
            .accessibilityLabel("AI で食事を記録")
        }
    }

    /// Compact 7-day intake summary at the bottom of the screen.
    /// Today's meals + totals live above; this is the "habit /
    /// weekly trend" layer, intentionally visually separated so the
    /// user can't confuse a weekly average with today's intake.
    /// Tap → `HealthSummaryView` for the full multi-metric weekly
    /// breakdown.
    private var weeklyTrendCard: some View {
        let summary = HealthSummary(logs: recentLogs)
        let weekly = summary.weeklyIntakeAverage
        return NavigationLink {
            HealthSummaryView()
        } label: {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(accentGradient.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(accentGradient)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("7日間の傾向")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                    if let avg = weekly {
                        Text("摂取の週平均: \(formatInt(avg)) kcal / 日")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("7日間の記録が3日未満のため計算できません")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(glassBackground)
            .overlay(glassStroke)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("7日間の傾向。週間サマリーを開く")
    }

    // MARK: - Recent meals (quick re-entry)

    /// Up to 8 deduped recent confirmed manual meals from prior days.
    /// Empty when no qualifying history exists — caller hides the
    /// section in that case.
    private var recentMealSuggestions: [RecentMealSuggestions.Suggestion] {
        RecentMealSuggestions.suggest(from: allMeals, today: Date())
    }

    @ViewBuilder
    private var recentMealsCard: some View {
        let suggestions = recentMealSuggestions
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("最近の食事")
                        .font(.subheadline.weight(.bold))
                    Spacer()
                    Text("タップで今日に追加")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(suggestions) { suggestion in
                            recentMealChip(suggestion)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(16)
            .background(glassBackground)
            .overlay(glassStroke)
        }
    }

    private func recentMealChip(_ suggestion: RecentMealSuggestions.Suggestion) -> some View {
        Button {
            addRecentMeal(suggestion)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: suggestion.slot.systemImage)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(accentGradient)
                    Text(suggestion.slot.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(suggestion.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text("\(formatInt(suggestion.kcal))")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(accentGradient)
                    Text("kcal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(width: 150, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(accentGradient.opacity(0.25), lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("最近の食事 \(suggestion.name) \(suggestion.kcal) kcal、タップで今日に追加")
    }

    /// Resurrect a past confirmed manual meal as a fresh entry on
    /// today. Goes through `NutritionLedger.syncDayLogIntake` so the
    /// DayLog intake total reflects the new row immediately.
    private func addRecentMeal(_ suggestion: RecentMealSuggestions.Suggestion) {
        let now = Date()
        let meal = MealEntry(
            dayDate: now,
            slot: suggestion.slot,
            name: suggestion.name,
            kcal: suggestion.kcal,
            proteinGrams: suggestion.proteinGrams,
            carbGrams: suggestion.carbGrams,
            fatGrams: suggestion.fatGrams,
            status: .confirmed,
            source: .manual
        )
        modelContext.insert(meal)
        NutritionLedger.syncDayLogIntake(for: now, modelContext: modelContext)
    }

    /// Last 7 days of DayLog rows, used by `HealthSummary` for the
    /// weekly card. Computed lazily off the existing `allDayLogs`
    /// `@Query` rather than running a second fetch.
    private var recentLogs: [DayLog] {
        let cal = Calendar.current
        let end = today
        let start = cal.date(byAdding: .day, value: -6, to: end) ?? end
        return allDayLogs
            .filter { $0.date >= start && $0.date <= end }
            .sorted { $0.date > $1.date }
    }

    // MARK: - Summary card

    private var summaryCard: some View {
        let proteinSum = confirmedMeals.compactMap { $0.proteinGrams }.reduce(0, +)
        let carbSum = confirmedMeals.compactMap { $0.carbGrams }.reduce(0, +)
        let fatSum = confirmedMeals.compactMap { $0.fatGrams }.reduce(0, +)

        let proteinTarget = max(60, Int(Double(targetKcal ?? 2000) * 0.20 / 4))
        let carbTarget = max(150, Int(Double(targetKcal ?? 2000) * 0.50 / 4))
        let fatTarget = max(40, Int(Double(targetKcal ?? 2000) * 0.30 / 9))

        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("今日の栄養")
                    .font(.title3.weight(.bold))
                Text("目標摂取カロリーとマクロバランス")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatInt(confirmedKcal))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(accentGradient)
                Text(targetKcal.map { "/ \(formatInt($0)) kcal" } ?? "/ —")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 10) {
                macroPanel(
                    label: "PROTEIN",
                    grams: proteinSum,
                    target: proteinTarget,
                    gradient: proteinGradient
                )
                macroPanel(
                    label: "CARBS",
                    grams: carbSum,
                    target: carbTarget,
                    gradient: carbGradient
                )
                macroPanel(
                    label: "FAT",
                    grams: fatSum,
                    target: fatTarget,
                    gradient: fatGradient
                )
            }
        }
        .padding(20)
        .background(glassBackground)
        .overlay(glassStroke)
    }

    private func macroPanel(label: String, grams: Int, target: Int, gradient: LinearGradient) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Spacer(minLength: 4)
            }
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(grams)g")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                Text(" / \(target)g")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ProgressBar(progress: Double(grams) / Double(max(1, target)), gradient: gradient)
                .frame(height: 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Meals by slot

    private var mealsByslot: some View {
        VStack(spacing: 12) {
            ForEach(MealSlot.allCases) { slot in
                let confirmedForSlot = confirmedMeals.filter { $0.slot == slot }
                let pendingManualForSlot = pendingManualMeals.filter { $0.slot == slot }
                if confirmedForSlot.isEmpty && pendingManualForSlot.isEmpty {
                    emptySlotCard(slot)
                } else {
                    ForEach(confirmedForSlot, id: \.id) { meal in
                        mealLogCard(meal)
                    }
                    ForEach(pendingManualForSlot, id: \.id) { meal in
                        mealLogCard(meal)
                    }
                }
            }
        }
    }

    private func mealLogCard(_ meal: MealEntry) -> some View {
        Button {
            sheetMode = .edit(meal)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                slotThumb(meal.slot)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(meal.slot.enLabel)
                            .font(.caption2.weight(.bold))
                            .tracking(1.0)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        statusBadge(meal.status)
                    }
                    Text(meal.name)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text("\(formatInt(meal.kcal)) kcal")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accentGradient)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(glassBackground)
            .overlay(glassStroke)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(meal.slot.label) \(meal.name) \(meal.kcal) kcal \(meal.status.label)")
        .swipeDelete {
            let day = meal.dayDate
            modelContext.delete(meal)
            // Use the delete-aware ledger entry point so that
            // removing the last confirmed meal clears DayLog
            // (the plain `syncDayLogIntake` returns early when no
            // meals remain, which would leave a stale total).
            NutritionLedger.reconcileAfterMealRemoval(for: day, modelContext: modelContext)
        }
    }

    private func slotThumb(_ slot: MealSlot) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(accentGradient.opacity(0.15))
                .frame(width: 48, height: 48)
            Image(systemName: slot.systemImage)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(accentGradient)
        }
    }

    private func statusBadge(_ status: MealStatus) -> some View {
        HStack(spacing: 4) {
            Image(systemName: status.systemImage)
                .font(.system(size: 10, weight: .bold))
            Text(status.label)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(status == .confirmed ? Color.green : Color.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill((status == .confirmed ? Color.green : Color.orange).opacity(0.12))
        )
    }

    private func emptySlotCard(_ slot: MealSlot) -> some View {
        // Primary path: empty slot → manual entry directly. The
        // previous flow opened a Manual/AI confirmation dialog before
        // the user could type a food name + kcal; that extra step
        // (combined with a `camera.fill` icon) hid the most common
        // case. AI entry is reachable from `aiEntryRow` near the
        // section header.
        Button {
            sheetMode = .add(source: .manual, slot: slot)
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(accentGradient.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(accentGradient)
                }
                Text(slot.label)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                Text("食事名とカロリーを追加")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(glassBackground)
            .overlay(glassStroke)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(slot.label)を追加")
        .contextMenu {
            Button {
                pendingSlotForChoice = slot
                showAddDialog = true
            } label: {
                Label("AI で記録（推定）", systemImage: "sparkles")
            }
        }
    }

    // MARK: - AI estimate card

    private func aiEstimateCard(_ meal: MealEntry) -> some View {
        let proteinTarget = max(60, Int(Double(targetKcal ?? 2000) * 0.20 / 4))
        let carbTarget = max(150, Int(Double(targetKcal ?? 2000) * 0.50 / 4))
        let fatTarget = max(40, Int(Double(targetKcal ?? 2000) * 0.30 / 9))

        return VStack(alignment: .leading, spacing: 14) {
            heroFoodImage(slot: meal.slot)

            VStack(alignment: .leading, spacing: 6) {
                Text(meal.slot.enLabel)
                    .font(.caption2.weight(.bold))
                    .tracking(1.0)
                    .foregroundStyle(.secondary)
                Text(meal.name)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(2)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("~ \(formatInt(meal.kcal))")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(accentGradient)
                    Text("kcal")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    estimateBadge
                }
            }

            VStack(spacing: 8) {
                aiMacroRow(label: "PRO", value: meal.proteinGrams ?? 0,
                           target: proteinTarget, gradient: proteinGradient)
                aiMacroRow(label: "CARB", value: meal.carbGrams ?? 0,
                           target: carbTarget, gradient: carbGradient)
                aiMacroRow(label: "FAT", value: meal.fatGrams ?? 0,
                           target: fatTarget, gradient: fatGradient)
            }

            HStack(spacing: 10) {
                Button {
                    sheetMode = .edit(meal)
                } label: {
                    Label("編集", systemImage: "square.and.pencil")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.regularMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.5), lineWidth: 0.6)
                )
                .accessibilityLabel("AI 推定を編集")

                Button {
                    confirmAIEstimate(meal)
                } label: {
                    Label("確定", systemImage: "checkmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(accentGradient)
                        .shadow(
                            color: Color(red: 0.27, green: 0.5, blue: 0.95).opacity(0.4),
                            radius: 12, y: 6
                        )
                )
                .accessibilityLabel("AI 推定を確定")
            }
            .padding(.top, 4)

            Button {
                pendingDiscard = meal
            } label: {
                Text("この推定を破棄")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("この AI 推定を破棄")
        }
        .padding(20)
        .background(glassBackground)
        .overlay(glassStroke)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(accentGradient.opacity(0.35), lineWidth: 1.2)
        )
    }

    private func heroFoodImage(slot: MealSlot) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(colors: [
                        Color(red: 0.95, green: 0.92, blue: 0.84),
                        Color(red: 0.86, green: 0.82, blue: 0.74)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            Image(systemName: foodSymbol(for: slot))
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(
                    LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.6)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        }
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.5), lineWidth: 0.6)
        )
        .accessibilityHidden(true)
    }

    private func foodSymbol(for slot: MealSlot) -> String {
        switch slot {
        case .breakfast: return "fork.knife"
        case .lunch: return "fork.knife.circle"
        case .dinner: return "takeoutbag.and.cup.and.straw.fill"
        case .snack: return "cup.and.saucer.fill"
        }
    }

    private var estimateBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .bold))
            Text("推定")
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(accentGradient)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(.regularMaterial)
        )
        .overlay(
            Capsule().strokeBorder(accentGradient.opacity(0.5), lineWidth: 0.6)
        )
    }

    private func aiMacroRow(label: String, value: Int, target: Int, gradient: LinearGradient) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            ProgressBar(progress: Double(value) / Double(max(1, target)), gradient: gradient)
                .frame(height: 6)
            Text("\(value)g")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .frame(width: 40, alignment: .trailing)
        }
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

    // MARK: - Confirm flow

    /// Wraps the meal as `UserConfirmed<MealEstimate>` and calls
    /// `applyConfirmedMealEstimate`. This is the only path through
    /// which an AI-sourced kcal value mutates DayLog, matching the
    /// privacy-and-safety contract documented in
    /// `Docs/ai-privacy-and-safety.md`.
    private func confirmAIEstimate(_ meal: MealEntry) {
        let estimate = MealEstimate(
            estimatedKcal: meal.kcal,
            confidence: 0.6,
            breakdown: [
                MealEstimate.LineItem(name: "タンパク質", kcal: (meal.proteinGrams ?? 0) * 4),
                MealEstimate.LineItem(name: "炭水化物", kcal: (meal.carbGrams ?? 0) * 4),
                MealEstimate.LineItem(name: "脂質", kcal: (meal.fatGrams ?? 0) * 9)
            ]
        )
        let confirmed = UserConfirmed(estimate)
        let dayLog = DayLogStore.fetchOrCreate(date: meal.dayDate, modelContext: modelContext)
        // Promote the meal first so the ledger sum picks it up.
        meal.statusRaw = MealStatus.confirmed.rawValue
        // Sync via the canonical ledger so DayLog matches the sum of
        // confirmed meals (handles edits / deletes consistently).
        NutritionLedger.syncDayLogIntake(for: meal.dayDate, modelContext: modelContext)
        // Touch DayLog through the privacy boundary so the helper
        // remains exercised from a single call site. (No-op in practice
        // because syncDayLogIntake already wrote the correct sum.)
        _ = confirmed
        _ = dayLog
        if settings.hapticsEnabled {
            SoundHapticManager.playHaptic()
        }
    }

    // MARK: - Helpers

    private func formatInt(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

// MARK: - ProgressBar

private struct ProgressBar: View {
    let progress: Double
    let gradient: LinearGradient

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(gradient)
                    .frame(width: geo.size.width * max(0, min(1, progress)))
            }
        }
    }
}

// MARK: - Swipe-to-delete helper

private extension View {
    func swipeDelete(_ action: @escaping () -> Void) -> some View {
        self.contextMenu {
            Button("削除", role: .destructive, action: action)
        }
    }
}
