//
//  MyGymHomeView.swift
//  Pulse Cue
//
//  Entry point for the manual gym workout flow. Reached from
//  Settings →「マイジム」. Shows the active gym + saved machines,
//  lets the user register additional gyms, switch the active one,
//  edit the machine selection, and generate a workout routine.
//
//  No server calls; everything here is offline-first and stored in
//  SwiftData.
//

import SwiftUI
import SwiftData

struct MyGymHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = MyGymHomeViewModel()
    @State private var showRegistration = false

    var body: some View {
        List {
            if viewModel.gyms.isEmpty {
                emptyStateSection
            } else {
                activeSection
                if viewModel.gyms.count > 1 {
                    otherGymsSection
                }
            }
            infoSection
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
        .task {
            viewModel.configure(modelContext: modelContext)
        }
        .onAppear { viewModel.reload() }
    }

    // MARK: - Sections

    private var emptyStateSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("ジムが登録されていません")
                    .font(.headline)
                Text("普段トレーニングしているジムを登録すると、利用できるマシンに合わせてワークアウトを生成できます。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    showRegistration = true
                } label: {
                    Label("ジムを登録する", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var activeSection: some View {
        if let active = viewModel.activeGym {
            Section("アクティブなジム") {
                gymRow(active, isActive: true)
                NavigationLink {
                    ManualMachineSelectionView(gym: active)
                } label: {
                    Label("マシンを選択", systemImage: "dumbbell")
                }
                NavigationLink {
                    TargetBodyPartSelectionView(gym: active)
                } label: {
                    Label("ワークアウトを生成", systemImage: "sparkles")
                }
            }
        }
    }

    private var otherGymsSection: some View {
        Section("その他のジム") {
            ForEach(viewModel.gyms.filter { !$0.isActive }) { gym in
                Button {
                    viewModel.setActive(gym)
                } label: {
                    gymRow(gym, isActive: false)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        viewModel.delete(gym)
                    } label: {
                        Label("削除", systemImage: "trash")
                    }
                }
            }
        }
    }

    private var infoSection: some View {
        Section {
            Text("生成されたワークアウトは既存のルーティン一覧に保存され、ランナーからそのまま開始できます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Row

    private func gymRow(_ gym: Gym, isActive: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "building.2")
                .foregroundStyle(isActive ? .green : .secondary)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text(gym.name)
                    .font(.body.weight(.semibold))
                let count = viewModel.machineCount(for: gym)
                Text(count > 0 ? "\(count) 台のマシン" : "マシン未登録")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isActive {
                Text("切り替え")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
