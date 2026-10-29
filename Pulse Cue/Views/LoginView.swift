//
//  LoginView.swift
//  Pulse Cue
//
//  User-facing login / account UI for the auth shell. Built on `AppTheme` +
//  `PulseUI` primitives and driven by `AuthSessionStore`.
//
//  Actions:
//    - "Appleでサインイン" → `ProviderSignInCoordinator`, which takes a
//      Keychain-backed permit *before* Apple's authorization sheet opens. The
//      identityToken, authorizationCode and raw nonce ARE read and sent to
//      PulseCue's backend, which verifies them and issues a server session.
//      `credential.user`, the name and the email are display fields only and
//      are never sent as identity.
//    - "Googleで続ける" → the same coordinator, so `GIDSignIn` is not touched
//      until the permit is granted. Requires a real iOS OAuth client *and* a
//      distinct server client.
//      The idToken IS read and sent to the backend; the accessToken,
//      refreshToken, serverAuthCode and userID are not. While either client id
//      is the documented placeholder — or the two are equal — sign-in is
//      refused rather than faked.
//    - "ゲストで続ける"  → AuthSessionStore.continueAsGuest()
//
//  Neither provider SDK is reachable from this view directly: both go through
//  the coordinator, so a button cannot start an authorization the account
//  layer has not agreed to.
//
//  Sign-in exchanges the provider's signed material for a PulseCue server
//  session, which `ServerAccountStore` owns: it verifies the session,
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
    /// Whether to draw an explicit 閉じる control.
    ///
    /// Opt-in because this view is also embedded where there is nothing to
    /// close (Visual QA, previews). Callers that present it as a sheet pass
    /// `true`; swipe-to-dismiss and the post-sign-in dismiss are unaffected.
    var showsCloseButton = false
    @Environment(\.dismiss) private var dismiss

    /// Disables both provider buttons while an attempt is on screen.
    ///
    /// A courtesy, not the enforcement — the coordinator's permit is what
    /// actually prevents a second authorization, and it holds even if this
    /// flag is wrong. The nonce now lives in `AppleAuthorizationBridge`, for
    /// the lifetime of one authorization.
    @State private var isSigningIn = false

    /// Why the last attempt was refused before it reached a provider, if it was.
    @State private var refusalMessage: String?

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
            // The close control shares the icon's row, never the title's, so
            // a title that wraps at accessibility sizes cannot run under it.
            HStack(alignment: .top) {
                ZStack {
                    Circle()
                        .fill(AppTheme.accentFilled)
                        .frame(width: 56, height: 56)
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)

                Spacer(minLength: AppTheme.Spacing.m)

                if showsCloseButton {
                    closeButton
                }
            }

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

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(AppTheme.separator, lineWidth: 0.7))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("閉じる")
        .accessibilityIdentifier("login.close")
    }

    // MARK: - Actions

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            PulseSectionHeader("続ける方法", icon: "rectangle.portrait.and.arrow.right")

            // Apple's own control, wrapped — see `AppleSignInButton`.
            //
            // Deliberately not `SignInWithAppleButton`, which begins the
            // authorization the instant it is tapped and leaves no room for
            // the Keychain preflight. This one only reports the tap, so the
            // permit still comes first and the SDK second.
            AppleSignInButton {
                await startSignIn(.apple)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .disabled(isSigningIn)
            .opacity(isSigningIn ? 0.5 : 1)

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
                    Task { await startSignIn(.google) }
                }
                .buttonStyle(PulseSecondaryButtonStyle())
                .disabled(!googleConfig.isConfigured || isSigningIn)

                if !googleConfig.isConfigured {
                    Label("Googleログインは設定準備中です", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let refusalMessage {
                Label(refusalMessage, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// The only route to a provider SDK — see `ProviderSignInFlow`.
    @MainActor
    private func startSignIn(_ provider: AuthProviderKind) async {
        guard !isSigningIn else { return }

        isSigningIn = true
        defer { isSigningIn = false }

        switch await ProviderSignInFlow.live(authSession: authSession, serverAccount: serverAccount)
            .start(provider) {
        case .signedIn:
            dismiss()
        case let .stayed(message):
            // nil is a cancel: nothing changed, and nothing to say.
            refusalMessage = message
        }
    }
}

/// What a sign-in screen should do after one provider attempt.
enum ProviderSignInResult: Equatable {
    /// The server confirmed the session and the local link was recorded.
    case signedIn
    /// Nothing was signed in. `message` is nil when the user simply cancelled.
    case stayed(message: String?)
}

/// One provider sign-in, shared by `LoginView` and the first-launch
/// `OnboardingView` so neither re-derives the gate.
///
/// Everything that decides whether a sign-in may start lives behind
/// `ProviderSignInCoordinator`, which takes a Keychain-backed permit before
/// Apple's or Google's sheet is opened. A disabled button is a courtesy; this
/// is the part that is enforced.
@MainActor
struct ProviderSignInFlow {
    let authSession: AuthSessionStore
    /// Absent in builds with no account layer; sign-in is then refused.
    let serverAccount: ServerAccountStore?
    let apple: any AppleAuthorizing
    let google: any GoogleAuthorizing
    let googleConfigurationIsUsable: () -> Bool

    /// The real bridges and Info.plist configuration. Built per attempt, so
    /// each authorization gets its own bridge (and Apple nonce).
    static func live(authSession: AuthSessionStore, serverAccount: ServerAccountStore?) -> ProviderSignInFlow {
        let googleServerConfig = GoogleServerSignInConfig.fromMainBundle()
        let googleConfig = GoogleSignInConfig.fromMainBundle()
        return ProviderSignInFlow(
            authSession: authSession,
            serverAccount: serverAccount,
            apple: AppleAuthorizationBridge(),
            google: GoogleAuthorizationBridge(),
            googleConfigurationIsUsable: {
                // Both client ids present, and different. They are both
                // `...apps.googleusercontent.com`, so pasting the iOS one into
                // the server slot is an easy mistake shape alone cannot catch.
                googleServerConfig.isConfigured
                    && googleConfig.isConfigured
                    && googleServerConfig.isDistinct(from: googleConfig.clientID)
            }
        )
    }

    func start(_ provider: AuthProviderKind) async -> ProviderSignInResult {
        guard let serverAccount else {
            // No account layer in this build. Sign-in would have nothing to
            // talk to, and creating a local-only link would claim a PulseCue
            // account that does not exist.
            return .stayed(message: Self.message(for: .notConfigured))
        }
        let authSession = authSession
        let coordinator = ProviderSignInCoordinator(
            account: serverAccount,
            apple: apple,
            google: google,
            googleConfigurationIsUsable: googleConfigurationIsUsable,
            recordLink: { link in
                // Reached only after the server confirmed and persisted the
                // session, so a local link never outlives a failed sign-in.
                switch link.provider {
                case .apple:
                    authSession.completeAppleSignIn(
                        userIdentifier: link.userIdentifier,
                        displayName: link.displayName,
                        email: link.email
                    )
                case .google:
                    authSession.completeGoogleSignIn(
                        userIdentifier: link.userIdentifier,
                        displayName: link.displayName,
                        email: link.email
                    )
                case .guest:
                    break
                }
            }
        )

        let outcome = provider == .apple
            ? await coordinator.signInWithApple()
            : await coordinator.signInWithGoogle()
        return Self.result(for: outcome)
    }

    static func result(for outcome: ProviderSignInOutcome) -> ProviderSignInResult {
        switch outcome {
        case .signedIn:
            return .signedIn
        case .cancelled:
            return .stayed(message: nil)
        case .providerFailed:
            return .stayed(message: "サインインを完了できませんでした。もう一度お試しください。")
        case let .refused(reason):
            return .stayed(message: message(for: reason))
        }
    }

    private static func message(for refusal: ProviderSignInRefusal) -> String {
        switch refusal {
        case .existingSession:
            return "すでにサインインしています。別のアカウントを使うには、先にサインアウトしてください。"
        case .credentialUnavailable:
            return "この端末のサインイン情報を読み取れませんでした。しばらくしてからお試しください。"
        case .busy:
            return "サインインを処理中です。しばらくお待ちください。"
        case .notConfigured:
            return "この端末ではアカウント機能をまだ利用できません。"
        case .serverRefused:
            return "サインインできませんでした。もう一度お試しください。"
        case .superseded:
            // Sign-out, deletion or a launch restore overtook this attempt.
            // The user asked for that newer thing and got it, so this is not
            // an error to apologise for — it explains why the tap did nothing.
            return "サインアウトなどの操作が行われたため、このサインインは取り消されました。"
        }
    }
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
