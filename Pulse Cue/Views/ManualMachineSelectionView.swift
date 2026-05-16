//
//  ManualMachineSelectionView.swift
//  Pulse Cue
//
//  Lets the user mark which catalog machines exist at the given gym.
//  Each toggle flips local state; tapping「保存」pushes the diff into
//  SwiftData via `GymRepository.setMachines`. Catalog rows are
//  grouped by their primary body part so the user can scan by
//  workout target rather than alphabetically.
//

import SwiftUI
import SwiftData

struct ManualMachineSelectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel: ManualMachineSelectionViewModel

    init(gym: Gym) {
        _viewModel = StateObject(wrappedValue: ManualMachineSelectionViewModel(gym: gym))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MyGymStyle.backgroundLayer(for: colorScheme)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerCard

                    ForEach(BodyPart.allCases) { part in
                        let entries = entries(for: part)
                        if !entries.isEmpty {
                            bodyPartCard(part: part, entries: entries)
                        }
                    }

                    if case .error(let message) = viewModel.state {
                        errorCard(message: message)
                    }
                    // Spacer so the sticky save bar doesn't cover the
                    // last card.
                    Color.clear.frame(height: 88)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }

            saveBar
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .navigationTitle("マシンを選択")
        .navigationBarTitleDisplayMode(.inline)
        .task { viewModel.configure(modelContext: modelContext) }
        .onChange(of: viewModel.state) { _, newValue in
            if newValue == .saved { dismiss() }
        }
    }

    // MARK: - Cards

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            MyGymStyle.sectionHeader(icon: "building.2.fill", title: viewModel.gym.name)
            Text("このジムで使えるマシンにチェックを入れてください。あとからいつでも変更できます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .myGymCard()
    }

    private func bodyPartCard(part: BodyPart, entries: [MachineCatalogEntry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                MyGymStyle.sectionHeader(icon: bodyPartIcon(part), title: part.displayName)
                Text(selectedCountText(for: entries))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider().opacity(0.35) }
                machineToggle(entry)
            }
        }
        .myGymCard()
    }

    private func errorCard(message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .myGymCard()
    }

    // MARK: - Rows + helpers

    private func machineToggle(_ entry: MachineCatalogEntry) -> some View {
        Button {
            viewModel.toggle(entry)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            viewModel.isSelected(entry) ? Color.clear : Color.secondary.opacity(0.4),
                            lineWidth: 1.5
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(viewModel.isSelected(entry) ? AnyShapeStyle(MyGymStyle.accentGradient) : AnyShapeStyle(Color.clear))
                        )
                        .frame(width: 22, height: 22)
                    if viewModel.isSelected(entry) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(secondaryBodyParts(for: entry))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private var saveBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("選択済み")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(viewModel.selectedIds.count) 台")
                    .font(.headline.weight(.bold))
            }
            Spacer()
            Button {
                viewModel.save()
            } label: {
                if viewModel.state == .saving {
                    ProgressView()
                        .frame(maxWidth: 140)
                } else {
                    Label("プランを保存", systemImage: "tray.and.arrow.down.fill")
                        .frame(maxWidth: 160)
                }
            }
            .buttonStyle(MyGymPrimaryButtonStyle())
            .disabled(viewModel.state == .saving)
            .frame(maxWidth: 200)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
        )
    }

    // MARK: - Catalog helpers

    private func entries(for part: BodyPart) -> [MachineCatalogEntry] {
        MachineCatalog.all.filter { $0.bodyParts.contains(part) }
    }

    private func selectedCountText(for entries: [MachineCatalogEntry]) -> String {
        let count = entries.filter { viewModel.selectedIds.contains($0.id) }.count
        return "\(count) / \(entries.count)"
    }

    private func secondaryBodyParts(for entry: MachineCatalogEntry) -> String {
        BodyPart.allCases
            .filter { entry.bodyParts.contains($0) }
            .map(\.displayName)
            .joined(separator: " / ")
    }

    private func bodyPartIcon(_ part: BodyPart) -> String {
        switch part {
        case .chest: return "figure.strengthtraining.traditional"
        case .back: return "figure.walk"
        case .legs: return "figure.run"
        case .shoulders: return "figure.archery"
        case .arms: return "dumbbell.fill"
        case .core: return "figure.core.training"
        case .fullBody: return "figure.mixed.cardio"
        }
    }
}
