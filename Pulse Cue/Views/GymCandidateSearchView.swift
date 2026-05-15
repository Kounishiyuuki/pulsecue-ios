//
//  GymCandidateSearchView.swift
//  Pulse Cue
//
//  Root screen of the "+ ジムを追加" flow. Hosts the location-based
//  nearby entry row, the MapKit text-based search inputs, and the
//  manual-entry fallback. Picking a candidate pushes
//  `GymRegistrationView` with pre-filled name and optional URL.
//

import SwiftUI

struct GymCandidateSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @StateObject private var viewModel: GymCandidateSearchViewModel
    let onSaved: (UUID) -> Void

    init(
        service: GymCandidateSearchService = MapKitGymCandidateSearchService(),
        onSaved: @escaping (UUID) -> Void
    ) {
        _viewModel = StateObject(wrappedValue: GymCandidateSearchViewModel(service: service))
        self.onSaved = onSaved
    }

    var body: some View {
        ZStack {
            MyGymStyle.backgroundLayer(for: colorScheme)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    nearbyCard
                    searchCard
                    stateCard
                    fallbackCard
                    privacyCard
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
        }
        .navigationTitle("ジムを検索")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("キャンセル") { dismiss() }
            }
        }
    }

    // MARK: - Cards

    private var nearbyCard: some View {
        NavigationLink {
            NearbyGymCandidateView(onSaved: onSaved)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "location.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(MyGymStyle.accentGradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text("現在地から近くのジムを探す")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("位置情報を使って近くのジムを表示します")
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

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            MyGymStyle.sectionHeader(icon: "magnifyingglass", title: "ジム名で検索")

            TextField("ジムブランド・店名 (例: エニタイムフィットネス)", text: $viewModel.brand)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            TextField("店舗・場所 (例: 金沢駅西)", text: $viewModel.branch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            Button {
                viewModel.search()
            } label: {
                if viewModel.state == .searching {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("検索", systemImage: "magnifyingglass")
                }
            }
            .buttonStyle(MyGymPrimaryButtonStyle(isEnabled: viewModel.canSearch))
            .disabled(!viewModel.canSearch)
        }
        .myGymCard()
    }

    @ViewBuilder
    private var stateCard: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()
        case .searching:
            HStack(spacing: 10) {
                ProgressView()
                Text("検索中…")
                    .foregroundStyle(.secondary)
            }
            .myGymCard()
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
                "該当する候補が見つかりませんでした。下の「手動で入力する」から登録してください。",
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
            Text("検索クエリは Apple のマップ検索に送信されます。位置情報は使用しません。")
                .font(.footnote)
        }
        .foregroundStyle(.secondary)
        .myGymCard(padding: 14)
    }
}
