//
//  ProfileOnboardingView.swift
//  Pulse Cue
//
//  The personal-profile questions asked once per PulseCue account, after the
//  server has confirmed the sign-in — Apple or Google alike, because both end
//  in the same `ServerAccountStore.authenticated` state and the same internal
//  account UUID.
//
//  "Once" is the account's own profile: `profileOnboardingCompletedAt` on the
//  `UserProfile` it owns. Not a device-wide flag — a second account on the
//  same phone has never answered, and signing out and back in has. Deleting
//  the account deletes its profile, so the marker goes with it.
//
//  It waits for the guest-adoption question. Finishing here stores an account
//  profile, and an account that already has one keeps it instead of adopting
//  the guest's — so asking first would silently decide adoption's profile
//  half. Once that question is answered (or there is nothing to ask), the
//  profile this screen edits is whichever one adoption left: the guest's, if
//  it was carried over, or a fresh one.
//
//  Nothing here is stored twice. Age, height, sex and the goal weight are the
//  same `UserProfile` fields Settings edits; the current weight is today's
//  `DayLog.weightKg`, which is where every screen already reads it from.
//

import SwiftUI
import SwiftData

extension View {
    /// Presents the profile onboarding when the signed-in account has not
    /// completed it. `isBlocked` holds it back while something else owns the
    /// screen (first-launch onboarding, the Runner).
    func profileOnboarding(isBlocked: Bool) -> some View {
        modifier(ProfileOnboardingPresenter(isBlocked: isBlocked))
    }
}

private struct ProfileOnboardingPresenter: ViewModifier {
    let isBlocked: Bool

    @EnvironmentObject private var serverAccount: ServerAccountStore
    @EnvironmentObject private var dataScope: WorkoutDataScopeResolver
    @Environment(\.modelContext) private var modelContext

    @Query private var everyProfile: [UserProfile]
    @AppStorage(GuestAdoptionConsent.workoutAnsweredKey) private var workoutAnsweredRaw = ""
    @AppStorage(GuestAdoptionConsent.healthAnsweredKey) private var healthAnsweredRaw = ""

    @State private var pendingAccountID: UUID?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: evaluate)
            .onChange(of: serverAccount.state) { _, _ in evaluate() }
            .onChange(of: dataScope.scope) { _, _ in evaluate() }
            .onChange(of: workoutAnsweredRaw) { _, _ in evaluate() }
            .onChange(of: healthAnsweredRaw) { _, _ in evaluate() }
            .onChange(of: completionSignature) { _, _ in evaluate() }
            .fullScreenCover(isPresented: Binding(
                get: { !isBlocked && pendingAccountID != nil },
                // Not dismissible by gesture: the cover goes away only when
                // the profile records completion (or the account changes).
                set: { _ in }
            )) {
                if let id = pendingAccountID {
                    ProfileOnboardingView(accountID: id)
                        .interactiveDismissDisabled()
                        // A different account is a different screen: never
                        // carry one account's half-typed answers to the next.
                        .id(id)
                }
            }
    }

    /// Changes whenever any profile's owner or completion does, so finishing
    /// (or adoption moving a profile) re-evaluates.
    private var completionSignature: String {
        everyProfile
            .map { "\($0.id)|\($0.ownerAccountID?.uuidString ?? "-")|\($0.profileOnboardingCompletedAt?.timeIntervalSince1970 ?? 0)" }
            .sorted()
            .joined(separator: ",")
    }

    private func evaluate() {
        pendingAccountID = ProfileOnboardingGate.accountNeedingOnboarding(
            state: serverAccount.state,
            scope: dataScope.scope,
            answers: .init(workoutRaw: workoutAnsweredRaw, healthRaw: healthAnsweredRaw),
            in: modelContext
        )
    }
}

/// When to ask, apart from the view, so the contract is testable.
@MainActor
enum ProfileOnboardingGate {

    /// The account to onboard now, or nil.
    ///
    /// Only a server-confirmed session whose account is the one the app is
    /// showing: an offline launch resolves to the last confirmed account but
    /// has not been confirmed this time, and a provider sign-in that the
    /// server has not answered is no account at all.
    static func accountNeedingOnboarding(
        state: ServerAccountState,
        scope: WorkoutDataScope,
        answers: GuestAdoptionConsent.Answers,
        in context: ModelContext
    ) -> UUID? {
        guard case let .authenticated(profile) = state,
              let confirmed = UUID(uuidString: profile.user.id),
              case let .account(id) = scope,
              id == confirmed
        else { return nil }
        guard GuestAdoptionConsent.question(for: id, answers: answers, in: context) == nil else { return nil }
        if let existing = UserProfileStore.profile(for: scope, modelContext: context),
           existing.profileOnboardingCompletedAt != nil {
            return nil
        }
        return id
    }
}

