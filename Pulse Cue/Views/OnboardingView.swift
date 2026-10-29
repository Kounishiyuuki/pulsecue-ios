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
/// server-confirmed Apple / Google sign-in, or after "ゲストで始める" — the
/// same `ProfileOnboardingView`, in place, for that account or for the guest.
/// Home is reached only by `onFinish`, so nobody sees Home before their
/// profile is complete, and the swap happens inside one cover rather than
/// dismissing to Home and presenting again.
///
/// Which account to onboard is still decided by `ProfileOnboardingGate`; the
/// app-level presenter stays blocked until `onFinish` and then finds nothing
/// left to ask. The guest's onboarding is owned here alone: the presenter
/// only ever asks for accounts.
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
    /// Set by the guest button only. A guest scope by itself is what every
    /// fresh install starts in, so it must not skip the three choices.
    @State private var guestChosen = false

    var body: some View {
        Group {
            switch step {
            case .choose:
                OnboardingView(
                    accountSignIn: .init(
                        authSession: authSession,
                        serverAccount: serverAccount,
                        // The state change this causes re-evaluates `step`.
                        onSignedIn: evaluate
                    ),
                    onPrimary: {
                        guestChosen = true
                        evaluate()
                    }
                )
            case .awaitingGuestAdoption, .waitingForScope, .finished:
                // No choices and no way to Home: while adoption is open its
                // alert is the only control, and `.finished` leaves at once.
                FirstLaunchWaitingView()
            case let .profile(scope):
                ProfileOnboardingView(scope: scope)
                    .id(scope)
            }
        }
        // The adoption question is asked here, over this cover, so answering
        // it never exposes Home; the app-level prompt is blocked meanwhile.
        .guestWorkoutAdoptionPrompt()
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
            guestChosen: guestChosen,
            in: modelContext
        )
        if step == .finished {
            onFinish()
        }
    }
}

/// The first-launch background between steps. Deliberately has no actions.
struct FirstLaunchWaitingView: View {
    var body: some View {
        ZStack {
            PulseAtmosphericBackground()
                .ignoresSafeArea()
            ProgressView()
                .accessibilityIdentifier("first-launch.waiting")
        }
    }
}

/// First-launch sign-in: onboarding completes only on a server-confirmed
/// session. Cancel and every failure keep the user on the first screen.
enum FirstLaunchSignIn {
    enum Step: Equatable {
        /// No server-confirmed account: show the three choices.
        case choose
        /// A confirmed account that must first answer the guest-adoption
        /// question; the profile it onboards depends on that answer.
        case awaitingGuestAdoption(UUID)
        /// The server confirmed an account the app is not showing yet: the
        /// scope resolver follows the account state on its own schedule, and
        /// until it does neither the guest's data nor another account's may
        /// decide anything.
        case waitingForScope
        /// A confirmed account (`.account`) or the guest (`.guest`) whose
        /// profile onboarding is not complete. Never `.undetermined`.
        case profile(HealthDataScope)
        /// Nothing left to ask here: go Home.
        case finished
    }

    /// Where the first-launch cover is, from the same inputs the profile gate
    /// reads. The gate also returns nil while the guest-adoption question is
    /// open, so that case is told apart here and never counts as finished.
    ///
    /// Without a confirmed account, the guest is onboarded only once chosen
    /// (`guestChosen`) or when its profile already holds a resume point from
    /// an earlier launch; a guest profile already marked complete finishes.
    @MainActor
    static func step(
        state: ServerAccountState,
        scope: WorkoutDataScope,
        answers: GuestAdoptionConsent.Answers,
        guestChosen: Bool = false,
        in context: ModelContext
    ) -> Step {
        if let id = ProfileOnboardingGate.accountNeedingOnboarding(
            state: state, scope: scope, answers: answers, in: context
        ) {
            return .profile(.account(id))
        }
        if case let .authenticated(profile) = state {
            // Fail closed: an unreadable id, or a scope still on the guest or
            // another account, never falls through to the guest checks below.
            guard let confirmed = UUID(uuidString: profile.user.id),
                  scope == .account(confirmed)
            else { return .waitingForScope }
            if GuestAdoptionConsent.question(for: confirmed, answers: answers, in: context) != nil {
                return .awaitingGuestAdoption(confirmed)
            }
            return .finished
        }
        guard scope == .guest else { return .choose }
        let guestProfile = UserProfileStore.profile(for: .guest, modelContext: context)
        if guestProfile?.profileOnboardingCompletedAt != nil { return .finished }
        if guestChosen || guestProfile?.profileOnboardingStepRaw != nil { return .profile(.guest) }
        return .choose
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
