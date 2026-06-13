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
//    - "Googleで続ける" → real Google Sign-In via the GoogleSignIn SDK when a
//      real iOS OAuth client is configured (PR #115). Only sanitized
//      name/email reaches `AuthSessionStore.completeGoogleSignIn`; the idToken,
//      accessToken, refreshToken, serverAuthCode, and user identifier are
//      never read or stored. While the Info.plist client ID is the documented
//      placeholder, the button is disabled and a "設定準備中" note is shown —
//      no real sign-in starts and no fake signed-in state is created.
//    - "ゲストで続ける"  → AuthSessionStore.continueAsGuest()
//
//  Even with real Apple/Google sign-in, the app stays local-first: no token
//  persistence, no Keychain, no server token exchange, no sync. The copy
//  makes clear that account linking / backup / sync are not active yet, and
//  login is never required to use the app.
//

import SwiftUI
import UIKit
import AuthenticationServices
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

struct LoginView: View {
    @ObservedObject var authSession: AuthSessionStore
    @Environment(\.dismiss) private var dismiss

    /// Google sign-in configuration read from Info.plist. While this holds the
    /// documented placeholder, `isConfigured` is false and the Google button
    /// stays disabled.
    private let googleConfig = GoogleSignInConfig.fromMainBundle()

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

                // Real Google Sign-In when a real iOS OAuth client is
                // configured; disabled with a note while the placeholder is in
                // place. Only sanitized name/email is used; no token / code /
                // user identifier is read or stored.
                Button("Googleで続ける") {
                    startGoogleSignIn()
                }
                .buttonStyle(PulseSecondaryButtonStyle())
                .disabled(!googleConfig.isConfigured)

                if !googleConfig.isConfigured {
                    Text("Googleログインは設定準備中です。Google Cloud の設定が完了すると利用できます。")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Apple・Googleでサインインできます。サインインしても現在のデータはこの端末内に保存され、同期・バックアップ・アカウント連携はまだ有効ではありません。")
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

    // MARK: - Google sign-in

    /// Entry point for the Google button. Refuses to start unless a real iOS
    /// OAuth client is configured, so the documented placeholder can never
    /// trigger a real flow or fabricate a signed-in state.
    private func startGoogleSignIn() {
        guard googleConfig.isConfigured else { return }
        presentGoogleSignIn()
    }

#if canImport(GoogleSignIn)
    /// Presents the real Google Sign-In sheet. On success it extracts ONLY the
    /// non-sensitive display name / email; the idToken, accessToken,
    /// refreshToken, serverAuthCode, and Google user identifier are deliberately
    /// ignored and never stored. Cancellation / failure leaves state unchanged.
    private func presentGoogleSignIn() {
        guard let presenter = Self.topViewController() else { return }
        GIDSignIn.sharedInstance.signIn(withPresenting: presenter) { signInResult, error in
            guard error == nil, let profile = signInResult?.user.profile else { return }
            // Extract ONLY the non-sensitive display name / email up front, so
            // the MainActor handoff below captures plain `String?` values and
            // never the SDK result. The idToken, accessToken, refreshToken,
            // serverAuthCode, and Google user identifier are never touched.
            let displayName = profile.name
            let email = profile.email
            // Hop to the main actor for the state update + dismiss, which are
            // both main-actor isolated. The SDK callback itself is nonisolated.
            Task { @MainActor in
                let googleResult = GoogleSignInResult(
                    displayName: displayName,
                    email: email
                )
                authSession.completeGoogleSignIn(
                    displayName: googleResult.displayName,
                    email: googleResult.email
                )
                dismiss()
            }
        }
    }

    /// Finds the top-most view controller to present the Google sheet from.
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        guard var top = scene?.keyWindow?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }
#else
    /// GoogleSignIn SDK unavailable at build time — treat as not configured.
    private func presentGoogleSignIn() {}
#endif

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
