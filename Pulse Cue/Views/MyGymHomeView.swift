//
//  MyGymHomeView.swift
//  Pulse Cue
//
//  Entry point for the manual gym workout flow. Reached from
//  Settings →「マイジム」. Shows the active gym hero with its
//  machine count + primary "generate workout" CTA, the list of
//  registered gyms, and entry points for adding more. Offline-first
//  — no server calls.
//

import SwiftUI
import SwiftData

struct MyGymHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var viewModel = MyGymHomeViewModel()
    @State private var showRegistration = false
    /// Holds the gym the user has asked to delete, while the
    /// confirmation alert is on screen. `nil` when no alert is active.
    @State private var pendingDeletion: Gym?

    var body: some View {
        ZStack(alignment: .top) {
            MyGymStyle.backgroundLayer(for: colorScheme)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    titleBlock
                    if viewModel.gyms.isEmpty {
                        emptyStateCard
                    } else if let active = viewModel.activeGym {
                        activeGymCard(active)
                        activeGymActionsCard(active)
                        if viewModel.gyms.count > 1 {
                            otherGymsCard
                        } else {
                            registerAnotherCard
                        }
                    } else {
                        // Gyms exist but none is active (e.g. the
                        // user deleted the previously-active gym).
                        // Surface every registered gym as a tappable
                        // row so the active invariant can be repaired
                        // without forcing a re-register.
                        selectActiveGymCard
                        registerAnotherCard
                    }
                    Color.clear.frame(height: 28)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
        }
        .navigationTitle("マイジム")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showRegistration = true
                } label: {
                    Label("ジムを追加", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showRegistration, onDismiss: { viewModel.reload() }) {
            NavigationStack {
                GymCandidateSearchView { _ in
                    showRegistration = false
                }
            }
        }
        .task { viewModel.configure(modelContext: modelContext) }
        .onAppear { viewModel.reload() }
        .alert(
            "ジムを削除しますか？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { gym in
            Button("キャンセル", role: .cancel) { pendingDeletion = nil }
            Button("削除", role: .destructive) {
                viewModel.delete(gym)
                pendingDeletion = nil
            }
        } message: { _ in
            Text("このジムに登録したマシン情報も削除されます。")
        }
    }

    // MARK: - Title

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("マイジム")
                .font(.largeTitle.weight(.bold))
            Text("ワークアウト場所とマシンのアクセスを管理します。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Empty state

    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "building.2.crop.circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(MyGymStyle.accentGradient)
                Text("ジムを登録するとメニューを自動生成できます")
                    .font(.headline)
            }
            Text("普段トレーニングしているジムを登録すると、利用できるマシンに合わせてワークアウトを組み立てます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                showRegistration = true
            } label: {
                Label("ジムを登録する", systemImage: "plus.circle.fill")
            }
            .buttonStyle(MyGymPrimaryButtonStyle())
            .padding(.top, 6)
        }
        .myGymCard()
    }

    // MARK: - Active gym hero

    private func activeGymCard(_ gym: Gym) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                activeBadge
                Spacer()
                Menu {
                    Button(role: .destructive) {
                        pendingDeletion = gym
                    } label: {
                        Label("このジムを削除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("ジムの操作")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(gym.name)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                if let host = displayHost(for: gym.officialUrl) {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.caption2)
                        Text(host)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            machineStatRow(gym)
            NavigationLink {
                TargetBodyPartSelectionView(gym: gym)
            } label: {
                Label("選択中のマシンでメニューを生成", systemImage: "sparkles")
            }
            .buttonStyle(MyGymPrimaryButtonStyle(isEnabled: viewModel.machineCount(for: gym) > 0))
            .disabled(viewModel.machineCount(for: gym) == 0)
        }
        .myGymCard()
    }

    private var activeBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "star.fill")
                .font(.caption2)
            Text("アクティブ")
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(MyGymStyle.accentGradient)
        )
    }

    private func machineStatRow(_ gym: Gym) -> some View {
        let count = viewModel.machineCount(for: gym)
        return HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(count)")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle(MyGymStyle.accentGradient)
                Text("利用可能なマシン")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if count == 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("まずはマシンを選択")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("「マシンを選択」 から登録")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    // MARK: - Active gym secondary actions

    private func activeGymActionsCard(_ gym: Gym) -> some View {
        VStack(spacing: 0) {
            NavigationLink {
                ManualMachineSelectionView(gym: gym)
            } label: {
                actionRow(
                    icon: "dumbbell.fill",
                    title: "マシンを選択",
                    subtitle: "このジムで使えるマシンを更新"
                )
            }
            Divider().opacity(0.4)
            Button {
                showRegistration = true
            } label: {
                actionRow(
                    icon: "plus.circle",
                    title: "別のジムを追加",
                    subtitle: "出張先のジムや別店舗を登録"
                )
            }
            .buttonStyle(.plain)
        }
        .myGymCard(padding: 14)
    }

    // MARK: - Other gyms

    private var otherGymsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                MyGymStyle.sectionHeader(icon: "building.2", title: "登録済みのジム")
                Button {
                    showRegistration = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                            .font(.caption.weight(.bold))
                        Text("ジムを登録する")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(MyGymStyle.accentSolid)
                }
                .buttonStyle(.plain)
            }
            VStack(spacing: 0) {
                ForEach(Array(viewModel.gyms.filter { !$0.isActive }.enumerated()), id: \.element.id) { index, gym in
                    if index > 0 { Divider().opacity(0.4) }
                    Button {
                        viewModel.setActive(gym)
                    } label: {
                        otherGymRow(gym)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            pendingDeletion = gym
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .myGymCard()
    }

    /// Tappable list of every registered gym, used when no gym is
    /// currently active. Tapping a row promotes that gym to active
    /// via `GymRepository.setActive`, which automatically demotes
    /// any other rows — the single-active invariant is preserved.
    private var selectActiveGymCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            MyGymStyle.sectionHeader(icon: "checkmark.circle", title: "ジムを選択")
            Text("今日使うジムをタップしてアクティブにしてください。")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(viewModel.gyms.enumerated()), id: \.element.id) { index, gym in
                    if index > 0 { Divider().opacity(0.4) }
                    Button {
                        viewModel.setActive(gym)
                    } label: {
                        otherGymRow(gym)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            pendingDeletion = gym
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .myGymCard()
    }

    /// Compact card shown when only the active gym exists, so the
    /// 「ジムを登録する」 affordance is always visible.
    private var registerAnotherCard: some View {
        Button {
            showRegistration = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(MyGymStyle.accentGradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text("別のジムを追加")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("出張先のジムや家トレ用の設定もここで管理")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .myGymCard()
    }

    // MARK: - Rows

    private func actionRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(MyGymStyle.accentGradient)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
    }

    private func otherGymRow(_ gym: Gym) -> some View {
        let count = viewModel.machineCount(for: gym)
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                Image(systemName: "building.2.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(gym.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(count) 台のマシンが同期済み")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func displayHost(for urlString: String?) -> String? {
        guard let urlString,
              !urlString.isEmpty,
              let url = URL(string: urlString),
              let host = url.host?.lowercased()
        else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
