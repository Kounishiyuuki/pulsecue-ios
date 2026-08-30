//
//  BodyGoalsSettingsSection.swift
//  Pulse Cue
//
//  体と目標 — height, age, sex, activity factor, the figures derived from
//  them, and the weight goal.
//
//  This section owns the weight it calculates from, because it is the only
//  part of settings that has an opinion about it. Two rules govern that and
//  neither is arbitrary — both are bugs this screen has already shipped:
//
//  **Only the weight is cached.** BMR, TDEE and the calorie target are derived
//  on every read from the profile as it stands. Caching them too, which this
//  screen used to do, left them showing figures from before the user's last
//  edit — you could change your height and watch your BMR not move.
//
//  **The weight is not bounded to the display window.** It comes through
//  `BodyMetrics.resolveCurrentWeightKg`, not from `recentLogs`. A presentation
//  range has no business deciding domain truth: when it did, someone who last
//  weighed in three weeks ago had their target computed as though no weight
//  existed, while Home and Me showed the figure perfectly well.
//

import SwiftData
import SwiftUI

struct BodyGoalsSettingsSection: View {
    let profile: UserProfile
    /// Called after a successful save, so the shell can show its toast. The
    /// toast overlays the whole screen and is not this section's to place.
    let onSaved: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore

    /// 14 days of DayLog, for today's intake in the goal-gap row. A display
    /// window, and used only as one.
    @Query private var recentLogs: [DayLog]

    /// Every day log, as the source of the weight-refresh signal.
    ///
    /// `recentLogs` cannot serve: a weigh-in backfilled outside its fortnight
    /// would not disturb it, and the cached weight would go stale on screen.
    @Query(sort: [SortDescriptor(\DayLog.date, order: .reverse)])
    private var allDayLogs: [DayLog]

    @State private var currentWeightKg: Double?

