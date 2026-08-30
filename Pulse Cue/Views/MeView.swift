//
//  MeView.swift
//  Pulse Cue
//
//  The root of the マイページ tab.
//
//  It used to be two rows: 「プロフィールとジム」 and 「設定」. The second opened
//  everything at once — height and age, HealthKit, the account, sign-in,
//  notification toggles, the app version — in a single scroll, which put "how
//  tall am I" and "should the app buzz" at the same level. The first mixed
//  body measurements with gym setup, and gym management moved to Training
//  along with the rest of the training features.
//
//  The distinction that was missing is between **your data** and **the app's
//  configuration**. So the tab separates them:
//
//    体と目標    height, weight, BMR/TDEE, the weight goal
//    ヘルスケア  HealthKit, and what the app may send
//    アカウント  sign-in, the server account, deletion
//    アプリ設定  notifications, help, version
//
//  Above them, one line of personal status: the current weight and how far it
//  is from the goal. That is what "me" is, and it was previously visible only
//  after opening a settings screen.
//
//  Nothing about those screens changed. `SettingsView` renders the same cards
//  with the same bindings, scoped to a section rather than split apart, so
//  this stays an information-architecture change.
//

import SwiftData
import SwiftUI

struct MeView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\UserProfile.updatedAt, order: .reverse)])
    private var profiles: [UserProfile]
    /// Change trigger for the cached weight. Not bounded to a display window,
    /// for the reason `TodayView` documents: a presentation range must not
    /// decide which weigh-in the app considers current.
    @Query(sort: [SortDescriptor(\DayLog.date, order: .reverse)])
    private var allDayLogs: [DayLog]

    /// Refresh signal for the cached weight; see `changeSignature` for why the
    /// array itself is not enough.
    private var latestWeightSignature: String {
        LatestBodyWeightResolver.changeSignature(for: allDayLogs)
    }

    /// The latest weigh-in, through the shared resolver, so Me, Home and
    /// Nutrition cannot disagree about which one it is.
    @State private var latestWeightKg: Double?

    var body: some View {
        ZStack {
            PulseAtmosphericBackground().ignoresSafeArea()

            ScrollView {
                VStack(spacing: 12) {
                    personalStatus

                    entry(
                        section: .bodyAndGoals,
                        subtitle: "身長・体重・基礎代謝・目標",
                        icon: "figure"
                    )
                    entry(
                        section: .health,
                        subtitle: "ヘルスケア連携とデータの送信範囲",
                        icon: "heart"
                    )
                    entry(
                        section: .account,
                        subtitle: "サインイン・連携・アカウントの削除",
                        icon: "person.crop.circle"
                    )
                    entry(
                        section: .app,
                        subtitle: "通知・ヘルプ・アプリ情報",
                        icon: "gearshape"
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("マイページ")
        .navigationBarTitleDisplayMode(.large)
        .task { refreshWeight() }
        .onChange(of: latestWeightSignature) { _, _ in refreshWeight() }
    }

    // MARK: - Personal status

    /// One quiet line, not a dashboard.
    ///
    /// Home already shows today's numbers, and repeating them here would make
    /// two places to look and two places to be wrong. This is the slower
    /// fact — where your weight is relative to where you want it — which
    /// nothing else surfaces.
    private var personalStatus: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("体重")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(latestWeightKg.map { "\(NumberFormat.weight($0)) kg" } ?? "未記録")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
            }

            if let goalDifferenceText {
                Divider().frame(height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text("目標まで")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(goalDifferenceText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.cardBackground.opacity(0.5))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusAccessibilityLabel)
        // Wraps rather than shrinks at accessibility sizes.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Distance to the goal weight, from the profile's own goal. Nothing is
    /// derived here that the profile does not already hold.
    private var goalDifferenceText: String? {
        guard let latestWeightKg,
              let goal = profiles.first?.goalWeightKg,
              goal > 0
        else { return nil }

        let delta = latestWeightKg - goal
        if abs(delta) < 0.05 { return "達成" }
        return delta > 0
            ? "-\(NumberFormat.weight(delta)) kg"
            : "+\(NumberFormat.weight(abs(delta))) kg"
    }

    private var statusAccessibilityLabel: String {
        var parts: [String] = []
        parts.append(
            latestWeightKg.map { "体重 \(NumberFormat.weight($0)) キログラム" } ?? "体重 未記録"
        )
        if let goalDifferenceText {
            parts.append("目標まで \(goalDifferenceText)")
        }
        return parts.joined(separator: "、")
    }

    private func refreshWeight() {
        latestWeightKg = LatestBodyWeightResolver.latestWeightKg(
            modelContext: modelContext
        )
    }

    // MARK: - Entries

    private func entry(
        section: SettingsSection,
        subtitle: String,
        icon: String
    ) -> some View {
        NavigationLink {
            SettingsView(section: section)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(section.title)
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
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .pulseGlass(level: .functional, padding: 0)
            // One element naming the destination, with the description as a
            // hint. Read separately, the icon, title and subtitle stop
            // sounding like a single button.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(section.title)
            .accessibilityHint(subtitle)
            .accessibilityAddTraits(.isButton)
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
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
