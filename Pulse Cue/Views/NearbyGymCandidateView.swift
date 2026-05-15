//
//  NearbyGymCandidateView.swift
//  Pulse Cue
//
//  Location-based gym candidate search screen. Permission is requested
//  on the user's first explicit「現在地から探す」tap (the same tap
//  that leads here from `GymCandidateSearchView`), so the user sees
//  exactly one cause-and-effect prompt.
//
//  Reuses `GymCandidateRow` so the result rows look identical to the
//  text-search flow. The manual-entry fallback link is always visible
//  in every state.
//

import SwiftUI
import UIKit

struct NearbyGymCandidateView: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel: NearbyGymCandidateViewModel
    /// Bubbles the new `Gym.id` up through `GymCandidateSearchView` so
    /// the hub sheet can dismiss + reload.
    let onSaved: (UUID) -> Void

    /// Production callers use the default initializer (real CoreLocation
    /// + MapKit). Previews and tests inject fakes.
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
        Form {
            actionSection
            stateSection
            fallbackSection
            privacySection
        }
        .navigationTitle("現在地から探す")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Auto-fire the first search when the screen appears; this
            // is what the user expected by tapping into this screen.
            // Permission is still requested just-in-time inside the VM.
            if viewModel.state == .idle {
                await viewModel.searchNearby()
            }
        }
    }

    // MARK: - Sections

    private var actionSection: some View {
        Section {
            Button {
                Task { await viewModel.searchNearby() }
            } label: {
                if viewModel.state == .locating || viewModel.state == .searching {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("もう一度近くを検索", systemImage: "location.circle.fill")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.state == .locating || viewModel.state == .searching)
        }
    }

    @ViewBuilder
    private var stateSection: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()
        case .permissionDenied:
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("位置情報の許可が必要です", systemImage: "location.slash")
                        .font(.body.weight(.semibold))
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
                .padding(.vertical, 4)
            }
        case .locating:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("位置情報を取得中…")
                        .foregroundStyle(.secondary)
                }
            }
        case .searching:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("近くのジムを検索中…")
                        .foregroundStyle(.secondary)
                }
            }
        case .loaded(let candidates):
            Section("候補") {
                ForEach(candidates) { candidate in
                    NavigationLink {
                        GymRegistrationView(
                            initialName: candidate.name,
                            initialOfficialUrl: candidate.officialUrlString ?? "",
                            onSaved: onSaved
                        )
                    } label: {
                        GymCandidateRow(candidate: candidate) {
                            // Trailing「選択」button is decorative;
                            // the NavigationLink's row owns the
                            // actual navigation.
                        }
                    }
                }
            }
        case .empty:
            Section {
                Label(
                    "近くのジムが見つかりませんでした。検索範囲を広げる手段はまだありません。下の「手動で入力する」から登録してください。",
                    systemImage: "magnifyingglass.circle"
                )
                .foregroundStyle(.secondary)
            }
        case .error(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private var fallbackSection: some View {
        Section {
            NavigationLink {
                GymRegistrationView(onSaved: onSaved)
            } label: {
                Label("見つからない場合は手動で入力する", systemImage: "square.and.pencil")
            }
        }
    }

    private var privacySection: some View {
        Section {
            Text("現在地は近くのジム検索にのみ使用します。外部に送信しません。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