/// The answers being edited. Each step's answers are stored when that step
/// is left with "次へ", together with the step to resume at, so quitting
/// mid-way loses at most the page on screen.
struct ProfileOnboardingDraft: Equatable {
    var ageYears: Int
    var heightCm: Int
    var currentWeightKg: Double?
    var biologicalSex: BiologicalSex
    var activityFactor: ActivityFactor
    var trainingGoal: ProfileTrainingGoal?
    var goalWeightKg: Double?
    var weeklyChangeKg: Double
    var trainingDaysPerWeek: Int
    var preferredSessionMinutes: Int
    var experienceLevel: ExperienceLevel?

    /// Where a brand-new profile's age wheel starts. Onboarding's own choice,
    /// not `UserProfile`'s default, which Settings and older data rely on.
    static let newProfileAgeYears = 20

    init(profile: UserProfile?, latestWeightKg: Double?) {
        // A new profile's defaults, so a fresh draft starts where Settings
        // would. Only a profile that saved the goal step is trusted for the
        // weekly change: the -0.5 default assumes weight loss.
        let base = profile ?? UserProfile()
        ageYears = profile?.ageYears ?? Self.newProfileAgeYears
        heightCm = base.heightCm
        // Snapped onto the wheels' grids, so what the wheel shows is exactly
        // what is saved. A value outside the range stays out (and invalid)
        // rather than being clamped into a weight nobody entered.
        currentWeightKg = latestWeightKg
            .flatMap { ProfileFieldRanges.bodyWeightKg.contains($0) ? $0 : nil }
            .map(NumericWheelScale.bodyWeightKg.snapped)
        biologicalSex = base.biologicalSex
        activityFactor = base.activityFactor
        trainingGoal = base.trainingGoal
        goalWeightKg = profile
            .map(\.goalWeightKg)
            .flatMap { ProfileFieldRanges.goalWeightKg.contains($0) ? $0 : nil }
            .map(NumericWheelScale.goalWeightKg.snapped)
        weeklyChangeKg = base.trainingGoal.map { _ in base.weeklyChangeKg } ?? 0
        trainingDaysPerWeek = base.trainingDaysPerWeek ?? 3
        preferredSessionMinutes = base.preferredSessionMinutes
            .map { QuickPlanDuration(minutes: $0).minutes } ?? ProfileFieldRanges.defaultSessionMinutes
        experienceLevel = base.experienceLevel
    }

    func isValid(_ step: ProfileOnboardingStep) -> Bool {
        switch step {
        case .basics:
            return ProfileFieldRanges.ageYears.contains(ageYears)
                && ProfileFieldRanges.heightCm.contains(heightCm)
                && currentWeightKg.map(ProfileFieldRanges.bodyWeightKg.contains) == true
        case .goal:
            return trainingGoal != nil
                && goalWeightKg.map(ProfileFieldRanges.goalWeightKg.contains) == true
                && ProfileFieldRanges.weeklyChangeKg.contains(weeklyChangeKg)
        case .habits:
            return ProfileFieldRanges.trainingDaysPerWeek.contains(trainingDaysPerWeek)
                && ProfileFieldRanges.isValidSessionMinutes(preferredSessionMinutes)
                && experienceLevel != nil
        case .done:
            return true
        }
    }

    /// Stores `step`'s answers in `scope`'s profile — the existing one, or a
    /// new one — and moves the resume point past it. `.done` marks the
    /// profile onboarded and clears the resume point. Nil, with nothing
    /// written, if the step is invalid or the scope cannot hold health data.
    ///
    /// The caller saves; the gate has already waited for guest adoption, so
    /// creating the account profile here cannot pre-empt it.
    @MainActor
    @discardableResult
    func save(
        _ step: ProfileOnboardingStep,
        to scope: HealthDataScope,
        modelContext: ModelContext,
        now: Date = Date()
    ) -> UserProfile? {
        guard isValid(step),
              let draft = UserProfileStore.draftProfile(for: scope),
              let profile = UserProfileStore.persistDraft(draft, for: scope, modelContext: modelContext)
        else { return nil }
        switch step {
        case .basics:
            guard let currentWeightKg,
                  let log = DayLogStore.fetchOrCreateToday(scope: scope, modelContext: modelContext, now: now)
            else { return nil }
            profile.ageYears = ageYears
            profile.heightCm = heightCm
            profile.biologicalSex = biologicalSex
            profile.activityFactor = activityFactor
            log.weightKg = currentWeightKg
        case .goal:
            guard let goalWeightKg else { return nil }
            profile.trainingGoal = trainingGoal
            profile.goalWeightKg = goalWeightKg
            profile.weeklyChangeKg = weeklyChangeKg
        case .habits:
            profile.trainingDaysPerWeek = trainingDaysPerWeek
            profile.preferredSessionMinutes = preferredSessionMinutes
            profile.experienceLevel = experienceLevel
        case .done:
            profile.profileOnboardingCompletedAt = now
        }
        if let next = step.next {
            profile.profileOnboardingStep = next
        } else {
            profile.profileOnboardingStepRaw = nil
        }
        profile.updatedAt = now
        return profile
    }
}

