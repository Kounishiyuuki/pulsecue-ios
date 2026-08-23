//
//  MeView.swift
//  Pulse Cue
//
//  The root of the マイページ tab.
//
//  Deliberately thin. Settings used to be a primary tab, and the honest
//  reason it should not be is that "settings" is not something anyone opens
//  the app to do — it is where you go because of something else. But it still
//  needs a reliable home, and so does the profile, so this is that home and
//  nothing more.
//
//  What this is **not**: a dashboard. No summaries, no counts, no cards. Every
//  destination here already exists and is presented exactly the way it is
//  presented elsewhere in the app — `ProfileGymSetupView` as a sheet, because
//  it owns its own navigation stack and a 完了 button, and `SettingsView` as a
//  push, because it does not. Inventing a new surface on the way past would
//  make this navigation change harder to review and harder to undo.
//

import SwiftUI

struct MeView: View {
    @State private var showProfileGymSetup = false

    var body: some View {
        ZStack {
            PulseAtmosphericBackground().ignoresSafeArea()

            ScrollView {
                VStack(spacing: 12) {
                    Button {
                        showProfileGymSetup = true
                    } label: {
                        row(
                            title: "プロフィールとジム",
                            subtitle: "身長・体重・マイジムの設定",
                            icon: "person.crop.circle"
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        SettingsView()
                    } label: {
                        row(
                            title: "設定",
                            subtitle: "アカウント・通知・連携・アプリ情報",
                            icon: "gearshape"
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .navigationTitle("マイページ")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showProfileGymSetup) {
            ProfileGymSetupView()
        }
    }

    private func row(title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .pulseGlass(level: .functional, padding: 0)
        // One element saying the destination, with the description as a hint.
        // Without this VoiceOver reads the icon, the title and the subtitle as
        // three separate things and the row stops sounding like a button.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
        .accessibilityAddTraits(.isButton)
    }
}

#if DEBUG
#Preview("Me") {
    NavigationStack {
        MeView()
    }
    .environmentObject(SettingsStore())
    .environmentObject(AuthSessionStore())
}
#endif
