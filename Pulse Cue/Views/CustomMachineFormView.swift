//
//  CustomMachineFormView.swift
//  Pulse Cue
//
//  One sheet used for both creating and editing a custom machine.
//  Presented from the machine-selection screen so custom equipment is
//  managed in the same place as the bundled catalog rather than in a
//  disconnected screen hierarchy.
//
//  Nothing persists while typing: the draft lives in
//  `CustomMachineFormViewModel` and only the explicit save action writes.
//

import SwiftUI
import SwiftData

struct CustomMachineFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel: CustomMachineFormViewModel
    @FocusState private var nameFieldFocused: Bool

    /// - Parameter machine: `nil` creates a new machine; non-nil edits it.
    init(gym: Gym, editing machine: CustomMachine? = nil) {
        _viewModel = StateObject(
            wrappedValue: CustomMachineFormViewModel(gym: gym, editing: machine)
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                bodyPartSection
                equipmentTypeSection
                notesSection
                if case .error(let message) = viewModel.state {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(viewModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(viewModel.saveButtonTitle) {
                        nameFieldFocused = false
                        viewModel.save(modelContext: modelContext)
                    }
                    .fontWeight(.semibold)
                    .disabled(!viewModel.canSave)
                }
            }
            .onChange(of: viewModel.state) { _, newValue in
                if newValue == .saved { dismiss() }
            }
        }
    }

    // MARK: - Sections

    private var nameSection: some View {
        Section {
            TextField("例: 旧型レッグプレス", text: $viewModel.displayName)
                .focused($nameFieldFocused)
                .submitLabel(.done)
                .onChange(of: viewModel.displayName) { _, _ in viewModel.nameChanged() }
                .accessibilityLabel("マシン名")
            if let error = viewModel.nameError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("エラー: \(error)")
            }
        } header: {
            Text("マシン名")
        } footer: {
            Text("このジムにしかない器具や、カタログにない名前で登録できます。")
        }
    }

    private var bodyPartSection: some View {
        Section {
            // Wrapping chip rows rather than a horizontal scroll so no
            // option can hide off-screen at large Dynamic Type sizes.
            ForEach(chipRows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row) { part in
                        bodyPartChip(part)
                    }
                    Spacer(minLength: 0)
                }
            }
            if let error = viewModel.bodyPartsError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("鍛える部位（1つ以上）")
        }
    }

    private var equipmentTypeSection: some View {
        Section {
            Picker("種別", selection: $viewModel.equipmentType) {
                Text("未設定").tag(EquipmentType?.none)
                ForEach(EquipmentType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(EquipmentType?.some(type))
                }
            }
            .accessibilityLabel("器具の種別")
        } header: {
            Text("種別（任意）")
        }
    }

    private var notesSection: some View {
        Section {
            TextField("例: 2階の窓側", text: $viewModel.notes, axis: .vertical)
                .lineLimit(1...4)
                .accessibilityLabel("メモ")
        } header: {
            Text("メモ（任意）")
        }
    }

    // MARK: - Chips

    private func bodyPartChip(_ part: BodyPart) -> some View {
        let isOn = viewModel.isSelected(part)
        return Button {
            viewModel.toggleBodyPart(part)
        } label: {
            Text(chipLabel(for: part))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(
                        isOn ? AnyShapeStyle(AppTheme.accentFilled)
                             : AnyShapeStyle(Color.primary.opacity(0.06))
                    )
                )
                .foregroundStyle(isOn ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chipLabel(for: part))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    /// Three chips per row keeps every option reachable without a
    /// horizontal scroll, including at accessibility text sizes.
    private var chipRows: [[BodyPart]] {
        stride(from: 0, to: viewModel.bodyPartChoices.count, by: 3).map { start in
            Array(viewModel.bodyPartChoices[start..<min(start + 3, viewModel.bodyPartChoices.count)])
        }
    }

    private func chipLabel(for part: BodyPart) -> String {
        // Same display-only relabel the catalog screens use.
        part == .fullBody ? "有酸素" : part.displayName
    }
}
