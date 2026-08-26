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

/// Which group of settings a screen shows.
///
/// One screen, four entrances. `MeView` used to offer a single 「設定」 that
/// opened everything at once — body measurements, HealthKit, the account and
/// notification toggles in one scroll — which put "how tall am I" and "should
/// the app buzz" at the same level. The distinction that matters is between
/// *your data* and *the app's configuration*, and it is not visible when they
/// share a list.
///
/// Scoping the existing screen rather than splitting it into four files keeps
/// this an information-architecture change: the cards, their bindings and
/// their behaviour are untouched, and a reader can still see all of them in
/// one place.
enum SettingsSection: Equatable, CaseIterable {
    /// Height, age, sex, activity, BMR/TDEE and the weight goal.
    case bodyAndGoals
    /// HealthKit, and what the app is allowed to send.
    case health
    /// Sign-in, the linked provider, the server account and its deletion.
    case account
    /// Notifications, help, version — the app itself.
    case app

    var title: String {
        switch self {
        case .bodyAndGoals: return "体と目標"
        case .health: return "ヘルスケア"
        case .account: return "アカウント"
        case .app: return "アプリ設定"
        }
    }
}

struct SettingsView: View {
    /// Defaults to the whole screen so previews and the QA harness keep
    /// working unchanged.
    var section: SettingsSection?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var authSession: AuthSessionStore
    @EnvironmentObject var serverAccount: ServerAccountStore

    // 14 days of DayLog so we can pull "current weight" + today's intake
    // for the goal-gap card without a second SwiftData read.
    @Query private var recentLogs: [DayLog]

    // UserProfile is now the source of truth for profile / goal fields.
    @Query(sort: [SortDescriptor(\UserProfile.updatedAt, order: .reverse)])
    private var profiles: [UserProfile]

    @State private var notificationAuthStatus: UNAuthorizationStatus = .notDetermined
    @State private var showNotificationAlert = false
    @State private var showSavedToast = false
    @State private var showOnboardingReplay = false
    @State private var showLoginSheet = false
    @State private var showProfileGymSetup = false

