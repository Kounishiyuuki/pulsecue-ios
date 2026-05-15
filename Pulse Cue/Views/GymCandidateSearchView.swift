//
//  GymCandidateSearchView.swift
//  Pulse Cue
//
//  Root screen of the "+ ジムを追加" flow. Wraps a `MKLocalSearch`-
//  backed candidate search around two text inputs (brand and branch),
//  with the unchanged manual-entry path always one tap away. Selecting
//  a candidate pushes `GymRegistrationView` with pre-filled name and
//  optional URL; tapping「見つからない…」does the same with empty
//  fields, preserving the original PR #20 flow.
//

import SwiftUI

struct GymCandidateSearchView: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel: GymCandidateSearchViewModel
    /// Called when the user finishes the registration flow that this
    /// screen started. Bubbles the new `Gym.id` up to the caller so
    /// the hub screen can dismiss its sheet + reload.
    let onSaved: (UUID) -> Void

    /// Production callers use the default initializer (real MapKit).
    /// Previews and tests inject a fake service.
    init(
        service: GymCandidateSearchService = MapKitGymCandidateSearchService(),
        onSaved: @escaping (UUID) -> Void
    ) {
        _viewModel = StateObject(wrappedValue: GymCandidateSearchViewModel(service: service))
        self.onSaved = onSaved
    }

    var body: some View {
        Form {
            inputSection
            stateSection
            fallbackSection
            privacySection
        }
        .navigationTitle("ジムを検索")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("キャンセル") { dismiss() }
            }
        }
    }

    // MARK: - Sections

    private var inputSection: some View {
        Section("ジムを検索") {
            TextField("ジムブランド・店名(例: エニタイムフィットネス)", text: $viewModel.brand)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("店舗・場所(例: 金沢駅西)", text: $viewModel.branch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                viewModel.search()
            } label: {
                if viewModel.state == .searching {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("検索", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(!viewModel.canSearch)
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var stateSection: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()
        case .searching:
            Section {
                HStack {
                    ProgressView()
                    Text("検索中…")
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
                            // The trailing「選択」button is decorative
                            // here; tapping the NavigationLink's row
                            // is what actually navigates. Kept so the
                            // row works the same when extracted for
                            // previews / tests.
                        }
                    }
                }
            }
        case .empty:
            Section {
                Label(
                    "該当する候補が見つかりませんでした。下の「手動で入力する」から登録してください。",
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
                GymRegistrationView(
                    initialName: "",
                    initialOfficialUrl: "",
                    onSaved: onSaved
                )
            } label: {
                Label("見つからない場合は手動で入力する", systemImage: "square.and.pencil")
            }
        }
    }

    private var privacySection: some View {
        Section {
            Text("検索クエリは Apple のマップ検索に送信されます。位置情報は使用しません。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
