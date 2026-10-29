//
//  SettingsView.swift
//  Pulse Cue
//
//  The settings shell: background, the profile every section needs, and which
//  section is on screen.
//
//  It used to be the whole of settings — body measurements, HealthKit, the
//  account, notification toggles, the save CTA and every glass helper in one
//  1,100-line file. Scoping it to a `SettingsSection` gave マイページ four
//  honest entrances, but left one type owning four unrelated jobs: a change to
//  the account footnote and a change to the BMR card touched the same file, and
//  `@State` for a login sheet sat beside `@State` for a cached body weight.
//
//  So each responsibility is now its own view, and each owns what only it
//  uses — its queries, its sheets, its permission state. What is left here is
//  what genuinely is shared: the background, the profile, and the save toast,
//  which overlays the screen rather than belonging to any one card.
//

import SwiftUI
import SwiftData
import UserNotifications

struct SettingsView: View {
    /// Defaults to the whole screen so previews and the QA harness keep
    /// working unchanged.
    var section: SettingsSection?

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var dataScope: WorkoutDataScopeResolver

    // UserProfile is the source of truth for profile / goal fields — the
    // current scope's profile, never another account's.
    @Query private var everyProfile: [UserProfile]

    @State private var showSavedToast = false

    /// The profile shown while the scope has none stored. Looking at Settings
    /// is not an edit, so nothing is inserted until something changes: an
    /// account profile created by opening this screen would already exist
    /// when the adoption prompt is answered, and the guest's profile would
    /// stay behind. Tagged with its scope so a draft for A is never shown or
    /// saved under B.
    @State private var draft: HealthScopedValue<UserProfile>?

    /// - Parameter section: which group to show. `nil` shows all of them,
    ///   which is what the previews and the QA harness use.
    init(section: SettingsSection? = nil) {
        self.section = section
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            PulseAtmosphericBackground().ignoresSafeArea()

            if let profile = UserProfileStore.select(from: everyProfile, scope: dataScope.scope) {
                content(profile: profile)
            } else if let draft = draft?.value(in: dataScope.scope) {
                content(profile: draft)
                    .onChange(of: Self.editSignature(draft)) { _, _ in persistDraft() }
            } else {
                // Keyed on the scope: while it is undetermined there is no
                // draft, and the confirmed scope must get its chance.
                ProgressView("読み込み中…")
                    .task(id: dataScope.scope) {
                        draft = UserProfileStore.draftProfile(for: dataScope.scope)
                            .map { HealthScopedValue(scope: dataScope.scope, value: $0) }
                    }
            }

            if showSavedToast {
                savedToast
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationTitle(section?.title ?? "設定")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            guard Self.parentOwnsNotificationRefresh(for: section) else { return }
            refreshNotificationStatus()
        }
    }

    @ViewBuilder
    private func content(profile: UserProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if shows(.bodyAndGoals) {
                    BodyGoalsSettingsSection(profile: profile, onSaved: confirmSave)
                }
                if shows(.health) {
                    HealthSettingsSection()
                }
                if shows(.account) {
                    AccountSettingsSection()
                }
                if shows(.app) {
                    AppPreferencesSection()
                }
                Color.clear.frame(height: 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    /// Whether this group belongs on screen. No section means all of them.
    private func shows(_ group: SettingsSection) -> Bool {
        section == nil || section == group
    }

    /// The extracted App Preferences section refreshes while it is mounted.
    /// Every other scoped Settings screen keeps the shell-level refresh that
    /// ran before the extraction. The all-sections QA screen also mounts App
    /// Preferences, so the child remains its single refresh owner there.
    static func parentOwnsNotificationRefresh(for section: SettingsSection?) -> Bool {
        section != nil && section != .app
    }

    /// Preserves the pre-extraction Settings lifecycle side effect without
    /// taking presentation state back from `AppPreferencesSection`.
    private func refreshNotificationStatus() {
        NotificationManager.shared.getAuthorizationStatus { status in
            let authorized = (status == .authorized || status == .provisional)
            if !authorized && settings.notificationsEnabled {
                settings.notificationsEnabled = false
            }
        }
    }

    // MARK: - Save confirmation

    /// Cosmetic confirmation. Every control writes through on change, so there
    /// is nothing to commit — the toast exists because a settings screen with
    /// no acknowledgement leaves people unsure their edit took.
    /// Stores the draft once the person has edited or saved it. A no-op once
    /// the scope has a stored profile.
    private func persistDraft() {
        guard let draft = draft?.value(in: dataScope.scope) else { return }
        UserProfileStore.persistDraft(draft, for: dataScope.scope, modelContext: modelContext)
    }

    /// Every field the body-and-goals controls write.
    private static func editSignature(_ profile: UserProfile) -> String {
        "\(profile.heightCm)|\(profile.ageYears)|\(profile.biologicalSexRaw)|\(profile.activityFactorRaw)|\(profile.goalWeightKg)|\(profile.weeklyChangeKg)|\(profile.trainingGoalRaw ?? "")|\(profile.experienceLevelRaw ?? "")|\(profile.trainingDaysPerWeek ?? 0)|\(profile.preferredSessionMinutes ?? 0)"
    }

    private func confirmSave() {
        persistDraft()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            showSavedToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut(duration: 0.25)) {
                showSavedToast = false
            }
        }
    }

    private var savedToast: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white)
            Text("保存しました")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(AppTheme.accentFilled)
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        )
    }
}
