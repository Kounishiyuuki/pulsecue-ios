//
//  GymRegistrationView.swift
//  Pulse Cue
//
//  Form for registering a new gym. Two fields (name + optional
//  public URL). Saving makes the new gym the active one so the
//  caller can immediately push into machine selection.
//

import SwiftUI
import SwiftData

struct GymRegistrationView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel = GymRegistrationViewModel()

    /// Called with the newly created gym id after a successful save
    /// so the caller (the hub screen) can decide whether to dismiss
    /// itself or push deeper into the flow.
    let onSaved: (UUID) -> Void

    var body: some View {
        Form {
            Section("ジム情報") {
                TextField("ジム名", text: $viewModel.name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("公式URL(任意)", text: $viewModel.officialUrl)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }

            if case .error(let message) = viewModel.state {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Text("公式URLは後でジムごとの機械リスト取り込みに使う予定です。今は任意で構いません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("ジムを登録")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("キャンセル") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { viewModel.save() }
                    .disabled(!viewModel.canSave)
            }
        }
        .task { viewModel.configure(modelContext: modelContext) }
        .onChange(of: viewModel.state) { _, newValue in
            if case .saved(let gymId) = newValue {
                onSaved(gymId)
                dismiss()
            }
        }
    }
}
