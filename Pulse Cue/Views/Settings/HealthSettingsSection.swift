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

    /// A status row, not a setting.
    ///
    /// This used to end in `Toggle("", isOn: .constant(false)).disabled(true)`
    /// — a switch wired to a literal, that no user action could ever move.
    /// VoiceOver read it as a dimmed switch, which says "you could turn this
    /// on, but not now"; the truth is that this build has no HealthKit
    /// integration to turn on at all. `HealthKitImporterProvider.shared` is
    /// the no-op importer and nothing reassigns it.
    ///
    /// So the row reports state instead of offering a control. The badge is
    /// the same status vocabulary the account row beside it uses, and it is
    /// `Text` in a capsule — presentation, not a switch drawn by hand.
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
            Text("ヘルスデータ連携")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            PulseStatusBadge(healthKitStatusLabel, kind: healthKitStatusKind)
        }
        // One element: the label and its status are one fact, and read apart
        // they are a heading and a loose word.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("ヘルスデータ連携 \(healthKitStatusLabel)")
        // Wraps rather than clips at accessibility sizes.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var healthKitStatusKind: PulseStatusBadge.Kind {
        HealthKitImporterProvider.shared.isAvailable ? .success : .info
    }

    private var healthKitStatusLabel: String {
        HealthKitImporterProvider.shared.isAvailable ? "許可済み" : "未対応（プレビュー）"
    }
}
