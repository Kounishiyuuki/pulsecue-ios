//
//  GymRegistrationView.swift
//  Pulse Cue
//
//  Form for registering a new gym. Two fields (name + optional
//  public URL). Saving makes the new gym the active one so the
//  caller can immediately push into machine selection. Accepts
//  optional pre-fill values from the candidate search flow.
//

import SwiftUI
import SwiftData

struct GymRegistrationView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel = GymRegistrationViewModel()
    @State private var didApplyInitialValues = false

    let initialName: String
    let initialOfficialUrl: String
    let onSaved: (UUID) -> Void

    init(
        initialName: String = "",
        initialOfficialUrl: String = "",
        onSaved: @escaping (UUID) -> Void
    ) {
        self.initialName = initialName
        self.initialOfficialUrl = initialOfficialUrl
        self.onSaved = onSaved
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MyGymStyle.backgroundLayer(for: colorScheme)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    inputCard
                    if case .error(let message) = viewModel.state {
                        errorCard(message: message)
                    }
                    hintCard
                    Color.clear.frame(height: 96)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }

            saveBar
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .navigationTitle("ジムを登録")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("キャンセル") { dismiss() }
            }
        }
        .task {
            viewModel.configure(modelContext: modelContext)
            if !didApplyInitialValues {
                if viewModel.name.isEmpty { viewModel.name = initialName }
                if viewModel.officialUrl.isEmpty { viewModel.officialUrl = initialOfficialUrl }
                didApplyInitialValues = true
            }
        }
        .onChange(of: viewModel.state) { _, newValue in
            if case .saved(let gymId) = newValue {
                onSaved(gymId)
                dismiss()
            }
        }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            MyGymStyle.sectionHeader(icon: "building.2.fill", title: "ジム情報")

            fieldLabel("ジム名", required: true)
            TextField("例: フィットネスジム パルス", text: $viewModel.name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            fieldLabel("公式URL", required: false)
            TextField("https://", text: $viewModel.officialUrl)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                Text("公式URLは後でマシン情報の確認に使える項目です。空欄で保存できます。")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
        .myGymCard()
    }

    private func fieldLabel(_ text: String, required: Bool) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            if required {
                Text("*")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.red)
            } else {
                Text("(任意)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var hintCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            MyGymStyle.sectionHeader(icon: "lightbulb", title: "ヒント")
            Text("登録後、このジムにあるマシンを選んでワークアウトを生成できます。あとから内容はいつでも編集できます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .myGymCard()
    }

    private func errorCard(message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .myGymCard()
    }

    private var saveBar: some View {
        Button {
            viewModel.save()
        } label: {
            if viewModel.state == .saving {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                Label("保存する", systemImage: "tray.and.arrow.down.fill")
            }
        }
        .buttonStyle(MyGymPrimaryButtonStyle(isEnabled: viewModel.canSave))
        .disabled(!viewModel.canSave)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
                .padding(-6)
        )
    }
}
