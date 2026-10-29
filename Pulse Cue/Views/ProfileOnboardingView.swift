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

/// The answers being edited, before anything is stored.
struct ProfileOnboardingDraft: Equatable {
    var ageYears: Int
    var heightCm: Int
    var currentWeightText: String
    var biologicalSex: BiologicalSex
    var trainingGoal: ProfileTrainingGoal?
    var goalWeightText: String
    var trainingDaysPerWeek: Int
    var preferredSessionMinutes: Int
    var experienceLevel: ExperienceLevel?

    // The same bounds Settings offers, so nothing entered here is a value
    // Settings could not show.
    static let ageRange = 10...100
    static let heightRange = 120...220
    static let currentWeightRange = 30.0...250.0
    static let goalWeightRange = 30.0...150.0
    static let daysRange = 1...7
    static let minutesRange = 10...180

    init(profile: UserProfile?, latestWeightKg: Double?) {
        ageYears = profile?.ageYears ?? 30
        heightCm = profile?.heightCm ?? 170
        currentWeightText = latestWeightKg.map { NumberFormat.weight($0) } ?? ""
        biologicalSex = profile?.biologicalSex ?? .unspecified
        trainingGoal = profile?.trainingGoal
        goalWeightText = profile.map { NumberFormat.weight($0.goalWeightKg) } ?? ""
        trainingDaysPerWeek = profile?.trainingDaysPerWeek ?? 3
        preferredSessionMinutes = profile?.preferredSessionMinutes ?? 45
        experienceLevel = profile?.experienceLevel
    }

    var currentWeightKg: Double? { Self.parse(currentWeightText, in: Self.currentWeightRange) }
    var goalWeightKg: Double? { Self.parse(goalWeightText, in: Self.goalWeightRange) }

    var isBasicsValid: Bool {
        Self.ageRange.contains(ageYears) && Self.heightRange.contains(heightCm) && currentWeightKg != nil
    }
    var isGoalValid: Bool { trainingGoal != nil && goalWeightKg != nil }
    var isHabitsValid: Bool {
        Self.daysRange.contains(trainingDaysPerWeek)
            && Self.minutesRange.contains(preferredSessionMinutes)
            && experienceLevel != nil
    }

    /// Accepts "65.5" and "65,5": a decimal pad in a comma locale types the
    /// latter.
    static func parse(_ text: String, in range: ClosedRange<Double>) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), range.contains(value) else { return nil }
        return value
    }

    /// Writes the answers into `scope`'s profile — the existing one, or a new
    /// one if the scope has none — and today's weight into today's day log,
    /// Nil, with nothing written, if the draft is incomplete or the scope
    /// cannot hold health data. Does not mark completion: that is
    /// `markCompleted`, because the marker is what dismisses the screen.
    @MainActor
    @discardableResult
    func apply(to scope: HealthDataScope, modelContext: ModelContext, now: Date = Date()) -> UserProfile? {
        guard isBasicsValid, isGoalValid, isHabitsValid,
              let currentWeightKg, let goalWeightKg,
              let draft = UserProfileStore.draftProfile(for: scope),
              let profile = UserProfileStore.persistDraft(draft, for: scope, modelContext: modelContext),
              let log = DayLogStore.fetchOrCreateToday(scope: scope, modelContext: modelContext, now: now)
        else { return nil }
        profile.ageYears = ageYears
        profile.heightCm = heightCm
        profile.biologicalSex = biologicalSex
        profile.goalWeightKg = goalWeightKg
        profile.trainingGoal = trainingGoal
        profile.experienceLevel = experienceLevel
        profile.trainingDaysPerWeek = trainingDaysPerWeek
        profile.preferredSessionMinutes = preferredSessionMinutes
        profile.updatedAt = now
        log.weightKg = currentWeightKg
        return profile
    }

    /// Records that `scope`'s profile finished onboarding. False if the scope
    /// has no stored profile — `apply` comes first.
    @MainActor
    @discardableResult
    static func markCompleted(scope: HealthDataScope, modelContext: ModelContext, now: Date = Date()) -> Bool {
        guard let profile = UserProfileStore.profile(for: scope, modelContext: modelContext) else { return false }
        profile.profileOnboardingCompletedAt = now
        return true
    }
}

struct ProfileOnboardingView: View {
    let accountID: UUID

    @Environment(\.modelContext) private var modelContext

    private enum Step: Int, CaseIterable {
        case basics, goal, habits, done

        var title: String {
            switch self {
            case .basics: return "基本情報"
            case .goal: return "目標"
            case .habits: return "トレーニング習慣"
            case .done: return "準備完了"
            }
        }
    }

