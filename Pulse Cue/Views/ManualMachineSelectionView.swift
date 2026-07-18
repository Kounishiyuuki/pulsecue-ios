//
//  ManualMachineSelectionView.swift
//  Pulse Cue
//
//  Lets the user mark which catalog machines exist at the given gym.
//  Each row toggles local state; tapping「選択を保存」pushes the diff into
//  SwiftData via `GymRepository.setMachines`. The list can be narrowed by
//  free-text search and body-part filters (reusing `MachineCatalogQuery`
//  via the view model) while the full selection is preserved regardless
//  of the active filter, so saving always writes every selected machine.
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
                VStack(alignment: .leading, spacing: 16) {
                    headerCard
                    filterCard
                    resultsSection

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

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            MyGymStyle.sectionHeader(icon: "building.2.fill", title: viewModel.gym.name)
            Text("このジムで使えるマシンにチェックを入れてください。あとからいつでも変更できます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .myGymCard()
    }

    // MARK: - Filters

    private var filterCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchField
            bodyPartChips
            Divider().opacity(0.35)
            selectedOnlyRow
            summaryRow
            if viewModel.hiddenSelectedCount > 0 {
                hiddenSelectedNote
            }
        }
        .myGymCard()
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("マシン名・タグで検索", text: $viewModel.searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("検索をクリア")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private var bodyPartChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.bodyPartFilters, id: \.self) { part in
                    chip(for: part)
                }
                if !viewModel.selectedBodyParts.isEmpty {
                    Button {
                        viewModel.selectedBodyParts.removeAll()
                    } label: {
                        Text("すべて")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("部位フィルターをすべて解除")
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func chip(for part: BodyPart) -> some View {
        let isOn = viewModel.selectedBodyParts.contains(part)
        return Button {
            viewModel.toggleBodyPart(part)
        } label: {
            Text(chipLabel(for: part))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(
                        isOn ? AnyShapeStyle(MyGymStyle.accentGradient)
                             : AnyShapeStyle(Color.primary.opacity(0.06))
                    )
                )
                .foregroundStyle(isOn ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func chipLabel(for part: BodyPart) -> String {
        // Catalog uses `.fullBody` for cardio-style machines (treadmill/
        // bike); surface that as 有酸素 here per the catalog screen without
        // touching the persisted `BodyPart` enum. Display-only relabel.
        part == .fullBody ? "有酸素" : part.displayName
    }

    private var selectedOnlyRow: some View {
        Toggle(isOn: $viewModel.showSelectedOnly) {
            Text("選択中のみ表示")
                .font(.subheadline.weight(.medium))
        }
        .toggleStyle(SwitchToggleStyle(tint: MyGymStyle.accentSolid))
        .disabled(!viewModel.hasSelection && !viewModel.showSelectedOnly)
    }

    private var summaryRow: some View {
        HStack {
            Text("該当 \(viewModel.visibleCount) 件")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(viewModel.hasSelection
                 ? "選択済み \(viewModel.selectedCount) 台"
                 : "まだ選択されていません")
                .font(.caption.weight(.semibold))
                .foregroundStyle(viewModel.hasSelection ? .primary : .secondary)
        }
    }

    private var hiddenSelectedNote: some View {
        Label(
            "選択済み \(viewModel.hiddenSelectedCount) 台は現在の絞り込みに含まれていません（保存対象です）。",
            systemImage: "info.circle"
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsSection: some View {
        if viewModel.visibleEntries.isEmpty {
            emptyStateCard
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(viewModel.visibleEntries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().opacity(0.35) }
                    machineToggle(entry)
                }
            }
            .myGymCard()
        }
    }

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
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(viewModel.isSelected(entry) ? .isSelected : [])
    }

    private var emptyStateCard: some View {
        VStack(spacing: 8) {
            Image(systemName: viewModel.showSelectedOnly ? "checklist" : "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(emptyTitle)
                .font(.subheadline.weight(.semibold))
            Text(emptyMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if viewModel.hasActiveFilters {
                Button("絞り込みを解除") { viewModel.clearFilters() }
                    .font(.caption.weight(.semibold))
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .myGymCard()
    }

    private var emptyTitle: String {
        if viewModel.showSelectedOnly {
            return "選択済みのマシンがありません"
        }
        return "一致するマシンがありません"
    }

    private var emptyMessage: String {
        if viewModel.showSelectedOnly {
            return viewModel.hasSelection
                ? "現在の絞り込みでは選択済みマシンが表示されません。"
                : "マシンを選ぶと、ここで一覧を確認できます。"
        }
        return "検索ワードや部位フィルターを変更してください。"
    }

    // MARK: - Error + save

    private func errorCard(message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .myGymCard()
    }

    private var saveBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("選択済み")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(viewModel.selectedCount) 台")
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
                    Label("選択を保存", systemImage: "tray.and.arrow.down.fill")
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

    // MARK: - Helpers

    private func secondaryBodyParts(for entry: MachineCatalogEntry) -> String {
        BodyPart.allCases
            .filter { entry.bodyParts.contains($0) }
            .map(\.displayName)
            .joined(separator: " / ")
    }
}
