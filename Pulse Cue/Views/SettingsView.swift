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
            Section("通知") {
                Toggle("通知を有効にする", isOn: notificationBinding)
                Text(notificationStatusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("フィードバック") {
                Toggle("ビープ音", isOn: $settings.soundEnabled)
                Toggle("触覚", isOn: $settings.hapticsEnabled)
            }

            Section("表示") {
                Toggle("画面を常時点灯", isOn: $settings.keepScreenOn)
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
