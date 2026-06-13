//
//  LoginView.swift
//  Pulse Cue
//
//  User-facing login / account UI for the auth shell. Built on `AppTheme` +
//  `PulseUI` primitives and driven by `AuthSessionStore`.
//
//  Actions:
//    - "Sign in with Apple" → real Apple flow via `SignInWithAppleButton`
//      (PR #114). Only sanitized, non-sensitive display metadata (name/email)
//      reaches `AuthSessionStore.completeAppleSignIn`; the identityToken,
//      authorizationCode, and Apple `user` identifier are never read or stored.
//    - "Googleで続ける" → AuthSessionStore.signInWithMockGoogle() — still a
//      local mock placeholder until PR #115.
//    - "ゲストで続ける"  → AuthSessionStore.continueAsGuest()
//
//  Even with real Apple sign-in, the app stays local-first: no token
//  persistence, no Keychain, no server token exchange, no sync. The copy
//  makes clear that account linking / backup / sync are not active yet, and
//  login is never required to use the app.
//

import SwiftUI
import AuthenticationServices

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
                PulseSectionHeader("続ける方法を選ぶ", icon: "rectangle.portrait.and.arrow.right")

                // Real Sign in with Apple. Only sanitized name/email is used;
                // no token / code / user identifier is read or stored.
                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    handleAppleCompletion(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous))

                // Guest reflects real, local-only usage today.
                Button("ゲストで続ける") {
                    authSession.continueAsGuest()
                    dismiss()
                }
                .buttonStyle(PulseSecondaryButtonStyle())

                // Google remains a local mock placeholder until PR #115.
                Button("Googleで続ける") {
                    Task {
                        await authSession.signInWithMockGoogle()
                        dismiss()
                    }
                }
                .buttonStyle(PulseSecondaryButtonStyle())

                Text("Appleでサインインできます。サインインしても現在のデータはこの端末内に保存され、同期・バックアップ・アカウント連携はまだ有効ではありません。Google連携は準備中のローカル確認用です。")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Handles the Apple authorization result. On success it extracts ONLY the
    /// non-sensitive display name / email; the identityToken, authorizationCode,
    /// and Apple `user` identifier are deliberately ignored and never stored.
    /// Cancellation / failure leaves the auth state unchanged.
    private func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        guard case let .success(authorization) = result else { return }
        let appleResult: AppleSignInResult
        if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
            appleResult = AppleSignInResult(
                nameComponents: credential.fullName,
                email: credential.email
            )
        } else {
            appleResult = AppleSignInResult(displayName: nil, email: nil)
        }
        authSession.completeAppleSignIn(
            displayName: appleResult.displayName,
            email: appleResult.email
        )
        dismiss()
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