    init(profile: UserProfile, onSaved: @escaping () -> Void) {
        self.profile = profile
        self.onSaved = onSaved
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -13, to: today) ?? today
        self._recentLogs = Query(
            filter: #Predicate<DayLog> { $0.date >= start },
            sort: [SortDescriptor(\DayLog.date, order: .reverse)]
        )
    }

    var body: some View {
        @Bindable var profile = profile
        VStack(alignment: .leading, spacing: 18) {
            titleBlock
            personalDataCard(profile: $profile)
            HStack(spacing: 12) {
                bmrCard
                tdeeCard
            }
            goalCard(profile: $profile)
            saveButton
        }
        .task { refreshCurrentWeight() }
        .onChange(of: latestWeightSignature) { _, _ in refreshCurrentWeight() }
    }

    // MARK: - Derived figures

    /// The derived figures for the profile, right now.
    ///
    /// Recomputed rather than stored, so editing height, age, sex, activity or
    /// the goal updates them immediately. Pure arithmetic — no fetch happens
    /// here, so an edit costs nothing but the calculation.
    private var metrics: BodyMetrics {
        BodyMetrics.derive(profile: profile, currentWeightKg: currentWeightKg)
    }

    private var summary: HealthSummary { HealthSummary(logs: recentLogs) }

    /// Refresh signal for the cached weight; see `changeSignature` for why the
    /// array itself is not enough.
    private var latestWeightSignature: String {
        LatestBodyWeightResolver.changeSignature(for: allDayLogs)
    }

    private func refreshCurrentWeight() {
        currentWeightKg = BodyMetrics.resolveCurrentWeightKg(
            modelContext: modelContext
        )
    }

    // MARK: - Title

    private var titleBlock: some View {
        HStack(spacing: 9) {
            Image(systemName: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
            Text("パーソナルデータと目標の管理")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Personal data

    private func personalDataCard(profile: Bindable<UserProfile>) -> some View {
        SettingsChrome.featuredGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SettingsChrome.sectionHeader(icon: "person.fill", title: "パーソナルデータ")

                SettingsChrome.inlineNumberCell(
                    label: "身長",
                    value: profile.wrappedValue.heightCm,
                    range: 120...220,
                    step: 1,
                    unit: "cm",
                    binding: profile.heightCm,
                    identifier: "height-stepper"
                )
                SettingsChrome.inlineNumberCell(
                    label: "年齢",
                    value: profile.wrappedValue.ageYears,
                    range: 10...100,
                    step: 1,
                    unit: "歳",
                    binding: profile.ageYears
                )
                SettingsChrome.pickerCell(label: "性別", selection: profile.biologicalSex) { sex in
                    Text(sex.label).tag(sex)
                }
                SettingsChrome.pickerCell(label: "活動係数", selection: profile.activityFactor) { factor in
                    Text(factor.label).tag(factor)
                }
            }
        }
    }

    // MARK: - BMR / TDEE

    private var bmrCard: some View {
        SettingsChrome.summaryCard(
            label: "基礎代謝 (BMR)",
            value: metrics.bmr.map { NumberFormat.int($0) } ?? "—",
            unit: "kcal",
            gradient: SettingsChrome.accentGradient(colorScheme),
            identifier: "bmr-summary"
        )
    }

    private var tdeeCard: some View {
        SettingsChrome.summaryCard(
            label: "1日の総消費 (TDEE)",
            value: metrics.tdee.map { NumberFormat.int($0) } ?? "—",
            unit: "kcal",
            gradient: SettingsChrome.tealGradient(colorScheme)
        )
    }

    // MARK: - Goal

    private func goalCard(profile: Bindable<UserProfile>) -> some View {
        SettingsChrome.glassCard {
            VStack(alignment: .leading, spacing: 14) {
                SettingsChrome.sectionHeader(icon: "flag.fill", title: "目標設定")

                SettingsChrome.inlineDoubleCell(
                    label: "目標体重",
                    helper: currentWeightKg
                        .map { "現在の体重: \(NumberFormat.weight($0)) kg" }
                        ?? "現在の体重: 未入力",
                    value: profile.wrappedValue.goalWeightKg,
                    range: 30...150,
                    step: 0.5,
                    unit: "kg",
                    binding: profile.goalWeightKg
                )

                SettingsChrome.inlineDoubleCell(
                    label: "週あたりの変化量",
                    helper: "推奨: -0.5 〜 +0.5 kg/週",
                    value: profile.wrappedValue.weeklyChangeKg,
                    range: -1.5...1.5,
                    step: 0.1,
                    unit: "kg",
                    binding: profile.weeklyChangeKg
                )

                SettingsChrome.derivedRow(
                    label: "目標摂取カロリー",
                    value: metrics.targetIntakeKcal
                        .map { "\(NumberFormat.int($0)) kcal/日" } ?? "—"
                )
                SettingsChrome.derivedRow(
                    label: "今日の目標差分",
                    value: todayGoalGapText,
                    valueStyle: todayGoalGapStyle
                )
                healthTargetLink
            }
        }
    }

    private var healthTargetLink: some View {
        NavigationLink {
            HealthTargetSettingsView()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("曜日・日付ごとの目標")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("睡眠・摂取・運動・バランスをカスタマイズ")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }

    private var todayGoalGapText: String {
        guard let target = metrics.targetIntakeKcal else { return "—" }
        if summary.todayIntake == nil {
            return "未入力 (目標 \(NumberFormat.int(target)) kcal)"
        }
        let actual = summary.todayIntake ?? 0
        let gap = actual - target
        let sign = gap >= 0 ? "+" : ""
        return "\(sign)\(NumberFormat.int(gap)) kcal"
    }

    private var todayGoalGapStyle: Color {
        guard let target = metrics.targetIntakeKcal,
              let actual = summary.todayIntake
        else { return .secondary }
        let gap = actual - target
        if abs(gap) <= Self.goalGapToleranceKcal { return .green }
        return gap > 0 ? .orange : .blue
    }

    /// How far today's intake may sit from the target and still read as "on
    /// track". A domain judgement, not a design token: a hundred kilocalories
    /// is roughly a rounding error in a day's food, and colouring that as a
    /// miss would make the row cry wolf every day.
    private static let goalGapToleranceKcal = 100

    // MARK: - Save

    private var saveButton: some View {
        Button {
            handleSaveTapped()
        } label: {
            Text("保存する")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(AppTheme.accentFilled)
                        .shadow(
                            color: Color(red: 0.27, green: 0.5, blue: 0.95).opacity(0.35),
                            radius: 18, x: 0, y: 10
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("設定を保存")
    }

    private func handleSaveTapped() {
        // Each control already wrote through to UserDefaults via @Published
        // didSet. The CTA gives the user explicit confirmation, dismisses
        // the keyboard, and runs the success haptic if enabled.
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
        if settings.hapticsEnabled {
            SoundHapticManager.playHaptic()
        }
        onSaved()
    }
}
