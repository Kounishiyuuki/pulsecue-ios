//
//  OnboardingView.swift
//  Pulse Cue
//
//  First-launch welcome / guest-entry screen. A single, calm "Apple Health
//  Light" screen built only on `AppTheme` + `PulseUI` primitives — no model,
//  persistence, networking, or auth dependencies.
//
//  This screen explains what PulseCue does and lets the user start
//  immediately as a guest. There is no login here: account linking and sync
//  are introduced in later phases. The only thing the flow persists (via the
//  caller's `onPrimary` closure → `SettingsStore.completeOnboarding()`) is a
//  single completion flag.
//
//  Reused in two contexts:
//    1. First launch — gated by `ContentView` as a `fullScreenCover`; the
//       primary button is "ゲストで始める" and marks onboarding complete.
//    2. Settings replay — presented as a `.sheet`; the primary button is
//       "閉じる" and simply dismisses.
//

import SwiftUI

struct OnboardingView: View {

    /// A single highlighted capability row.
    private struct Highlight: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
    }

    /// Label for the primary action button. Defaults to the first-launch
    /// guest-entry wording; the Settings replay passes "閉じる".
    var primaryTitle: String = "ゲストで始める"

    /// Invoked when the primary button is tapped. First launch passes
    /// `settings.completeOnboarding`; Settings replay passes a dismiss.
    var onPrimary: () -> Void

    private let highlights: [Highlight] = [
        Highlight(icon: "sun.max", title: "今日の状態を確認"),
        Highlight(icon: "fork.knife", title: "食事とカロリーを記録"),
        Highlight(icon: "list.bullet.rectangle", title: "ルーティンを作成・実行"),
        Highlight(icon: "clock.arrow.circlepath", title: "履歴で振り返り"),
        Highlight(icon: "sparkles", title: "AI風プラン候補を保存して使う")
    ]

    var body: some View {
        ZStack {
            AppTheme.surface.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                    header
                    highlightsCard
                    localFirstCard
                }
                .padding(.horizontal, AppTheme.Spacing.l)
                .padding(.top, AppTheme.Spacing.xl)
                .padding(.bottom, AppTheme.Spacing.xl)
            }

            VStack {
                Spacer()
                primaryButtonBar
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            ZStack {
                Circle()
                    .fill(AppTheme.accent)
                    .frame(width: 56, height: 56)
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)

            Text("PulseCueへようこそ")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)

            Text("トレーニング、食事、ルーティンをまとめて管理できます。")
                .font(.body)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Highlights

    private var highlightsCard: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                PulseSectionHeader("できること", icon: "checkmark.seal")

                VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                    ForEach(highlights) { highlight in
                        highlightRow(highlight)
                    }
                }
            }
        }
    }

    private func highlightRow(_ highlight: Highlight) -> some View {
        HStack(spacing: AppTheme.Spacing.m) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
                    .fill(AppTheme.accentSoft)
                    .frame(width: 36, height: 36)
                Image(systemName: highlight.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
            }
            Text(highlight.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Local-first / future-sync note

    private var localFirstCard: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                noteRow(
                    icon: "iphone",
                    title: "データはこの端末内に保存されます",
                    detail: "現在のデータはこの端末内に保存され、ログインなしでそのまま使えます。"
                )
                Divider().overlay(AppTheme.separator)
                noteRow(
                    icon: "icloud",
                    title: "アカウント連携・同期は今後対応予定",
                    detail: "アカウント連携やバックアップ・同期は、今後のアップデートで追加予定です。"
                )
            }
        }
    }

    private func noteRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.m) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Primary action

    private var primaryButtonBar: some View {
        VStack(spacing: AppTheme.Spacing.s) {
            Button(primaryTitle) {
                onPrimary()
            }
            .buttonStyle(PulsePrimaryButtonStyle())

            Text("ログインなしでそのまま使い始められます。")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, AppTheme.Spacing.l)
        .padding(.top, AppTheme.Spacing.m)
        .padding(.bottom, AppTheme.Spacing.l)
        .background(
            AppTheme.surface
                .opacity(0.0)
                .background(.regularMaterial)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

#if DEBUG
#Preview("First launch") {
    OnboardingView {}
}

#Preview("Settings replay") {
    OnboardingView(primaryTitle: "閉じる") {}
}
#endif
