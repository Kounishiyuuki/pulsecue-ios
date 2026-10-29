import SwiftUI
import SwiftData

/// Calm first entry: understand local-first use, then start as a guest or,
/// optionally, with an Apple / Google account.
struct OnboardingView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var primaryTitle: String = "ゲストで始める"
    /// When set, Apple / Google sign-in is offered next to the guest start.
    /// The Settings replay leaves it nil and stays guest-only.
    var accountSignIn: AccountSignIn? = nil
    var onPrimary: () -> Void

    /// The account stores and what to do once the server confirms a session.
    struct AccountSignIn {
        let authSession: AuthSessionStore
        let serverAccount: ServerAccountStore?
        let onSignedIn: () -> Void
    }

    @State private var isSigningIn = false
    @State private var refusalMessage: String?

    private var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private let googleConfig = GoogleSignInConfig.fromMainBundle()

    var body: some View {
        ZStack {
            PulseAtmosphericBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    hero
                    localFirstMessage
                    if dynamicTypeSize.isAccessibilitySize {
                        primaryAction
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 54)
                .padding(.bottom, 32)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !dynamicTypeSize.isAccessibilitySize {
                primaryAction
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Circle().fill(AppTheme.accentFilled))
                .accessibilityHidden(true)

            Text("今日の自分に、\nちょうどいい一歩を。")
                .font(.largeTitle.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text("PulseCueは、トレーニングと日々の記録を静かに続けるためのアプリです。")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var localFirstMessage: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "iphone")
                .font(.headline)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("ログインは任意です")
                    .font(.headline)
                Text(accountSignIn == nil
                     ? "現在のデータはこの端末内に保存されます。アカウント連携と同期は今後対応予定です。"
                     : "ゲストでもすべての機能を使えます。現在のデータはこの端末内に保存され、同期とバックアップはまだ有効ではありません。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .pulseGlass(level: .subtle, padding: 18)
        .accessibilityElement(children: .combine)
    }

    private var primaryAction: some View {
        VStack(spacing: 8) {
            if let accountSignIn {
                accountActions(accountSignIn)
            } else {
                Button(primaryTitle, action: onPrimary)
                    .buttonStyle(PulsePrimaryButtonStyle())
            }
            Text("あとから設定を変更できます")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Three equal choices. Guest shares the providers' style on purpose: it
    /// is a complete way to use PulseCue, not a fallback.
    @ViewBuilder
    private func accountActions(_ accountSignIn: AccountSignIn) -> some View {
        AppleSignInButton {
            await startSignIn(.apple, accountSignIn)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .disabled(isSigningIn)
        .opacity(isSigningIn ? 0.5 : 1)
        .accessibilityIdentifier("onboarding.apple")

        // Same rule as LoginView: Release shows Google only when configured.
        if GoogleSignInPresentation.showsControl(isConfigured: googleConfig.isConfigured, isDebugBuild: isDebugBuild) {
            Button("Googleで続ける") {
                Task { await startSignIn(.google, accountSignIn) }
            }
            .buttonStyle(PulseSecondaryButtonStyle())
            .disabled(!googleConfig.isConfigured || isSigningIn)
            .accessibilityIdentifier("onboarding.google")
        }

        Button(primaryTitle, action: onPrimary)
            .buttonStyle(PulseSecondaryButtonStyle())
            .disabled(isSigningIn)
            .accessibilityIdentifier("onboarding.guest")

        if let refusalMessage {
            Label(refusalMessage, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @MainActor
    private func startSignIn(_ provider: AuthProviderKind, _ accountSignIn: AccountSignIn) async {
        guard !isSigningIn else { return }
        isSigningIn = true
        defer { isSigningIn = false }

        refusalMessage = await FirstLaunchSignIn.run(
            ProviderSignInFlow.live(authSession: accountSignIn.authSession, serverAccount: accountSignIn.serverAccount),
            provider,
            onSignedIn: accountSignIn.onSignedIn
        )
    }
}

/// The whole first-launch cover: the three choices, then — after a
/// server-confirmed Apple / Google sign-in — the account's existing
/// `ProfileOnboardingView`, in place. Home is reached only by `onFinish`, so a
/// new account never sees Home before its profile is complete, and the swap
/// happens inside one cover rather than dismissing to Home and presenting
/// again.
///
/// Which account to onboard is still decided by `ProfileOnboardingGate`; the
/// app-level presenter stays blocked until `onFinish` and then finds nothing
/// left to ask.
struct FirstLaunchView: View {
    let onFinish: () -> Void

    @EnvironmentObject private var authSession: AuthSessionStore
    @EnvironmentObject private var serverAccount: ServerAccountStore
    @EnvironmentObject private var dataScope: WorkoutDataScopeResolver
    @Environment(\.modelContext) private var modelContext

    @Query private var everyProfile: [UserProfile]
    @AppStorage(GuestAdoptionConsent.workoutAnsweredKey) private var workoutAnsweredRaw = ""
    @AppStorage(GuestAdoptionConsent.healthAnsweredKey) private var healthAnsweredRaw = ""

    @State private var step: FirstLaunchSignIn.Step = .choose

    var body: some View {
        Group {
            switch step {
            case .choose, .finished:
                OnboardingView(
                    accountSignIn: .init(
                        authSession: authSession,
                        serverAccount: serverAccount,
                        // The state change this causes re-evaluates `step`.
                        onSignedIn: evaluate
                    ),
                    onPrimary: onFinish
                )
            case let .profile(id):
                ProfileOnboardingView(accountID: id)
                    .id(id)
            }
        }
        .onAppear(perform: evaluate)
        .onChange(of: serverAccount.state) { _, _ in evaluate() }
        .onChange(of: dataScope.scope) { _, _ in evaluate() }
        .onChange(of: workoutAnsweredRaw) { _, _ in evaluate() }
        .onChange(of: healthAnsweredRaw) { _, _ in evaluate() }
        .onChange(of: completionSignature) { _, _ in evaluate() }
    }

    private var completionSignature: String {
        everyProfile
            .map { "\($0.id)|\($0.ownerAccountID?.uuidString ?? "-")|\($0.profileOnboardingCompletedAt?.timeIntervalSince1970 ?? 0)" }
            .sorted()
            .joined(separator: ",")
    }

    private func evaluate() {
        step = FirstLaunchSignIn.step(
            state: serverAccount.state,
            scope: dataScope.scope,
            answers: .init(workoutRaw: workoutAnsweredRaw, healthRaw: healthAnsweredRaw),
            in: modelContext
        )
        if step == .finished {
            onFinish()
        }
    }
}

/// First-launch sign-in: onboarding completes only on a server-confirmed
/// session. Cancel and every failure keep the user on the first screen.
enum FirstLaunchSignIn {
    enum Step: Equatable {
        /// No server-confirmed account: show the three choices.
        case choose
        /// A confirmed account whose profile onboarding is not complete.
        case profile(UUID)
        /// A confirmed account with nothing left to ask here: go Home.
        case finished
    }

    /// Where the first-launch cover is, from the same inputs the profile gate
    /// reads. A confirmed account that the gate does not want to onboard has
    /// either completed its profile or is waiting on the guest-adoption
    /// question, which the app-level prompt and presenter then handle.
    @MainActor
    static func step(
        state: ServerAccountState,
        scope: WorkoutDataScope,
        answers: GuestAdoptionConsent.Answers,
        in context: ModelContext
    ) -> Step {
        if let id = ProfileOnboardingGate.accountNeedingOnboarding(
            state: state, scope: scope, answers: answers, in: context
        ) {
            return .profile(id)
        }
        guard case let .authenticated(profile) = state,
              let confirmed = UUID(uuidString: profile.user.id),
              scope == .account(confirmed)
        else { return .choose }
        return .finished
    }

    /// Returns the message to show when the user stays, nil otherwise.
    @MainActor
    static func run(
        _ flow: ProviderSignInFlow,
        _ provider: AuthProviderKind,
        onSignedIn: () -> Void
    ) async -> String? {
        switch await flow.start(provider) {
        case .signedIn:
            onSignedIn()
            return nil
        case let .stayed(message):
            return message
        }
    }
}

#if DEBUG
#Preview {
    OnboardingView {}
}
#endif