    @State private var step: Step = .basics
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
            .navigationTitle(step.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step != .basics && step != .done {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("戻る") { move(by: -1) }
                            .accessibilityIdentifier("profile-onboarding-back")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            guard draft == nil else { return }
            draft = ProfileOnboardingDraft(
                profile: UserProfileStore.profile(for: scope, modelContext: modelContext),
                latestWeightKg: LatestBodyWeightResolver.latestWeightKg(scope: scope, modelContext: modelContext)
            )
        }
        .alert("保存できませんでした", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("入力内容はそのままです。もう一度お試しください。")
        }
    }

    // MARK: - Progress

    private var progress: some View {
        let total = Step.allCases.count
        return VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(step.rawValue + 1), total: Double(total))
                .tint(AppTheme.accent)
            Text("ステップ \(step.rawValue + 1) / \(total)")
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
                Stepper(value: draft.ageYears, in: ProfileOnboardingDraft.ageRange) {
                    LabeledContent("年齢", value: "\(draft.wrappedValue.ageYears) 歳")
                }
                .accessibilityIdentifier("profile-onboarding-age")
                Stepper(value: draft.heightCm, in: ProfileOnboardingDraft.heightRange) {
                    LabeledContent("身長", value: "\(draft.wrappedValue.heightCm) cm")
                }
                .accessibilityIdentifier("profile-onboarding-height")
                weightField("現在の体重", text: draft.currentWeightText, identifier: "profile-onboarding-current-weight")
                Picker("性別（任意）", selection: draft.biologicalSex) {
                    ForEach(BiologicalSex.allCases) { Text($0.label).tag($0) }
                }
            } footer: {
                validation(
                    draft.wrappedValue.currentWeightText.isEmpty || draft.wrappedValue.currentWeightKg != nil,
                    "体重は 30〜250 kg で入力してください。"
                )
            }
        case .goal:
            Section("トレーニングの目的") {
                Picker("目的", selection: draft.trainingGoal) {
                    Text("選択してください").tag(ProfileTrainingGoal?.none)
                    ForEach(ProfileTrainingGoal.allCases) { Text($0.label).tag(Optional($0)) }
                }
                .accessibilityIdentifier("profile-onboarding-goal")
            }
            Section {
                weightField("目標体重", text: draft.goalWeightText, identifier: "profile-onboarding-goal-weight")
            } footer: {
                validation(
                    draft.wrappedValue.goalWeightText.isEmpty || draft.wrappedValue.goalWeightKg != nil,
                    "目標体重は 30〜150 kg で入力してください。"
                )
            }
        case .habits:
            Section {
                Stepper(value: draft.trainingDaysPerWeek, in: ProfileOnboardingDraft.daysRange) {
                    LabeledContent("週あたり", value: "\(draft.wrappedValue.trainingDaysPerWeek) 回")
                }
                .accessibilityIdentifier("profile-onboarding-days")
                Stepper(value: draft.preferredSessionMinutes, in: ProfileOnboardingDraft.minutesRange, step: 5) {
                    LabeledContent("1回あたり", value: "\(draft.wrappedValue.preferredSessionMinutes) 分")
                }
                .accessibilityIdentifier("profile-onboarding-minutes")
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

    private func weightField(_ label: String, text: Binding<String>, identifier: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField("0.0", text: text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier(identifier)
                Text("kg").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func validation(_ isValid: Bool, _ message: String) -> some View {
        if !isValid {
            Text(message).foregroundStyle(.orange)
        }
    }

    // MARK: - Footer

    private func footer(_ draft: ProfileOnboardingDraft) -> some View {
        Button {
            advance(draft)
        } label: {
            Text(step == .habits ? "保存する" : step == .done ? "はじめる" : "次へ")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(AppTheme.accentFilled)
        .disabled(!canAdvance(draft))
        .padding(16)
        .accessibilityIdentifier("profile-onboarding-next")
    }

    private func canAdvance(_ draft: ProfileOnboardingDraft) -> Bool {
        switch step {
        case .basics: return draft.isBasicsValid
        case .goal: return draft.isGoalValid
        case .habits: return draft.isHabitsValid
        case .done: return true
        }
    }

    private func advance(_ draft: ProfileOnboardingDraft) {
        switch step {
        case .basics, .goal:
            move(by: 1)
        case .habits:
            // The answers are stored here; the marker waits for "はじめる",
            // since setting it dismisses the cover before the last page shows.
            guard draft.apply(to: scope, modelContext: modelContext) != nil else {
                saveFailed = true
                return
            }
            do {
                try modelContext.save()
                move(by: 1)
            } catch {
                saveFailed = true
            }
        case .done:
            guard ProfileOnboardingDraft.markCompleted(scope: scope, modelContext: modelContext) else {
                saveFailed = true
                return
            }
            do {
                try modelContext.save()
            } catch {
                UserProfileStore.profile(for: scope, modelContext: modelContext)?.profileOnboardingCompletedAt = nil
                saveFailed = true
            }
        }
    }

    private func move(by offset: Int) {
        guard let next = Step(rawValue: step.rawValue + offset) else { return }
        step = next
    }
}
