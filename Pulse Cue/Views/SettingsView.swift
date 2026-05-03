//
//  SettingsView.swift
//  Pulse Cue
//
//  Created by Codex.
//

import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore

    @State private var showNotificationAlert = false
    @State private var notificationAuthStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            Section {
                Toggle("休憩終了の通知を許可する", isOn: notificationBinding)
                Text(notificationStatusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("通知")
            } footer: {
                Text("休憩のカウントダウンが終わったタイミングでローカル通知を発火します。アプリが背景にある間も鳴ります。")
            }

            Section {
                Toggle("休憩終了時にビープ音を鳴らす", isOn: $settings.soundEnabled)
                Toggle("休憩終了時に触覚で知らせる", isOn: $settings.hapticsEnabled)
            } header: {
                Text("フィードバック")
            } footer: {
                Text("通知の許可がない／ミュート時のフォールバックとして使われます。")
            }

            Section {
                Toggle("ランナー表示中は画面を常時点灯", isOn: $settings.keepScreenOn)
            } header: {
                Text("表示")
            }

            Section("アプリ情報") {
                LabeledContent("名称", value: "PulseCue")
                LabeledContent("バージョン", value: appVersion)
            }
        }
        .navigationTitle("設定")
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .onAppear {
            refreshNotificationStatus()
        }
        .alert("通知が無効です", isPresented: $showNotificationAlert) {
            Button("了解", role: .cancel) {}
        } message: {
            Text("設定アプリで通知を有効にしてください。")
        }
    }

    private var notificationStatusText: String {
        switch notificationAuthStatus {
        case .authorized, .provisional, .ephemeral:
            return "許可されています。休憩終了を通知します。"
        case .denied:
            return "iOS の設定アプリで通知を許可してください。"
        case .notDetermined:
            return "オンにすると通知の許可をリクエストします。"
        @unknown default:
            return ""
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
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
                    }
                } else {
                    settings.notificationsEnabled = false
                    NotificationManager.shared.removeAllPending()
                }
            }
        )
    }
}
