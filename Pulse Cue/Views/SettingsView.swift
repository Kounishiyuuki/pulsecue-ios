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

struct SettingsView: View {
    /// Defaults to the whole screen so previews and the QA harness keep
    /// working unchanged.
    var section: SettingsSection?

    @Environment(\.modelContext) private var modelContext

    // UserProfile is the source of truth for profile / goal fields.
    @Query(sort: [SortDescriptor(\UserProfile.updatedAt, order: .reverse)])
    private var profiles: [UserProfile]

    @State private var showSavedToast = false

    /// - Parameter section: which group to show. `nil` shows all of them,
    ///   which is what the previews and the QA harness use.
    init(section: SettingsSection? = nil) {
        self.section = section
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            PulseAtmosphericBackground().ignoresSafeArea()

            if let profile = profiles.first {
                content(profile: profile)
            } else {
                ProgressView("読み込み中…")
                    .task {
                        _ = UserProfileStore.fetchOrCreate(modelContext: modelContext)
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

    // MARK: - Save confirmation

    /// Cosmetic confirmation. Every control writes through on change, so there
    /// is nothing to commit — the toast exists because a settings screen with
    /// no acknowledgement leaves people unsure their edit took.
    private func confirmSave() {
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
