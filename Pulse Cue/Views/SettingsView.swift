//
//  SettingsView.swift
//  Pulse Cue
//
//  Created by Codex.
//
//  Premium liquid-glass Settings / Profile / Goals screen. Mirrors the
//  visual direction of Today and Runner: gradient background + frosted
//  rounded cards + accent gradient highlights.
//
//  The screen surfaces:
//    1. Brand header (PulseCue logo + bell).
//    2. 設定 title + subtitle.
//    3. パーソナルデータ card (height / age / sex / activity factor).
//    4. 基礎代謝 (BMR) and 1日の総消費 (TDEE) summary cards.
//    5. 目標設定 (goal weight, weekly rate, target intake, today gap).
//    6. 連携と AI (HealthKit preview + AI transmission scope).
//    7. アプリ設定 (notifications / sound / haptics / always-on,
//       preserving the prior P0 toggles + status copy).
//    8. アプリ情報 (name + version).
//    9. 「保存する」CTA: cosmetic confirmation since each control
//       writes through SettingsStore on change.
//

import SwiftUI
import SwiftData
import UserNotifications

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var settings: SettingsStore

    // 14 days of DayLog so we can pull "current weight" + today's intake
    // for the goal-gap card without a second SwiftData read.
    @Query private var recentLogs: [DayLog]

    // UserProfile is now the source of truth for profile / goal fields.
    @Query(sort: [SortDescriptor(\UserProfile.updatedAt, order: .reverse)])
    private var profiles: [UserProfile]

    @State private var notificationAuthStatus: UNAuthorizationStatus = .notDetermined
    @State private var showNotificationAlert = false
    @State private var showSavedToast = false

    init() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -13, to: today) ?? today
        self._recentLogs = Query(
            filter: #Predicate<DayLog> { $0.date >= start },
            sort: [SortDescriptor(\DayLog.date, order: .reverse)]
        )
    }

    private var summary: HealthSummary { HealthSummary(logs: recentLogs) }
    private var currentWeightKg: Double? { summary.latestWeight }

    private var resolvedProfile: UserProfile? { profiles.first }

    private func bmrValue(for profile: UserProfile) -> Int? {
        profile.bmr(currentWeightKg: currentWeightKg)
    }
    private func tdeeValue(for profile: UserProfile) -> Int? {
        profile.tdee(currentWeightKg: currentWeightKg)
    }
    private func targetIntakeValue(for profile: UserProfile) -> Int? {
        profile.targetIntake(currentWeightKg: currentWeightKg)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            backgroundLayer.ignoresSafeArea()

            if let profile = resolvedProfile {
                content(profile: profile)
            } else {
                ProgressView("読み込み中…")
                    .task {
                        _ = UserProfileStore.fetchOrCreate(modelContext: modelContext)
                    }
            }

            if showSavedToast {
                savedToast
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .alert("通知が無効です", isPresented: $showNotificationAlert) {
            Button("了解", role: .cancel) {}
        } message: {
            Text("iOS の設定アプリで通知を許可してください。")
        }
        .onAppear { refreshNotificationStatus() }
    }

    @ViewBuilder
    private func content(profile profileObject: UserProfile) -> some View {
        @Bindable var profile = profileObject
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                brandHeader
                titleBlock
                personalDataCard(profile: $profile)
                HStack(spacing: 12) {
                    bmrCard(profile: profile)
                    tdeeCard(profile: profile)
                }
                goalCard(profile: $profile)
                integrationsCard
                appSettingsCard
                appInfoCard
                saveButton
                Color.clear.frame(height: 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    // MARK: - Background

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

    private var tealGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.15, green: 0.70, blue: 0.78),
                Color(red: 0.27, green: 0.62, blue: 0.95)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Header / title

    private var brandHeader: some View {
        HStack {
            ZStack {
                Circle().fill(accentGradient).frame(width: 32, height: 32)
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Spacer()
            Text("PulseCue")
                .font(.headline.weight(.semibold))
            Spacer()
            Image(systemName: "bell")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
        }
        .padding(.top, 4)
        .accessibilityHidden(true)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("設定")
                .font(.system(size: 32, weight: .bold))
            Text("パーソナルデータと目標の管理")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Personal data card

    private func personalDataCard(profile: Bindable<UserProfile>) -> some View {
        glassCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(icon: "person.fill", title: "パーソナルデータ")

                inlineNumberCell(
                    label: "身長",
                    value: profile.wrappedValue.heightCm,
                    range: 120...220,
                    step: 1,
                    unit: "cm",
                    binding: profile.heightCm
                )
                inlineNumberCell(
                    label: "年齢",
                    value: profile.wrappedValue.ageYears,
                    range: 10...100,
                    step: 1,
                    unit: "歳",
                    binding: profile.ageYears
                )
                pickerCell(label: "性別", selection: profile.biologicalSex) { sex in
                    Text(sex.label).tag(sex)
                }
                pickerCell(label: "活動係数", selection: profile.activityFactor) { factor in
                    Text(factor.label).tag(factor)
                }
            }
        }
    }

    // MARK: - BMR / TDEE summary cards

    private func bmrCard(profile: UserProfile) -> some View {
        summaryCard(
            label: "基礎代謝 (BMR)",
            value: bmrValue(for: profile).map { formatInt($0) } ?? "—",
            unit: "kcal",
            gradient: accentGradient
        )
    }

    private func tdeeCard(profile: UserProfile) -> some View {
        summaryCard(
            label: "1日の総消費 (TDEE)",
            value: tdeeValue(for: profile).map { formatInt($0) } ?? "—",
            unit: "kcal",
            gradient: tealGradient
        )
    }

    private func summaryCard(label: String, value: String, unit: String, gradient: LinearGradient) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(gradient)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(glassBackground)
        .overlay(glassStroke)
    }

    // MARK: - Goal card

    private func goalCard(profile: Bindable<UserProfile>) -> some View {
        glassCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(icon: "flag.fill", title: "目標設定")

                inlineDoubleCell(
                    label: "目標体重",
                    helper: currentWeightKg.map { "現在の体重: \(formatWeight($0)) kg" } ?? "現在の体重: 未入力",
                    value: profile.wrappedValue.goalWeightKg,
                    range: 30...150,
                    step: 0.5,
                    unit: "kg",
                    binding: profile.goalWeightKg
                )

                inlineDoubleCell(
                    label: "週あたりの変化量",
                    helper: "推奨: -0.5 〜 +0.5 kg/週",
                    value: profile.wrappedValue.weeklyChangeKg,
                    range: -1.5...1.5,
                    step: 0.1,
                    unit: "kg",
                    binding: profile.weeklyChangeKg
                )

                derivedRow(
                    label: "目標摂取カロリー",
                    value: targetIntakeValue(for: profile.wrappedValue).map { "\(formatInt($0)) kcal/日" } ?? "—"
                )
                derivedRow(
                    label: "今日の目標差分",
                    value: todayGoalGapText(for: profile.wrappedValue),
                    valueStyle: todayGoalGapStyle(for: profile.wrappedValue)
                )
            }
        }
    }

    private func todayGoalGapText(for profile: UserProfile) -> String {
        guard let target = targetIntakeValue(for: profile) else { return "—" }
        if summary.todayIntake == nil {
            return "未入力 (目標 \(formatInt(target)) kcal)"
        }
        let actual = summary.todayIntake ?? 0
        let gap = actual - target
        let sign = gap >= 0 ? "+" : ""
        return "\(sign)\(formatInt(gap)) kcal"
    }

    private func todayGoalGapStyle(for profile: UserProfile) -> Color {
        guard let target = targetIntakeValue(for: profile), let actual = summary.todayIntake else {
            return .secondary
        }
        let gap = actual - target
        if abs(gap) <= 100 { return .green }
        return gap > 0 ? .orange : .blue
    }

    // MARK: - Integrations / AI card

    private var integrationsCard: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(icon: "link", title: "連携と AI")

                healthKitRow

                Divider().opacity(0.4)

                VStack(alignment: .leading, spacing: 8) {
                    Text("AI 送信範囲")
                        .font(.subheadline.weight(.semibold))
                    Picker("AI 送信範囲", selection: $settings.aiTransmissionScope) {
                        ForEach(AITransmissionScope.allCases) { scope in
                            Text(scope.label).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(settings.aiTransmissionScope.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("AI コーチ・食事推定は現在無効。設定はオプトイン後に適用されます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var healthKitRow: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.pink.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: "heart.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.pink)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("ヘルスデータ連携")
                    .font(.subheadline.weight(.semibold))
                Text(healthKitStatusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: .constant(false))
                .labelsHidden()
                .disabled(true)
                .tint(.pink)
                .accessibilityLabel("ヘルスデータ連携 \(healthKitStatusLabel)")
        }
    }

    private var healthKitStatusLabel: String {
        HealthKitImporterProvider.shared.isAvailable ? "許可済み" : "未対応（プレビュー）"
    }

    // MARK: - App settings (preserved P0 toggles)

    private var appSettingsCard: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(icon: "gearshape.fill", title: "アプリ設定")

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("休憩終了の通知を許可する", isOn: notificationBinding)
                    Text(notificationStatusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Divider().opacity(0.4)

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("休憩終了時にビープ音を鳴らす", isOn: $settings.soundEnabled)
                    Toggle("休憩終了時に触覚で知らせる", isOn: $settings.hapticsEnabled)
                    Toggle("ランナー表示中は画面を常時点灯", isOn: $settings.keepScreenOn)
                }
            }
        }
    }

    private var appInfoCard: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(icon: "info.circle.fill", title: "アプリ情報")
                HStack {
                    Text("名称").foregroundStyle(.secondary)
                    Spacer()
                    Text("PulseCue").font(.subheadline.weight(.semibold))
                }
                HStack {
                    Text("バージョン").foregroundStyle(.secondary)
                    Spacer()
                    Text(appVersion).font(.subheadline.weight(.semibold))
                }
            }
            .font(.subheadline)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    // MARK: - Save CTA

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
                        .fill(accentGradient)
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
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            showSavedToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut(duration: 0.25)) {
                showSavedToast = false
            }
        }
    }

    private var savedToast: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white)
            Text("保存しました")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(accentGradient)
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        )
    }

    // MARK: - Notifications binding (preserved)

    private var notificationBinding: Binding<Bool> {
        Binding(
            get: { settings.notificationsEnabled },
            set: { newValue in
                if newValue {
                    NotificationManager.shared.requestAuthorization { granted in
                        settings.notificationsEnabled = granted
                        if !granted {
                            showNotificationAlert = true
                        }
                        refreshNotificationStatus()
                    }
                } else {
                    settings.notificationsEnabled = false
                    NotificationManager.shared.removeAllPending()
                }
            }
        )
    }

    private var notificationStatusText: String {
        switch notificationAuthStatus {
        case .authorized, .provisional, .ephemeral:
            return "許可されています。休憩終了をローカル通知で知らせます。"
        case .denied:
            return "iOS の設定アプリで通知を許可してください。"
        case .notDetermined:
            return "オンにすると通知の許可をリクエストします。"
        @unknown default:
            return ""
        }
    }

    private func refreshNotificationStatus() {
        NotificationManager.shared.getAuthorizationStatus { status in
            notificationAuthStatus = status
            let authorized = (status == .authorized || status == .provisional)
            if !authorized && settings.notificationsEnabled {
                settings.notificationsEnabled = false
            }
        }
    }

    // MARK: - Reusable cells

    private func glassCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(glassBackground)
            .overlay(glassStroke)
    }

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(accentGradient)
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(accentGradient)
        }
    }

    private func inlineNumberCell(
        label: String,
        value: Int,
        range: ClosedRange<Int>,
        step: Int,
        unit: String,
        binding: Binding<Int>
    ) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text("\(value)")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Stepper("", value: binding, in: range, step: step)
                .labelsHidden()
                .accessibilityLabel("\(label) \(value) \(unit)")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func inlineDoubleCell(
        label: String,
        helper: String,
        value: Double,
        range: ClosedRange<Double>,
        step: Double,
        unit: String,
        binding: Binding<Double>
    ) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(formatWeight(value))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(helper)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Stepper("", value: binding, in: range, step: step)
                .labelsHidden()
                .accessibilityLabel("\(label) \(formatWeight(value)) \(unit)")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func pickerCell<T, Content: View>(
        label: String,
        selection: Binding<T>,
        @ViewBuilder content: @escaping (T) -> Content
    ) -> some View where T: Hashable & CaseIterable & Identifiable, T.AllCases == [T] {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Picker(label, selection: selection) {
                    ForEach(T.allCases) { item in
                        content(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.primary)
            }
            Spacer()
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func derivedRow(label: String, value: String, valueStyle: Color = .primary) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(valueStyle)
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

    // MARK: - Formatting

    private func formatInt(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formatWeight(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }
}
