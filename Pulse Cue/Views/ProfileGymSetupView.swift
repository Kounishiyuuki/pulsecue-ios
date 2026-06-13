//
//  ProfileGymSetupView.swift
//  Pulse Cue
//
//  A single, calm "Apple Health Light" setup surface that ties together the
//  profile + gym basics after login / account entry. It is built only on
//  `AppTheme` + `PulseUI` primitives so it matches Onboarding / Login tone.
//
//  IMPORTANT — this view is NOT a new source of truth. It summarizes and edits
//  through the EXISTING stores/models:
//    - 身長     → `UserProfile.heightCm` (drives existing BMR/TDEE/target)
//    - 今日の体重 → today's `DayLog.weightKg` (via the existing quick-input sheet)
//    - マイジム   → existing `Gym` flow (`MyGymHomeView`)
//
//  It is available to guests and signed-in users alike — it never reads the
//  auth state and never gates anything. No login is required, nothing is
//  synced, and no tokens/credentials are involved.
//

import SwiftUI
import SwiftData

struct ProfileGymSetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\UserProfile.updatedAt, order: .reverse)])
    private var profiles: [UserProfile]

    // Today's logs only, so we can read/record today's weight without a second
    // SwiftData read. Mirrors the `recentLogs` window pattern in SettingsView.
    @Query private var todayLogs: [DayLog]

    @Query(sort: [SortDescriptor(\Gym.updatedAt, order: .reverse)])
    private var gyms: [Gym]

    @State private var showWeightSheet = false
    @State private var weightDayLog: DayLog?

    init() {
        let today = DateUtils.startOfDay(Date())
        self._todayLogs = Query(
            filter: #Predicate<DayLog> { $0.date == today }
        )
    }

    // MARK: - Derived

    private var resolvedProfile: UserProfile? { profiles.first }
    private var activeGym: Gym? { gyms.first(where: { $0.isActive }) ?? gyms.first }
    private var todayWeight: Double? { todayLogs.first(where: { $0.weightKg != nil })?.weightKg }

    private var status: ProfileGymSetupStatus {
        ProfileGymSetupStatus(
            heightCm: resolvedProfile?.heightCm,
            todayWeightKg: todayWeight,
            hasGym: !gyms.isEmpty
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.surface.ignoresSafeArea()

                if let profile = resolvedProfile {
                    content(profile: profile)
                } else {
                    ProgressView("読み込み中…")
                        .task { _ = UserProfileStore.fetchOrCreate(modelContext: modelContext) }
                }
            }
            .navigationTitle("プロフィールとジムの設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .sheet(isPresented: $showWeightSheet) {
                if let weightDayLog {
                    DayLogQuickInputSheet(field: .weight, dayLog: weightDayLog)
                }
            }
        }
    }

    @ViewBuilder
    private func content(profile profileObject: UserProfile) -> some View {
        @Bindable var profile = profileObject
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                header
                heightCard(profile: $profile)
                weightCard
                gymCard
                localFirstCard
            }
            .padding(.horizontal, AppTheme.Spacing.l)
            .padding(.top, AppTheme.Spacing.l)
            .padding(.bottom, AppTheme.Spacing.xl)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            HStack(spacing: AppTheme.Spacing.s) {
                Text("セットアップ")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                PulseStatusBadge(
                    "\(status.completedCount)/\(status.totalCount) 完了",
                    kind: status.isComplete ? .success : .info
                )
            }
            Text("身長・体重・マイジムを設定すると、目標カロリーやワークアウトの提案に反映されます。設定はこの端末内に保存されます。")
                .font(.footnote)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Height

    private func heightCard(profile: Bindable<UserProfile>) -> some View {
        PulseCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                rowHeader(icon: "ruler", title: "身長", done: status.heightSet)
                HStack(alignment: .center) {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text("\(profile.wrappedValue.heightCm)")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(AppTheme.textPrimary)
                        Text("cm")
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    Spacer()
                    Stepper("", value: profile.heightCm, in: 120...220, step: 1)
                        .labelsHidden()
                        .accessibilityLabel("身長 \(profile.wrappedValue.heightCm) センチ")
                }
                Text("身長は基礎代謝（BMR）や目標摂取カロリーの計算に使われます。")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Weight (today's DayLog)

    private var weightCard: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                rowHeader(icon: "scalemass", title: "今日の体重", done: status.weightRecorded)
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    if let todayWeight {
                        Text(formatWeight(todayWeight))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(AppTheme.textPrimary)
                        Text("kg")
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                    } else {
                        Text("未記録")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                Button(todayWeight == nil ? "今日の体重を記録" : "今日の体重を更新") {
                    weightDayLog = DayLogStore.fetchOrCreateToday(modelContext: modelContext)
                    showWeightSheet = true
                }
                .buttonStyle(PulseSecondaryButtonStyle())
                Text("体重は今日の記録として保存され、目標との差分や推移の計算に使われます。")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Gym

    private var gymCard: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                rowHeader(icon: "dumbbell", title: "マイジム", done: status.gymRegistered)
                if let activeGym {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activeGym.name)
                            .font(.headline)
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                        Text("アクティブなジム")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                } else {
                    Text("まだジムが登録されていません。")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                NavigationLink {
                    MyGymHomeView()
                } label: {
                    HStack {
                        Text(activeGym == nil ? "マイジムを設定" : "マイジムを管理")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                .buttonStyle(PulseSecondaryButtonStyle())
                Text("普段使うジムと利用できるマシンを登録すると、ワークアウトの提案に反映されます。外部サービスとの連携は行いません。")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Local-first note

    private var localFirstCard: some View {
        PulseCard {
            HStack(alignment: .top, spacing: AppTheme.Spacing.m) {
                Image(systemName: "iphone")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("データはこの端末内に保存されます。")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text("ログインの有無に関わらず設定でき、同期・バックアップは行われません。")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Helpers

    private func rowHeader(icon: String, title: String, done: Bool) -> some View {
        HStack(spacing: AppTheme.Spacing.s) {
            PulseSectionHeader(title, icon: icon)
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.success)
                    .accessibilityLabel("設定済み")
            }
        }
    }

    private func formatWeight(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }
}

#if DEBUG
#Preview("Profile & gym setup") {
    ProfileGymSetupView()
        .modelContainer(for: [UserProfile.self, DayLog.self, Gym.self, GymMachine.self], inMemory: true)
}
#endif