struct ProfileOnboardingView: View {
    let accountID: UUID

    @Environment(\.modelContext) private var modelContext

    @State private var step: ProfileOnboardingStep = .basics
    @State private var draft: ProfileOnboardingDraft?
    @State private var saveFailed = false

    private var scope: HealthDataScope { .account(accountID) }

    var body: some View {
        NavigationStack {
            Group {
                if let binding = Binding($draft) {
                    VStack(spacing: 0) {
                        progress
                        Form { stepContent(binding) }
                        footer(binding.wrappedValue)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(Self.title(step))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let previous = step.previous, step != .done {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("戻る") { step = previous }
                            .accessibilityIdentifier("profile-onboarding-back")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            guard draft == nil else { return }
            let profile = UserProfileStore.profile(for: scope, modelContext: modelContext)
            draft = ProfileOnboardingDraft(
                profile: profile,
                latestWeightKg: LatestBodyWeightResolver.latestWeightKg(scope: scope, modelContext: modelContext)
            )
            // A profile without the marker resumes where it stopped; one that
            // never saved a step (or an existing profile from before V10)
            // starts at the beginning.
            step = profile?.profileOnboardingStep ?? .basics
        }
        .alert("保存できませんでした", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("入力内容はそのままです。もう一度お試しください。")
        }
    }

    private static func title(_ step: ProfileOnboardingStep) -> String {
        switch step {
        case .basics: return "基本情報"
        case .goal: return "目標"
        case .habits: return "トレーニング習慣"
        case .done: return "準備完了"
        }
    }

    // MARK: - Progress

    private var progress: some View {
        let all = ProfileOnboardingStep.allCases
        let index = (all.firstIndex(of: step) ?? 0) + 1
        return VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(index), total: Double(all.count))
                .tint(AppTheme.accent)
            Text("ステップ \(index) / \(all.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("profile-onboarding-progress")
    }

    // MARK: - Steps

    @ViewBuilder
    private func stepContent(_ draft: Binding<ProfileOnboardingDraft>) -> some View {
        switch step {
        case .basics:
            Section {
                NumericWheelField(
                    "年齢", unit: "歳", scale: .ageYears,
                    value: draft.ageYears.wheelValue,
                    initial: Double(ProfileOnboardingDraft.newProfileAgeYears),
                    identifier: "profile-onboarding-age"
                )
                NumericWheelField(
                    "身長", unit: "cm", scale: .heightCm,
                    value: draft.heightCm.wheelValue,
                    initial: Double(draft.wrappedValue.heightCm),
                    identifier: "profile-onboarding-height"
                )
                NumericWheelField(
                    "現在の体重", unit: "kg", scale: .bodyWeightKg,
                    value: draft.currentWeightKg,
                    initial: Self.initialWeightKg,
                    identifier: "profile-onboarding-current-weight"
                )
                Picker("性別（任意）", selection: draft.biologicalSex) {
                    ForEach(BiologicalSex.allCases) { Text($0.label).tag($0) }
                }
                Picker("活動量", selection: draft.activityFactor) {
                    ForEach(ActivityFactor.allCases) { Text($0.label).tag($0) }
                }
                .accessibilityIdentifier("profile-onboarding-activity")
            } footer: {
                if draft.wrappedValue.currentWeightKg == nil {
                    Text("現在の体重を選択してください。")
                }
            }
        case .goal:
            Section("トレーニングの目的") {
                Picker("目的", selection: draft.trainingGoal) {
                    Text("選択してください").tag(ProfileTrainingGoal?.none)
                    ForEach(ProfileTrainingGoal.allCases) { Text($0.label).tag(Optional($0)) }
                }
                .accessibilityIdentifier("profile-onboarding-goal")
                .onChange(of: draft.wrappedValue.trainingGoal) { _, goal in
                    if let goal { draft.wrappedValue.weeklyChangeKg = goal.suggestedWeeklyChangeKg }
                }
            }
            Section {
                NumericWheelField(
                    "目標体重", unit: "kg", scale: .goalWeightKg,
                    value: draft.goalWeightKg,
                    initial: NumericWheelScale.goalWeightKg.snapped(draft.wrappedValue.currentWeightKg ?? Self.initialWeightKg),
                    identifier: "profile-onboarding-goal-weight"
                )
                NumericWheelField(
                    "週あたりの変化量", unit: "kg", scale: .weeklyChangeKg, signed: true,
                    value: draft.weeklyChangeKg.wheelValue,
                    initial: draft.wrappedValue.weeklyChangeKg,
                    identifier: "profile-onboarding-weekly-change"
                )
            } footer: {
                Text("推奨: -0.5 〜 +0.5 kg/週。目標摂取カロリーの計算に使います。")
            }
        case .habits:
            Section {
                NumericWheelField(
                    "週あたり", unit: "回", scale: .trainingDaysPerWeek,
                    value: draft.trainingDaysPerWeek.wheelValue,
                    initial: Double(draft.wrappedValue.trainingDaysPerWeek),
                    identifier: "profile-onboarding-days"
                )
                NumericWheelField(
                    "1回あたり", unit: "分", scale: .sessionMinutes,
                    value: draft.preferredSessionMinutes.wheelValue,
                    initial: Double(ProfileFieldRanges.defaultSessionMinutes),
                    identifier: "profile-onboarding-minutes"
                )
                Picker("経験レベル", selection: draft.experienceLevel) {
                    Text("選択してください").tag(ExperienceLevel?.none)
                    ForEach(ExperienceLevel.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                }
                .accessibilityIdentifier("profile-onboarding-experience")
            }
        case .done:
            Section {
                Label("プロフィールを保存しました", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.accent)
                Text("内容は「設定 › 体と目標」からいつでも変更できます。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Where an unset weight wheel opens: mid-range for an adult, so reaching
    /// any common weight is a short scroll.
    private static let initialWeightKg = 60.0

    // MARK: - Footer

    private func footer(_ draft: ProfileOnboardingDraft) -> some View {
        Button {
            advance(draft)
        } label: {
            Text(step == .done ? "はじめる" : "次へ")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(AppTheme.accentFilled)
        .disabled(!draft.isValid(step))
        .padding(16)
        .accessibilityIdentifier("profile-onboarding-next")
    }

    /// Saves the page on screen and its resume point in one commit. On
    /// `.done` that commit is the completion marker, which dismisses the
    /// cover. A failed save stays on the page; not `rollback()`, which would
    /// discard unrelated unsaved work in the shared context.
    private func advance(_ draft: ProfileOnboardingDraft) {
        guard draft.save(step, to: scope, modelContext: modelContext) != nil else {
            saveFailed = true
            return
        }
        do {
            try modelContext.save()
        } catch {
            saveFailed = true
            return
        }
        if let next = step.next { step = next }
    }
}

#if DEBUG
/// The `-pulsecue-ui-test-profile-onboarding` root: the real onboarding
/// screen for one fake account, then a stand-in Home once it completes.
struct ProfileOnboardingFixtureRoot: View {
    static let accountID = UUID(uuidString: "0B0A0D00-0000-0000-0000-0000000000F1")!

    @State private var container = Self.makeContainer()

    var body: some View {
        Content().modelContainer(container)
    }

    private struct Content: View {
        @Query private var everyProfile: [UserProfile]

        var body: some View {
            let profile = UserProfileStore.select(from: everyProfile, scope: .account(ProfileOnboardingFixtureRoot.accountID))
            if profile?.profileOnboardingCompletedAt != nil {
                Text("ホーム")
                    .accessibilityIdentifier("profile-onboarding-fixture-home")
            } else {
                ProfileOnboardingView(accountID: ProfileOnboardingFixtureRoot.accountID)
            }
        }
    }

    /// A store of its own in Caches, never the app's: the fixture must be
    /// able to survive a relaunch without touching real data.
    private static func makeContainer() -> ModelContainer {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("uitest-profile-onboarding.sqlite")
        if ProcessInfo.processInfo.arguments.contains(PulseCueUITestSupport.profileOnboardingResetArgument) {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        let schema = Schema(versionedSchema: PulseCueSchemaV10.self)
        do {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        } catch {
            fatalError("Could not open the profile onboarding fixture store at \(url.path): \(error)")
        }
    }
}
#endif
