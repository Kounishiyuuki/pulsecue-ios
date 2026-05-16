//
//  NearbyGymCandidateView.swift
//  Pulse Cue
//
//  Location-based gym candidate search. Permission is requested on
//  the user's first explicit tap into this screen, so they see one
//  cause-and-effect prompt. Reuses `GymCandidateRow` so result rows
//  look identical to the text-search flow. The manual-entry fallback
//  link is always visible in every state.
//

import SwiftUI
import UIKit

struct NearbyGymCandidateView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @StateObject private var viewModel: NearbyGymCandidateViewModel
    let onSaved: (UUID) -> Void

    init(
        locationProvider: LocationProvider? = nil,
        searchService: NearbyGymCandidateSearchService = MapKitNearbyGymCandidateSearchService(),
        onSaved: @escaping (UUID) -> Void
    ) {
        let provider: LocationProvider = locationProvider ?? CoreLocationProvider()
        _viewModel = StateObject(
            wrappedValue: NearbyGymCandidateViewModel(
                locationProvider: provider,
                searchService: searchService
            )
        )
        self.onSaved = onSaved
    }

    var body: some View {
        ZStack {
            MyGymStyle.backgroundLayer(for: colorScheme)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    actionCard
                    stateCard
                    fallbackCard
                    privacyCard
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
        }
        .navigationTitle("現在地から探す")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if viewModel.state == .idle {
                await viewModel.searchNearby()
            }
        }
    }

    // MARK: - Cards

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            MyGymStyle.sectionHeader(icon: "location.circle.fill", title: "近くのジム")
            Text("現在地周辺のジムを検索します。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                Task { await viewModel.searchNearby() }
            } label: {
                if viewModel.state == .locating || viewModel.state == .searching {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("もう一度近くを検索", systemImage: "location.circle.fill")
                }
            }
            .buttonStyle(MyGymPrimaryButtonStyle())
            .disabled(viewModel.state == .locating || viewModel.state == .searching)
        }
        .myGymCard()
    }

    @ViewBuilder
    private var stateCard: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()
        case .permissionDenied:
            VStack(alignment: .leading, spacing: 10) {
                Label("位置情報の許可が必要です", systemImage: "location.slash.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("設定アプリで PulseCue の位置情報を許可してください。許可しなくても下の「手動で入力する」で登録できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    openSettings()
                } label: {
                    Label("設定アプリを開く", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .myGymCard()
        case .locating:
            stateMessage("位置情報を取得中…")
        case .searching:
            stateMessage("近くのジムを検索中…")
        case .loaded(let candidates):
            VStack(alignment: .leading, spacing: 12) {
                MyGymStyle.sectionHeader(icon: "list.bullet", title: "候補")
                ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                    if index > 0 { Divider().opacity(0.35) }
                    NavigationLink {
                        GymRegistrationView(
                            initialName: candidate.name,
                            initialOfficialUrl: candidate.officialUrlString ?? "",
                            onSaved: onSaved
                        )
                    } label: {
                        GymCandidateRow(candidate: candidate) {}
                    }
                    .buttonStyle(.plain)
                }
            }
            .myGymCard()
        case .empty:
            Label(
                "近くのジムが見つかりませんでした。下の「手動で入力する」から登録してください。",
                systemImage: "magnifyingglass.circle"
            )
            .foregroundStyle(.secondary)
            .myGymCard()
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .myGymCard()
        }
    }

    private func stateMessage(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .myGymCard()
    }

    private var fallbackCard: some View {
        NavigationLink {
            GymRegistrationView(onSaved: onSaved)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("見つからない場合は手動で入力する")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("ジム名と公式URLを直接入力します")
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

    private var privacyCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.caption2)
            Text("現在地は近くのジム検索にのみ使用します。外部に送信しません。")
                .font(.footnote)
        }
        .foregroundStyle(.secondary)
        .myGymCard(padding: 14)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
