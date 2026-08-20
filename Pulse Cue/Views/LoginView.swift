//
//  LoginView.swift
//  Pulse Cue
//
//  User-facing login / account UI for the auth shell. Built on `AppTheme` +
//  `PulseUI` primitives and driven by `AuthSessionStore`.
//
//  Actions:
//    - "Sign in with Apple" → real Apple flow via `SignInWithAppleButton`.
//      The identityToken, authorizationCode and raw nonce ARE read and sent to
//      PulseCue's backend, which verifies them and issues a server session.
//      `credential.user`, the name and the email are display fields only and
//      are never sent as identity.
//    - "Googleで続ける" → real Google Sign-In via the GoogleSignIn SDK when a
//      real iOS OAuth client *and* a distinct server client are configured.
//      The idToken IS read and sent to the backend; the accessToken,
//      refreshToken, serverAuthCode and userID are not. While either client id
//      is the documented placeholder — or the two are equal — sign-in is
//      refused rather than faked.
//    - "ゲストで続ける"  → AuthSessionStore.continueAsGuest()
//
//  Sign-in now exchanges the provider's signed material for a PulseCue
//  server session, which `ServerAccountStore` owns: it verifies the session,
//  persists the opaque token in the Keychain, and hands it back to the server
//  if any of that fails. The local `LinkedAccount` record is written only
//  after the server confirms, so a failed exchange leaves no link behind.
//
//  Sync is still not active, and login is still never required to use the
//  app — Guest remains a complete way to use PulseCue.
//

import SwiftUI
import UIKit
import AuthenticationServices
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

struct LoginView: View {
    @ObservedObject var authSession: AuthSessionStore
    /// The PulseCue server account, when this build has one.
    ///
    /// Optional so the local-only login shell keeps working unchanged in
    /// previews and in builds with no API configured. When it is absent, or
    /// unconfigured, sign-in still links the provider locally and simply does
    /// not claim a server account was created.
    var serverAccount: ServerAccountStore?
    @Environment(\.dismiss) private var dismiss

    /// The raw nonce for the sign-in attempt currently on screen.
    ///
    /// Apple receives `sha256(rawNonce)` and echoes it inside the signed
    /// identity token; the server receives the raw value and recomputes the
    /// hash. Holding it here for the duration of one attempt is what ties the
    /// token that comes back to the request that went out.
    @State private var appleRawNonce: String?

    /// The Web/server OAuth client. Google mints the ID token's `aud` from
    /// this, and the backend verifies against it. Separate from
    /// `googleConfig`, which is the *iOS* client.
    private let googleServerConfig = GoogleServerSignInConfig.fromMainBundle()

    /// Google sign-in configuration read from Info.plist. While this holds the
    /// documented placeholder, `isConfigured` is false.
    private let googleConfig = GoogleSignInConfig.fromMainBundle()

    /// Compile-time build flavour, surfaced as a value so the presentation
    /// decision below stays unit-testable without `#if` in the test.
    private var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Whether to render the Google control at all. Release users never see an
    /// unavailable / "設定準備中" control — the button appears only when a real
    /// client is configured. Debug keeps the unavailable state visible for
    /// development. Centralised so no other view re-derives this.
    private var showsGoogleSignIn: Bool {
        GoogleSignInPresentation.showsControl(
            isConfigured: googleConfig.isConfigured,
            isDebugBuild: isDebugBuild
        )
    }