    /// - Parameter section: which group to show. `nil` shows all of them,
    ///   which is what the previews and the QA harness use.
    init(section: SettingsSection? = nil) {
        self.section = section
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -13, to: today) ?? today
        self._recentLogs = Query(
            filter: #Predicate<DayLog> { $0.date >= start },
            sort: [SortDescriptor(\DayLog.date, order: .reverse)]
        )
    }

    /// Whether this group belongs on screen. No section means all of them.
    private func shows(_ group: SettingsSection) -> Bool {
        section == nil || section == group
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
        .navigationTitle(section?.title ?? "設定")
        .navigationBarTitleDisplayMode(.large)
        .alert("通知が無効です", isPresented: $showNotificationAlert) {
            Button("了解", role: .cancel) {}
        } message: {
            Text("iOS の設定アプリで通知を許可してください。")
        }
        .onAppear { refreshNotificationStatus() }
        .sheet(isPresented: $showOnboardingReplay) {
            OnboardingView(primaryTitle: "閉じる") {
                showOnboardingReplay = false
            }
        }
        .sheet(isPresented: $showLoginSheet) {
            LoginView(authSession: authSession, serverAccount: serverAccount)
        }
        .sheet(isPresented: $showProfileGymSetup) {
            ProfileGymSetupView()
        }
    }

    @ViewBuilder
    private func content(profile profileObject: UserProfile) -> some View {
        @Bindable var profile = profileObject
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if shows(.bodyAndGoals) {
                    titleBlock
                    personalDataCard(profile: $profile)
                    HStack(spacing: 12) {
                        bmrCard(profile: profile)
                        tdeeCard(profile: profile)
                    }
                    goalCard(profile: $profile)
                }
                if shows(.health) {
                    integrationsCard
                }
                if shows(.account) {
                    accountCard
                }
                // マイジム / 種目ライブラリ / マシンカタログ / 週間プラン /
                // AI プラン相談 live under トレーニング → その他の機能. They
                // are training tasks, not app configuration.
                if shows(.app) {
#if DEBUG
                    aiEndpointQASection
#endif
                    appSettingsCard
                    helpCard
                    appInfoCard
                }
                if shows(.bodyAndGoals) {
                    saveButton
                }
                Color.clear.frame(height: 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        PulseAtmosphericBackground()
    }

    private var accentGradient: LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [AppTheme.iceLight, AppTheme.edgeBlue]
                : [AppTheme.accentFilled, AppTheme.accent],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var tealGradient: LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [AppTheme.iceLight, AppTheme.reflectedBlue]
                : [AppTheme.deepGlass, AppTheme.reflectedBlue],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Header / title

    private var brandHeader: some View {
        HStack {
            ZStack {
                Circle().fill(AppTheme.accentFilled).frame(width: 32, height: 32)
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
        HStack(spacing: 9) {
            Image(systemName: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
            Text("パーソナルデータと目標の管理")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Personal data card

    private func personalDataCard(profile: Bindable<UserProfile>) -> some View {
        featuredGlassCard {
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

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("標準の休憩時間")
                                .font(.subheadline.weight(.semibold))
                            Text("ルーティンで指定しない場合の初期値")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Text("\(settings.defaultRestSeconds) 秒")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                    }
                    Stepper(
                        "標準の休憩時間を調整",
                        value: $settings.defaultRestSeconds,
                        in: 0...600,
                        step: 15
                    )
                    .labelsHidden()
                    .accessibilityValue("\(settings.defaultRestSeconds) 秒")
                }

                Divider().opacity(0.4)

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

#if DEBUG
    /// DEBUG-only developer / QA tools, grouped into one quiet section so they
    /// never read like a normal user feature. Compiled only in DEBUG builds —
    /// the shipping app shows none of this. Navigation destinations are
    /// unchanged.
    private var aiEndpointQASection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                PulseSectionHeader("開発者ツール", icon: "ladybug")
                PulseStatusBadge("DEBUG", kind: .warning)
            }
            Text("AIプラン相談の通信経路を確認するための開発・QA専用ツールです。通常のAIプラン相談とは別物で、リリース版には含まれません。")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            qaRow(
                title: "AI endpoint QA",
                subtitle: "ローカルのモックエンドポイントで通信経路を確認（トークンなし）。",
                badges: [("LOCAL", .info), ("MOCK", .info)]
            ) {
                MockAITrainingPlanChatView(endpointConfiguration: .debugLocalMock)
            }

            Divider().overlay(AppTheme.separator)

            qaRow(
                title: "AI endpoint QA（fake token）",
                subtitle: "フェイクの有効トークンでサーバーの mock-auth 成功経路を確認。",
                badges: [("LOCAL", .info), ("FAKE TOKEN", .warning)]
            ) {
                MockAITrainingPlanChatView(endpointConfiguration: .debugLocalMockWithFakeToken())
            }

            Divider().overlay(AppTheme.separator)

            qaRow(
                title: "API ヘルス確認",
                subtitle: "入力したベースURLの /api/health を手動確認（読み取り専用・トークンなし・保存なし）。",
                badges: [("DEBUG", .warning), ("READ-ONLY", .info)]
            ) {
                APIHealthQAView()
            }
        }
        .pulseCard()
    }

    /// Compact, low-emphasis navigation row for a DEBUG QA destination —
    /// deliberately quieter than the normal feature cards.
    private func qaRow<Destination: View>(
        title: String,
        subtitle: String,
        badges: [(String, PulseStatusBadge.Kind)],
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                            PulseStatusBadge(badge.0, kind: badge.1)
                        }
                    }
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
#endif

    // MARK: - Account (read-only status shell)

    /// Account / login entry. Shows the current usage state and opens the
    /// Login UI in a sheet.
    ///
    /// Two separate things are on display here and they are not the same
    /// question: the **local provider link** (an Apple or Google identity
    /// attached to this device's profile) and the **PulseCue server account**
    /// owned by `ServerAccountStore`. A link is not an account.
    ///
    /// A server session token *is* persisted now, in the Keychain — the older
    /// "no token persistence" note here described the local-only era and was
    /// simply untrue. What has not changed: nothing gates app usage. Signing
    /// in is optional, and every local feature works without it.
    private var accountCard: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(icon: "person.crop.circle", title: "アカウント")

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("現在の利用状態")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(authSession.statusLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    PulseStatusBadge("この端末のみ", kind: .info)
                }

                Divider().opacity(0.4)

                // The PulseCue server account. Separate from the local link
                // above on purpose: a local link means a provider was once
                // attached to this device, never that a server account exists.
                ServerAccountSettingsSection(store: serverAccount, authSession: authSession)

                Button {
                    showLoginSheet = true
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ログイン・アカウント設定")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("ゲストのまま使えます。Apple・Googleでサインインすることもできます。トレーニング記録は現在この端末に保存されます。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider().opacity(0.4)

                Button {
                    showProfileGymSetup = true
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("プロフィールとジムの設定")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("身長・今日の体重・マイジムの設定状況をまとめて確認できます。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if authSession.isSignedIn {
                    Divider().opacity(0.4)
                    Button(role: .destructive) {
                        authSession.unlinkAccount()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "link.badge.plus")
                            Text("連携を解除")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }

                Divider().opacity(0.4)

                // Says exactly what the app does, which is now two different
                // things. When a server session is held a PulseCue account
                // really does exist, so the old blanket
                // 「アカウントは作成されません」 would be a false statement to
                // show that user. Neither wording promises sync: nothing syncs
                // yet in either case, and saying otherwise is the kind of
                // promise someone only discovers is false after losing a phone.
                Text(localLinkFootnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The footnote under the local link card.
    ///
    /// Keyed to the *server* state, and deliberately not a two-way split. The
    /// distinction that has to survive here is between "there is no account"
    /// and "we cannot tell right now" — collapsing those is how a UI ends up
    /// telling someone their account does not exist because their train went
    /// into a tunnel.
    ///
    /// The local link is a separate fact and is stated separately: it lives on
    /// this device either way, and it never implies a server account.
    private var localLinkFootnote: String {
        let base = "Apple・Googleとの連携はこの端末内のプロフィールに保存されます。"
        let localData = "連携を解除しても、トレーニング記録などの端末内データは削除されません。"

        switch serverAccount.state {
        case .authenticated:
            // An account demonstrably exists, so promising the opposite would
            // be false. Sync still does not, and is not implied.
            return base
                + "PulseCueアカウントは作成済みです（アカウントの削除は「アカウント」セクションから行えます）。"
                + "トレーニング記録などの端末内データは、まだ同期・バックアップされません。"
                + localData

        case .guest:
            // Guest is a fact about *this device* — not signed in — and not a
            // fact about the server. A PulseCue account may well exist and be
            // reachable from another device, so "アカウントは作成されず" would
            // be asserting something this app has no way to know.
            return base
                + "現在この端末ではPulseCueアカウントにサインインしていません。"
                + "データが別端末と同期・バックアップされることはありません。"
                + localData

        case .notConfigured:
            // The only branch that can truthfully say no account is created:
            // this build has no account API to create one with.
            return base
                + "このビルドではPulseCueアカウントは作成されず、データが別端末と同期・バックアップされることはありません。"
                + localData

        case .restoring, .signingIn, .unreachable:
            // Not "no account" — unknown. The device may well hold a session
            // that simply could not be confirmed.
            return base
                + "PulseCueアカウントの状態は現在確認できません。"
                + "いずれの場合も、データが別端末と同期・バックアップされることはありません。"
                + localData

        case .localCleanupFailed:
            // Sign-out did not finish locally: a credential may still be on
            // the device, so neither "signed out" nor "no account" is true.
            return base
                + "サインアウトが完了しておらず、この端末にサインイン情報が残っている可能性があります。"
                + "データが別端末と同期・バックアップされることはありません。"
                + localData
        }
    }

    // MARK: - Help / onboarding replay

    private var helpCard: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(icon: "questionmark.circle.fill", title: "ヘルプ")
                Button {
                    showOnboardingReplay = true
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("アプリの使い方をもう一度見る")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("PulseCue でできることと、データの保存についての案内を表示します。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
                .fill(AppTheme.accentFilled)
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

    private func featuredGlassCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(
                PulseGlassPlate(level: .functional, cornerRadius: 24)
            )
    }

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(AppTheme.accent)
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppTheme.accent)
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
                .fill(Color.white.opacity(0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.54), .white.opacity(0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.6
                        )
                )
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
                .fill(Color.white.opacity(0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.30), lineWidth: 0.6)
                )
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
                .fill(Color.white.opacity(0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.30), lineWidth: 0.6)
                )
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
        PulseGlassPlate(level: .subtle, cornerRadius: 22)
    }

    private var glassStroke: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.clear, lineWidth: 0)
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
