//
//  ManualMachineSelectionView.swift
//  Pulse Cue
//
//  Lets the user mark which catalog machines exist at the given gym.
//  Each toggle flips local state; tapping「プランを保存」pushes the diff
//  into SwiftData via `GymRepository.setMachines`. Catalog rows stay
//  grouped by their primary body part so the user can scan by workout
//  target rather than alphabetically.
//
//  Search + body-part filtering layer on top of that original layout:
//  `.searchable` provides the search field and a compact chip row scopes
//  the visible body-part sections. All filter state and the filtered
//  results live in `ManualMachineSelectionViewModel` (reusing
//  `MachineCatalogQuery`); `selectedIds` stays the complete selection so
//  hiding a machine via search/filter never drops it on save.
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
                    filterChips

                    if viewModel.hiddenSelectedCount > 0 {
                        hiddenSelectedNote
                    }

                    if viewModel.visibleEntries.isEmpty {
                        emptyStateCard
                    } else {
                        ForEach(displayedParts) { part in
                            let entries = entries(for: part)
                            if !entries.isEmpty {
                                bodyPartCard(part: part, entries: entries)
                            }
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
        .searchable(
            text: $viewModel.searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "マシン名・タグで検索"
        )
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
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

    // MARK: - Filter chips (compact, horizontal)

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                selectedOnlyChip
                Divider().frame(height: 20).opacity(0.4)
                ForEach(viewModel.bodyPartFilters) { part in
                    bodyPartChip(part)
                }
                if viewModel.hasActiveFilters {
                    clearChip
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private var selectedOnlyChip: some View {
        let isOn = viewModel.showSelectedOnly
        return Button {
            viewModel.showSelectedOnly.toggle()
        } label: {
            Label("選択中", systemImage: isOn ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.caption.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(chipBackground(isOn: isOn))
                .foregroundStyle(isOn ? .white : .primary)
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.hasSelection && !viewModel.showSelectedOnly)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func bodyPartChip(_ part: BodyPart) -> some View {
        let isOn = viewModel.selectedBodyParts.contains(part)
        return Button {
            viewModel.toggleBodyPart(part)
        } label: {
            Text(chipLabel(for: part))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(chipBackground(isOn: isOn))
                .foregroundStyle(isOn ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var clearChip: some View {
        Button {
            viewModel.clearFilters()
        } label: {
            Text("すべて")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("絞り込みを解除")
    }

    private func chipBackground(isOn: Bool) -> some View {
        Capsule().fill(
            isOn ? AnyShapeStyle(MyGymStyle.accentGradient)
                 : AnyShapeStyle(Color.primary.opacity(0.06))
        )
    }

    private var hiddenSelectedNote: some View {
        Label(
            "選択済み \(viewModel.hiddenSelectedCount) 台は現在の絞り込みに含まれていません（保存対象です）。",
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .fixedSize(horizontal: false, vertical: true)
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
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .myGymCard()
    }

    private var emptyTitle: String {
        viewModel.showSelectedOnly ? "選択済みのマシンがありません" : "一致するマシンがありません"
    }

    private var emptyMessage: String {
        if viewModel.showSelectedOnly {
            return viewModel.hasSelection
                ? "現在の絞り込みでは選択済みマシンが表示されません。"
                : "マシンを選ぶと、ここで確認できます。"
        }
        return "検索ワードや部位フィルターを変更してください。"
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
        .accessibilityAddTraits(viewModel.isSelected(entry) ? .isSelected : [])
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

    /// Body-part sections to render: all parts by default, or only the
    /// parts the user is filtering by. The machines inside each section
    /// come from the view model's already-filtered `visibleEntries`.
    private var displayedParts: [BodyPart] {
        viewModel.selectedBodyParts.isEmpty
            ? viewModel.bodyPartFilters
            : viewModel.bodyPartFilters.filter { viewModel.selectedBodyParts.contains($0) }
    }

    private func entries(for part: BodyPart) -> [MachineCatalogEntry] {
        viewModel.visibleEntries.filter { $0.bodyParts.contains(part) }
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

    private func chipLabel(for part: BodyPart) -> String {
        // Catalog uses `.fullBody` for cardio-style machines (treadmill/
        // bike); surface that as 有酸素 here per the catalog screen without
        // touching the persisted `BodyPart` enum. Display-only relabel.
        part == .fullBody ? "有酸素" : part.displayName
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