    var body: some View {
        ZStack {
            PulseAtmosphericBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    actionsCard
                }
                .padding(.horizontal, 24)
                .padding(.top, 36)
                .padding(.bottom, 32)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            ZStack {
                Circle()
                    .fill(AppTheme.accentFilled)
                    .frame(width: 56, height: 56)
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)

            Text("PulseCueにログイン")
                .font(.title.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(AppTheme.textPrimary)

            Text("続ける方法を選んでください。ログインは任意です。")
                .font(.body)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            PulseSectionHeader("続ける方法", icon: "rectangle.portrait.and.arrow.right")

            // Real Sign in with Apple. Only sanitized name/email is used;
            // no token / code / user identifier is read or stored.
            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = [.fullName, .email]
                // Apple gets the hash; the server gets the raw value. A
                // captured identity token proves nothing without it, and the
                // server spends each nonce once.
                let raw = AppleSignInNonce.makeRawNonce()
                appleRawNonce = raw
                request.nonce = AppleSignInNonce.sha256Hex(raw)
            } onCompletion: { result in
                handleAppleCompletion(result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous))

            Button("ゲストで続ける") {
                authSession.continueAsGuest()
                dismiss()
            }
            .buttonStyle(PulseSecondaryButtonStyle())

            // Shown only where the control is meaningful (see
            // `showsGoogleSignIn`): a configured client, or any DEBUG build.
            // Release with the placeholder config shows nothing here.
            if showsGoogleSignIn {
                Button("Googleで続ける") {
                    startGoogleSignIn()
                }
                .buttonStyle(PulseSecondaryButtonStyle())
                .disabled(!googleConfig.isConfigured)

                if !googleConfig.isConfigured {
                    Label("Googleログインは設定準備中です", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                Text("現在のデータはこの端末内に保存されます。同期とバックアップはまだ有効ではありません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .pulseGlass(level: .functional, padding: 18)
    }

    /// Handles the Apple authorization result. On success it extracts ONLY the
    /// non-sensitive display name / email; the identityToken, authorizationCode,
    /// and Apple `user` identifier are deliberately ignored and never stored.
    /// Cancellation / failure leaves the auth state unchanged.
    private func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        guard case let .success(authorization) = result,
              let credential = authorization.credential as? ASAuthorizationAppleIDCredential
        else { return }

        let appleResult = AppleSignInResult(
            nameComponents: credential.fullName,
            email: credential.email
        )
        let rawNonce = appleRawNonce
        appleRawNonce = nil

        // The *signed* material is what PulseCue's server decides identity
        // from. `credential.user`, the name and the email are deliberately not
        // sent — the server reads the subject out of the signature it
        // verifies, and there is no field on the request for anything the
        // client claims. They are display fields only.
        //
        // `authorizationCode` is required, not best-effort: without it the
        // server cannot obtain the refresh token it needs to revoke at account
        // deletion, and the code cannot be re-requested later.
        let identityToken = credential.identityToken
            .flatMap { String(data: $0, encoding: .utf8) }
        let authorizationCode = credential.authorizationCode
            .flatMap { String(data: $0, encoding: .utf8) }

        guard let serverAccount,
              let rawNonce,
              let identityToken,
              let authorizationCode
        else {
            // No server account layer, or Apple did not give us everything the
            // backend needs. **Nothing is recorded locally.** Writing a
            // `LinkedAccount` here would leave the app showing a provider as
            // attached on the strength of a sign-in that never completed
            // server-side — which is precisely the local/server confusion the
            // account model exists to prevent.
            dismiss()
            return
        }

        // Everything the async work needs is extracted here, as plain values.
        // The `ASAuthorizationAppleIDCredential` itself is a live
        // AuthenticationServices object; capturing it in a Task that then
        // awaits two network round trips keeps the whole credential — and the
        // token data hanging off it — alive far longer than the flow needs.
        // Copying out the four strings lets it go at the end of this function.
        let providerUserID = credential.user
        let displayName = appleResult.displayName
        let email = appleResult.email

        // The local link is written only *after* the server confirms the
        // session. Recording it first meant a failed exchange — a missing
        // authorization code, a 401, an unreachable backend — still left a
        // local link behind with no account behind it.
        //
        // `providerUserID` is for that local record only. It is never sent to
        // the backend as identity: the server reads the subject out of the
        // signature it verified, and `AppleSignInRequest` has no field for it.
        Task { @MainActor [authSession, serverAccount] in
            let authenticated = await serverAccount.signInWithApple(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                rawNonce: rawNonce
            )
            guard authenticated else { return }

            authSession.completeAppleSignIn(
                userIdentifier: providerUserID,
                displayName: displayName,
                email: email
            )
        }

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
            guard error == nil,
                  let user = signInResult?.user,
                  let userID = user.userID
            else { return }
            // Extract ONLY the stable identifier and the non-sensitive display
            // fields up front, so the MainActor handoff below captures plain
            // `String` values and never the SDK result. The idToken,
            // accessToken, refreshToken and serverAuthCode are never touched —
            // the SDK keeps its own credential and `restorePreviousSignIn`
            // brings the session back on the next launch.
            let displayName = user.profile?.name
            let email = user.profile?.email
            // The ID token is the ONLY thing the server accepts as identity.
            // `user.userID`, the profile name and the email are display fields
            // here and are never sent as identity — the server reads `sub` out
            // of the signature it verifies.
            //
            // The token is only useful to the backend when `GIDServerClientID`
            // is configured, because that is what puts the server client id in
            // the token's `aud`. Unconfigured means no server sign-in is
            // attempted at all, rather than one that would be rejected.
            let idToken = user.idToken?.tokenString
            // The runtime gate, not just a config read. Both client ids must
            // be present *and* different: they are both
            // `...apps.googleusercontent.com`, so pasting the iOS one into the
            // server slot is an easy mistake that shape alone cannot catch.
            // Getting it wrong fails closed at the backend, which presents as
            // "sign-in is broken" — so it is refused here instead.
            let serverSignInIsPossible =
                googleServerConfig.isConfigured
                && googleConfig.isConfigured
                && googleServerConfig.isDistinct(from: googleConfig.clientID)
            // Hop to the main actor for the state update + dismiss, which are
            // both main-actor isolated. The SDK callback itself is nonisolated.
            Task { @MainActor in
                let googleResult = GoogleSignInResult(
                    displayName: displayName,
                    email: email
                )

                guard let serverAccount, serverSignInIsPossible, let idToken else {
                    // Server sign-in is unavailable — no account layer, or the
                    // server client id is missing or misconfigured. Nothing is
                    // recorded locally: a `LinkedAccount` written here would
                    // claim a provider is attached when no PulseCue account
                    // exists behind it.
                    dismiss()
                    return
                }

                // The local link follows the server, never leads it.
                let authenticated = await serverAccount.signInWithGoogle(
                    idToken: idToken
                )
                if authenticated {
                    authSession.completeGoogleSignIn(
                        userIdentifier: userID,
                        displayName: googleResult.displayName,
                        email: googleResult.email
                    )
                }
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

}

/// Centralised decision for whether the Google Sign-In control is presented.
///
/// Product rule: Release users must never see an unavailable / "設定準備中"
/// Google control — it appears only when a real client is configured. DEBUG
/// keeps the (explicitly unavailable) state visible for development. Pure and
/// top-level so both branches are unit-testable without `#if` in the test.
enum GoogleSignInPresentation {
    static func showsControl(isConfigured: Bool, isDebugBuild: Bool) -> Bool {
        isDebugBuild || isConfigured
    }
}

#if DEBUG
#Preview("Login") {
    LoginView(authSession: AuthSessionStore())
}
#endif
