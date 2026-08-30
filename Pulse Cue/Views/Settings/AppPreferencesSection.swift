//
//  AppPreferencesSection.swift
//  Pulse Cue
//
//  アプリ設定 — how the app behaves, plus help and version.
//
//  Nothing here is about you; it is all about the app. That is the line that
//  separates this section from 体と目標 and ヘルスケア, and the reason the
//  training features that once shared this screen now live under
//  トレーニング → その他の機能: registering a gym is a training task, not app
//  configuration.
//
//  The notification permission alert and the onboarding replay sheet are
//  presented from here, because the controls that raise them are here.
//

import SwiftUI
import UserNotifications

struct AppPreferencesSection: View {
    @EnvironmentObject private var settings: SettingsStore

    @State private var notificationAuthStatus: UNAuthorizationStatus = .notDetermined
    @State private var showNotificationAlert = false
    @State private var showOnboardingReplay = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
#if DEBUG
            developerToolsSection
#endif
            appSettingsCard
            helpCard
            appInfoCard
        }
        .onAppear { refreshNotificationStatus() }
        .alert("通知が無効です", isPresented: $showNotificationAlert) {
            Button("了解", role: .cancel) {}
        } message: {
            Text("iOS の設定アプリで通知を許可してください。")
        }
        .sheet(isPresented: $showOnboardingReplay) {
            OnboardingView(primaryTitle: "閉じる") {
                showOnboardingReplay = false
            }
        }
    }

    // MARK: - App behaviour

    private var appSettingsCard: some View {
        SettingsChrome.glassCard {
            VStack(alignment: .leading, spacing: 14) {
                SettingsChrome.sectionHeader(icon: "gearshape.fill", title: "アプリ設定")

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

    // MARK: - Notifications

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

    // MARK: - Help / app information

    private var helpCard: some View {
        SettingsChrome.glassCard {
            VStack(alignment: .leading, spacing: 14) {
                SettingsChrome.sectionHeader(icon: "questionmark.circle.fill", title: "ヘルプ")
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
        SettingsChrome.glassCard {
            VStack(alignment: .leading, spacing: 14) {
                SettingsChrome.sectionHeader(icon: "info.circle.fill", title: "アプリ情報")
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

#if DEBUG
    // MARK: - Developer tools

    /// DEBUG-only developer / QA tools, grouped into one quiet section so they
    /// never read like a normal user feature. Compiled only in DEBUG builds —
    /// the shipping app shows none of this. Navigation destinations are
    /// unchanged.
    private var developerToolsSection: some View {
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
}
