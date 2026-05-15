//
//  ManualMachineSelectionView.swift
//  Pulse Cue
//
//  Lets the user mark which catalog machines exist at the given gym.
//  Each toggle flips local state; tapping「保存」pushes the diff into
//  SwiftData via `GymRepository.setMachines`.
//

import SwiftUI
import SwiftData

struct ManualMachineSelectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel: ManualMachineSelectionViewModel

    init(gym: Gym) {
        _viewModel = StateObject(wrappedValue: ManualMachineSelectionViewModel(gym: gym))
    }

    var body: some View {
        List {
            Section {
                Text("「\(viewModel.gym.name)」で使えるマシンにチェックを入れてください。あとからいつでも変更できます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("カタログ") {
                ForEach(viewModel.catalog) { entry in
                    machineToggle(entry)
                }
            }

            if case .error(let message) = viewModel.state {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("マシンを選択")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { viewModel.save() }
                    .disabled(viewModel.state == .saving)
            }
        }
        .task { viewModel.configure(modelContext: modelContext) }
        .onChange(of: viewModel.state) { _, newValue in
            if newValue == .saved { dismiss() }
        }
    }

    private func machineToggle(_ entry: MachineCatalogEntry) -> some View {
        Button {
            viewModel.toggle(entry)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: viewModel.isSelected(entry) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(viewModel.isSelected(entry) ? Color.accentColor : Color.secondary)
                    .imageScale(.large)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .foregroundStyle(.primary)
                    Text(bodyPartList(for: entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func bodyPartList(for entry: MachineCatalogEntry) -> String {
        BodyPart.allCases
            .filter { entry.bodyParts.contains($0) }
            .map(\.displayName)
            .joined(separator: " / ")
    }
}
