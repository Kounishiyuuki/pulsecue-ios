//
//  LoginView.swift
//  Pulse Cue
//
//  User-facing login / account UI *shell* (PR #113). Built only on
//  `AppTheme` + `PulseUI` primitives, and driven entirely by the local auth
//  shell from PR #112 (`AuthSessionStore`).
//
//  IMPORTANT — this is a UI shell with mock/local actions only:
//    - "Appleで続ける"  → AuthSessionStore.signInWithMockApple()  (no SDK)
//    - "Googleで続ける" → AuthSessionStore.signInWithMockGoogle() (no SDK)
//    - "ゲストで続ける"  → AuthSessionStore.continueAsGuest()
//  No real Sign in with Apple, no Google Sign-In, no AuthenticationServices,
//  no network, no tokens, no URL schemes, no OAuth client IDs, no Keychain.
//  Apple / Google are local placeholders for QA only; the copy says so. The
//  guest path is the only one that reflects real (local-only) usage today,
//  so it is presented as the primary action.
//

import SwiftUI

struct LoginView: View {
    @ObservedObject var authSession: AuthSessionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AppTheme.surface.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                    header
                    actionsCard
                    localFirstCard
                }
                .padding(.horizontal, AppTheme.Spacing.l)
                .padding(.top, AppTheme.Spacing.xl)
                .padding(.bottom, AppTheme.Spacing.xl)
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
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)

            Text("PulseCueにログイン")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)

            Text("ログインすると、今後の同期・バックアップ機能に対応できます。")
                .font(.body)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private var actionsCard: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                HStack(spacing: AppTheme.Spacing.s) {
                    PulseSectionHeader("続ける方法を選ぶ", icon: "rectangle.portrait.and.arrow.right")
                    PulseStatusBadge("準備中", kind: .info)
                }

                // Guest is the only path that reflects real, local-only usage
                // today, so it is the primary action.
                Button("ゲストで続ける") {
                    authSession.continueAsGuest()
                    dismiss()
                }
                .buttonStyle(PulsePrimaryButtonStyle())

                // Apple / Google are local mock placeholders (no SDK / no auth).
                Button("Appleで続ける") {
                    Task {
                        await authSession.signInWithMockApple()
                        dismiss()
                    }
                }
                .buttonStyle(PulseSecondaryButtonStyle())

                Button("Googleで続ける") {
                    Task {
                        await authSession.signInWithMockGoogle()
                        dismiss()
                    }
                }
                .buttonStyle(PulseSecondaryButtonStyle())

                Text("Apple / Google連携は現在準備中のローカル確認用です。実際のサインインや同期はまだ行われません。")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Local-first note

    private var localFirstCard: some View {
        PulseCard {
            HStack(alignment: .top, spacing: AppTheme.Spacing.m) {
                Image(systemName: "iphone")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("現在のデータはこの端末内に保存されます。")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text("ログインしなくても、すべての機能をこの端末でそのまま利用できます。")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

#if DEBUG
#Preview("Login") {
    LoginView(authSession: AuthSessionStore())
}
#endif
