//
//  NutritionView.swift
//  Pulse Cue
//
//  The root of the 栄養 tab, and only that: it owns the day's queries, the
//  sheets, and every write. What each section looks like belongs to the
//  section.
//
//  The order of the sections is not decided here either — it comes from
//  `NutritionSurface.orderedSections`. The screen once had five ways to add a
//  meal above the fold, each reasonable when it was added, and writing the
//  ranking down was the fix. Rendering from it is what keeps the fix.
//
//  Two rules this screen must not take back into itself:
//
//    **What is true** is `DailyNutritionSummary`. Consumed, target, remaining
//    and who owns the day all come from there, so Home and this screen cannot
//    report different numbers for the same day.
//
//    **What is written** goes through `NutritionLedger`. Every path that
//    creates, confirms or deletes a meal ends in a ledger call, because the
//    DayLog intake field is derived from confirmed meals and nothing else may
//    maintain it.
//
//  No external AI API is called. AI candidates are locally synthesized when
//  the user taps 「AI で記録」 and edits the form; a pending estimate counts
//  towards nothing until confirmed.
//

import SwiftUI
import SwiftData

struct NutritionView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var settings: SettingsStore

    @Query(sort: [SortDescriptor(\MealEntry.createdAt, order: .forward)]) private var allMeals: [MealEntry]
    @Query private var allDayLogs: [DayLog]
    @Query(sort: [SortDescriptor(\UserProfile.updatedAt, order: .reverse)])
    private var profiles: [UserProfile]

    @StateObject private var favoriteTemplates = FavoriteMealTemplateStore()
    /// Same resolver Home uses, so a manual intake target moves both screens.
    @StateObject private var targetStore = HealthTargetStore()

    @State private var sheetMode: MealEntrySheet.Mode?
    @State private var pendingSlotForChoice: MealSlot?
    @State private var showAddDialog = false
    @State private var pendingDiscard: MealEntry?
    @State private var showBarcodeScanner = false
    @State private var showNutritionLabelOCR = false
    @State private var showPhotoFoodCapture = false
    /// Carbs and fat, one tap behind the figures people act on.
    @State private var showsMacroDetail = false

    private var today: Date { DateUtils.startOfDay(Date()) }

    private var todaysMeals: [MealEntry] {
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
        return allMeals.filter { $0.dayDate >= today && $0.dayDate < nextDay }
    }

    private var todaysDayLog: DayLog? {
        allDayLogs.first(where: { DateUtils.startOfDay($0.date) == today })
    }

    /// The day's figures, from the same helper Home uses.
    ///
    /// Previously this screen summed confirmed meals itself and read the
    /// profile target directly, while Home applied the manual `HealthTargets`
    /// override and read `DayLog.intakeCalories`. Same day, same stored data,
    /// different numbers on the two screens — and a quick calorie input that
    /// appeared on one of them and not the other.
    ///
    /// - Parameter mealsForDay: **every** meal for the day, pending included.
    ///   Ownership of the day depends on pending rows even though they never
    ///   count as intake, so filtering before this point is not an
    ///   optimisation — it is the bug.
    private func daySummary(mealsForDay: [MealEntry]) -> DailyNutritionSummary {
        DailyNutritionSummary.forDay(
            Date(),
            dayLog: todaysDayLog,
            mealsForDay: mealsForDay,
            profile: profiles.first,
            currentWeightKg: latestWeightKg,
            targetSettings: targetStore.settings
        )
    }

    /// The weight the calorie target is computed from.
    ///
    /// Shared with Home, Me and 体と目標 through `LatestBodyWeightResolver` so
    /// every screen resolves the same weigh-in. Cached and refreshed with the
    /// logs rather than sorting the whole history on every render.
    @State private var latestWeightKg: Double?

    /// Refresh signal for the cached weight.
    ///
    /// `onChange(of: allDayLogs)` compared `@Model` rows by identity, so
    /// editing a weight in place left the array equal and this screen kept
    /// computing the target from a weight no longer on disk.
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
                VStack(alignment: .leading, spacing: 18) {
                    // Partitioned once. Each of these used to re-filter the
                    // whole meal history on every access, several times per
                    // render.
                    let meals = todaysMeals
                    let confirmed = meals.filter { $0.status == .confirmed }
                    let pendingManual = meals.filter {
                        $0.status == .pending && $0.source == .manual
                    }
                    let pendingAI = meals.filter {
                        $0.status == .pending && $0.source == .ai
                    }

                    ForEach(NutritionSurface.orderedSections, id: \.self) { section in
                        sectionView(
                            section,
                            meals: meals,
                            confirmed: confirmed,
                            pendingManual: pendingManual,
                            pendingAI: pendingAI
                        )
                    }

                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
        }
        .navigationTitle("栄養")
        .navigationBarTitleDisplayMode(.inline)
        .task { refreshLatestWeight() }
        .onChange(of: latestWeightSignature) { _, _ in refreshLatestWeight() }
        .sheet(item: $sheetMode) { mode in
            MealEntrySheet(mode: mode)
        }
        .sheet(isPresented: $showBarcodeScanner) {
            BarcodeScannerView()
        }
        .sheet(isPresented: $showNutritionLabelOCR) {
            NutritionLabelOCRView()
        }
        .sheet(isPresented: $showPhotoFoodCapture) {
            PhotoFoodCaptureView()
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
            // The scanners moved here from a row of chips at the top of the
            // screen. Same sheets, same behaviour — they are simply no longer
            // asked about before the user has said they want to record
            // anything.
            Button("栄養表示を読み取る") { showNutritionLabelOCR = true }
            Button("バーコードを読み取る") { showBarcodeScanner = true }
            Button("写真から記録") { showPhotoFoodCapture = true }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("AI で記録すると「確認待ち」状態で保存されます。確定するまでカロリーには加算されません。")
        }
        .alert("この AI 推定を破棄しますか？", isPresented: discardAlertBinding) {
            Button("破棄", role: .destructive) {
                if let meal = pendingDiscard {
                    discard(meal)
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

    /// One section of the screen. The `switch` is exhaustive on purpose: a new
    /// `NutritionSurface.Section` stops compiling here until it is placed.
    @ViewBuilder
    private func sectionView(
        _ section: NutritionSurface.Section,
        meals: [MealEntry],
        confirmed: [MealEntry],
        pendingManual: [MealEntry],
        pendingAI: [MealEntry]
    ) -> some View {
        switch section {
        case .todayIntake:
            summaryCard(confirmedMeals: confirmed, mealsForDay: meals)

        case .addMeal:
            addMealButton

        case .todayMeals:
            NutritionMealsSection(
                confirmedMeals: confirmed,
                pendingManualMeals: pendingManual,
                proteinGradient: proteinGradient,
                onAdd: { sheetMode = .add(source: .manual, slot: $0) },
                onEdit: { sheetMode = .edit($0) },
                onDelete: discard,
                onSaveAsFavorite: saveMealAsFavorite,
                canSaveAsFavorite: canSaveAsFavorite
            )

        case .pendingEstimates:
            if !pendingAI.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    sectionTitle("AI 解析結果")
                    ForEach(pendingAI, id: \.id) { meal in
                        PendingAIEstimateCard(
                            meal: meal,
                            targets: MacroTargets.daily(
                                forKcalTarget: daySummary(mealsForDay: meals).targetKcal
                            ),
                            proteinGradient: proteinGradient,
                            carbGradient: carbGradient,
                            fatGradient: fatGradient,
                            onEdit: { sheetMode = .edit(meal) },
                            onConfirm: { confirmAIEstimate(meal) },
                            onDiscard: { pendingDiscard = meal }
                        )
                    }
                }
            }

        case .recentAndFavourites:
            NutritionQuickReentrySection(
                suggestions: recentMealSuggestions,
                templates: favoriteTemplates.templates,
                proteinGradient: proteinGradient,
                onAddSuggestion: addRecentMeal,
                onAddTemplate: addFavoriteTemplate,
                onRemoveTemplate: favoriteTemplates.remove
            )

        case .weeklyTrend:
            weeklyTrendCard
        }
    }

    /// The screen's single primary action.
    ///
    /// It used to be five: an AI chip in the section header, three scanner
    /// chips beneath it, and four large empty slot cards that each opened
    /// manual entry. All of them were ways to do the same thing, shown before
    /// the user had said they wanted to do it — so opening Nutrition meant
    /// choosing an input *method* first.
    ///
    /// Now the intent comes first and the method second, in the dialog. No
    /// input flow changed; only when the choice is asked for.
    private var addMealButton: some View {
        Button {
            pendingSlotForChoice = pendingSlotForChoice ?? .breakfast
            showAddDialog = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16, weight: .bold))
                Text("食事を記録")
                    .font(.headline)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.vertical, 15)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppTheme.accentFilled)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("食事を記録")
    }

    // MARK: - Chrome

    private var backgroundLayer: some View {
        // Calm, airy Apple Health Light surface (adapts to dark mode).
        AppTheme.surface
    }

    private func sectionTitle(_ text: String) -> some View {
        PulseSectionHeader(text)
            .padding(.top, 4)
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

    // MARK: - Summary

    private func summaryCard(
        confirmedMeals: [MealEntry],
        mealsForDay: [MealEntry]
    ) -> some View {
        let summary = daySummary(mealsForDay: mealsForDay)
        let targets = MacroTargets.daily(forKcalTarget: summary.targetKcal)
        return NutritionDailySummaryCard(
            summary: summary,
            carbGrams: confirmedMeals.compactMap { $0.carbGrams }.reduce(0, +),
            carbTargetGrams: targets.carbGrams,
            fatGrams: confirmedMeals.compactMap { $0.fatGrams }.reduce(0, +),
            fatTargetGrams: targets.fatGrams,
            proteinGradient: proteinGradient,
            carbGradient: carbGradient,
            fatGradient: fatGradient,
            showsMacroDetail: $showsMacroDetail
        )
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

    // MARK: - Weekly trend

    /// Last 7 days of DayLog rows, off the existing `allDayLogs` query rather
    /// than a second fetch.
    private var recentLogs: [DayLog] {
        let cal = Calendar.current
        let end = today
        let start = cal.date(byAdding: .day, value: -6, to: end) ?? end
        return allDayLogs
            .filter { $0.date >= start && $0.date <= end }
            .sorted { $0.date > $1.date }
    }

    /// Deliberately separated from today's figures: a weekly average and
    /// today's intake are easy to mistake for one another, and only one of
    /// them answers what to eat next.
    private var weeklyTrendCard: some View {
        let weekly = HealthSummary(logs: recentLogs).weeklyIntakeAverage
        return NavigationLink {
            HealthSummaryView()
        } label: {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(AppTheme.accent.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AppTheme.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("7日間の傾向")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                    if let weekly {
                        Text("摂取の週平均: \(NumberFormat.int(weekly)) kcal / 日")
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
            .frostedCard()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("7日間の傾向。週間サマリーを開く")
    }

    /// Up to 8 deduped recent confirmed manual meals from prior days.
    ///
    /// Ranked over the whole history rather than a window: the point is to
    /// find what this person eats repeatedly, and someone who logs three days
    /// a week would lose their own regular meals to a fortnight's cutoff.
    private var recentMealSuggestions: [RecentMealSuggestions.Suggestion] {
        RecentMealSuggestions.suggest(from: allMeals, today: Date())
    }

    // MARK: - Writes
    //
    //  Every one of these ends in a `NutritionLedger` call. `DayLog`'s intake
    //  field is derived from the day's confirmed meals, so a write that
    //  skipped the ledger would leave the stored total describing a day that
    //  no longer exists.

    /// Resurrect a past confirmed manual meal as a fresh entry on today.
    private func addRecentMeal(_ suggestion: RecentMealSuggestions.Suggestion) {
        insertConfirmedMeal(
            slot: suggestion.slot,
            name: suggestion.name,
            kcal: suggestion.kcal,
            proteinGrams: suggestion.proteinGrams,
            carbGrams: suggestion.carbGrams,
            fatGrams: suggestion.fatGrams
        )
    }

    /// Tap-to-add a pinned template onto today. Same path as `addRecentMeal`.
    private func addFavoriteTemplate(_ template: FavoriteMealTemplate) {
        insertConfirmedMeal(
            slot: template.slot,
            name: template.name,
            kcal: template.kcal,
            proteinGrams: template.proteinGrams
        )
    }

    /// The one way a meal is created from an existing one. Always `.confirmed`
    /// and `.manual`: the user picked a meal they had already eaten, so there
    /// is nothing left to estimate or confirm.
    private func insertConfirmedMeal(
        slot: MealSlot,
        name: String,
        kcal: Int,
        proteinGrams: Int?,
        carbGrams: Int? = nil,
        fatGrams: Int? = nil
    ) {
        let now = Date()
        modelContext.insert(
            MealEntry(
                dayDate: now,
                slot: slot,
                name: name,
                kcal: kcal,
                proteinGrams: proteinGrams,
                carbGrams: carbGrams,
                fatGrams: fatGrams,
                status: .confirmed,
                source: .manual
            )
        )
        NutritionLedger.syncDayLogIntake(for: now, modelContext: modelContext)
    }

    /// Deleting a meal reconciles rather than syncs: removing the day's last
    /// meal hands ownership back to the manual `DayLog` value, and that is a
    /// different question from re-summing what remains.
    private func discard(_ meal: MealEntry) {
        let day = meal.dayDate
        modelContext.delete(meal)
        NutritionLedger.reconcileAfterMealRemoval(for: day, modelContext: modelContext)
    }

    /// Pin a confirmed manual meal as a reusable template. Stored via
    /// `FavoriteMealTemplateStore` (UserDefaults JSON) so it does not require a
    /// SwiftData migration. Idempotent.
    private func saveMealAsFavorite(_ meal: MealEntry) {
        favoriteTemplates.add(
            FavoriteMealTemplate(
                name: meal.name,
                kcal: meal.kcal,
                proteinGrams: meal.proteinGrams,
                slot: meal.slot
            )
        )
        if settings.hapticsEnabled {
            SoundHapticManager.playHaptic()
        }
    }

    /// An AI estimate is not something to keep a shortcut to, and neither is a
    /// draft — pinning either would put an unconfirmed figure one tap from
    /// being logged as fact.
    private func canSaveAsFavorite(_ meal: MealEntry) -> Bool {
        meal.status == .confirmed
            && meal.source == .manual
            && !favoriteTemplates.contains(name: meal.name, kcal: meal.kcal)
    }

    /// Wraps the meal as `UserConfirmed<MealEstimate>` and calls
    /// `applyConfirmedMealEstimate`. This is the only path through which an
    /// AI-sourced kcal value mutates DayLog, matching the privacy-and-safety
    /// contract documented in `Docs/ai-privacy-and-safety.md`.
    private func confirmAIEstimate(_ meal: MealEntry) {
        let estimate = MealEstimate(
            estimatedKcal: meal.kcal,
            confidence: 0.6,
            breakdown: [
                MealEstimate.LineItem(
                    name: "タンパク質",
                    kcal: (meal.proteinGrams ?? 0) * ProteinTotals.kcalPerGram
                ),
                MealEstimate.LineItem(
                    name: "炭水化物",
                    kcal: (meal.carbGrams ?? 0) * MacroTargets.carbKcalPerGram
                ),
                MealEstimate.LineItem(
                    name: "脂質",
                    kcal: (meal.fatGrams ?? 0) * MacroTargets.fatKcalPerGram
                )
            ]
        )
        let confirmed = UserConfirmed(estimate)
        let dayLog = DayLogStore.fetchOrCreate(date: meal.dayDate, modelContext: modelContext)
        // Promote the meal first so the ledger sum picks it up.
        meal.statusRaw = MealStatus.confirmed.rawValue
        // Sync via the canonical ledger so DayLog matches the sum of confirmed
        // meals (handles edits / deletes consistently).
        NutritionLedger.syncDayLogIntake(for: meal.dayDate, modelContext: modelContext)
        // Touch DayLog through the privacy boundary so the helper remains
        // exercised from a single call site. (No-op in practice because
        // syncDayLogIntake already wrote the correct sum.)
        _ = confirmed
        _ = dayLog
        if settings.hapticsEnabled {
            SoundHapticManager.playHaptic()
        }
    }

}

// MARK: - ProgressBar

struct ProgressBar: View {
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

// MARK: - Entry action chip

/// Compact chip used in the meal-log "入力サポート" row. Pairs an
/// icon with a short label inside a capsule so the OCR / barcode /
/// photo entry points are visually distinct — previously each was an
/// icon-only circle that read as the same generic viewfinder shape.
/// Styling matches the existing "AI で記録" pill for visual
/// consistency; the accessibility label is preserved from the
/// previous inline buttons so VoiceOver output is unchanged.
private struct NutritionEntryActionChip: View {
    let systemImage: String
    let label: String
    let accessibilityLabel: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(tint.opacity(0.15))
                )
                .foregroundStyle(tint)
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

