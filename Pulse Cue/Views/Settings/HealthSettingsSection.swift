//
//  HealthSettingsSection.swift
//  Pulse Cue
//
//  ヘルスケア — the HealthKit link, and what the app is allowed to send.
//
//  Both answer the same question: which of your health data leaves this
//  screen's control, and where to. That is why they share a card and why they
//  are not filed under アプリ設定 with the notification toggles.
//

import SwiftUI

struct HealthSettingsSection: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        SettingsChrome.glassCard {
            VStack(alignment: .leading, spacing: 14) {
                SettingsChrome.sectionHeader(icon: "link", title: "連携と AI")

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
}
