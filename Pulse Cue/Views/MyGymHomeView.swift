//
//  MyGymHomeView.swift
//  Pulse Cue
//
//  Entry point for the manual gym workout flow. Reached from
//  Settings →「マイジム」. Shows the active gym hero with its
//  machine count, the list of registered gyms, and CTAs into machine
//  selection / plan generation. Offline-first — no server calls.
//

import SwiftUI
import SwiftData

struct MyGymHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var viewModel = MyGymHomeViewModel()
    @State private var showRegistration = false

    var body: some View {
        ZStack(alignment: .top) {
            MyGymStyle.backgroundLayer(for: colorScheme)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if viewModel.gyms.isEmpty {
                        emptyStateCard
                    } else {
                        if let active = viewModel.activeGym {
                            activeGymCard(active)
                            activeGymActionsCard(active)
                        }
                        if viewModel.gyms.count > 1 {
                            otherGymsCard
                        }
                    }
                    infoCard
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
        }
        .navigationTitle("マイジム")
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
    }

    // MARK: - Cards

    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            MyGymStyle.sectionHeader(icon: "building.2.crop.circle", title: "マイジム")
            Text("ジムを登録するとメニューを自動生成できます")
                .font(.headline)
            Text("普段トレーニングしているジムを登録すると、利用できるマシンに合わせてワークアウトを組み立てます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                showRegistration = true
            } label: {
                Label("ジムを登録する", systemImage: "plus.circle.fill")
            }
            .buttonStyle(MyGymPrimaryButtonStyle())
            .padding(.top, 4)
        }
        .myGymCard()
    }

    private func activeGymCard(_ gym: Gym) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(MyGymStyle.accentGradient)
                Text("アクティブなジム")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(gym.name)
                    .font(.title2.weight(.bold))
                if let url = gym.officialUrl, !url.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.caption2)
                        Text(displayHost(for: url))
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(viewModel.machineCount(for: gym))")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(MyGymStyle.accentGradient)
                    Text("利用可能なマシン")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .myGymCard()
    }

    private func activeGymActionsCard(_ gym: Gym) -> some View {
        VStack(spacing: 12) {
            NavigationLink {
                ManualMachineSelectionView(gym: gym)
            } label: {
                actionRow(
                    icon: "dumbbell.fill",
                    title: "マシンを選択",
                    subtitle: "このジムで利用できるマシンを更新"
                )
            }
            Divider().opacity(0.4)
            NavigationLink {
                TargetBodyPartSelectionView(gym: gym)
            } label: {
                actionRow(
                    icon: "sparkles",
                    title: "ワークアウトを生成",
                    subtitle: "部位を選んでメニューを自動作成"
                )
            }
        }
        .myGymCard()
    }

    private var otherGymsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            MyGymStyle.sectionHeader(icon: "building.2", title: "登録済みのジム")
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
                        viewModel.delete(gym)
                    } label: {
                        Label("削除", systemImage: "trash")
                    }
                }
            }
        }
        .myGymCard()
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            MyGymStyle.sectionHeader(icon: "info.circle", title: "ヒント")
            Text("生成されたワークアウトはルーティン一覧に保存され、ランナーからそのまま開始できます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
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
    }

    private func otherGymRow(_ gym: Gym) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "building.2")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(gym.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(viewModel.machineCount(for: gym)) 台のマシン")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("切り替え")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(Color.secondary.opacity(0.12))
                )
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Helpers

    private func displayHost(for urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else {
            return urlString
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
