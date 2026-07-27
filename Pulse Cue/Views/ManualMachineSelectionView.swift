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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @StateObject private var viewModel: ManualMachineSelectionViewModel

    /// Which custom machine the form sheet is editing; `nil` while the
    /// sheet is closed. `isAddingCustom` drives the create case.
    @State private var editingCustomMachine: CustomMachine?
    @State private var isAddingCustom = false
    @State private var pendingDeletion: CustomMachine?

    init(gym: Gym) {
        _viewModel = StateObject(wrappedValue: ManualMachineSelectionViewModel(gym: gym))
    }

    var body: some View {
        ZStack {
            MyGymStyle.backgroundLayer(for: colorScheme)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerBlock
                    filterChips

                    if viewModel.hiddenSelectedCount > 0 {
                        hiddenSelectedNote
                    }

                    customCard

                    if viewModel.hasNoVisibleEquipment {
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
                    if dynamicTypeSize.isAccessibilitySize {
                        saveBar
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !dynamicTypeSize.isAccessibilitySize {
                saveBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
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
        .sheet(isPresented: $isAddingCustom, onDismiss: viewModel.reloadCustomMachines) {
            CustomMachineFormView(gym: viewModel.gym)
        }
        .sheet(item: $editingCustomMachine, onDismiss: viewModel.reloadCustomMachines) { machine in
            CustomMachineFormView(gym: viewModel.gym, editing: machine)
        }
        .confirmationDialog(
            pendingDeletion.map { "「\($0.displayName)」を削除しますか？" } ?? "",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                if let machine = pendingDeletion {
                    viewModel.deleteCustom(machine)
                }
                pendingDeletion = nil
            }
            Button("キャンセル", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("このカスタムマシンをジムから削除します。保存済みのワークアウト履歴は残ります。")
        }
    }

    // MARK: - Cards

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            MyGymStyle.sectionHeader(icon: "building.2.fill", title: viewModel.gym.name)
            Text("このジムで使えるマシンにチェックを入れてください。あとからいつでも変更できます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
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
                .frame(minHeight: 44)
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
                .frame(minHeight: 44)
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
                .frame(minHeight: 44)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("絞り込みを解除")
    }

    private func chipBackground(isOn: Bool) -> some View {
        Capsule().fill(
            isOn ? AnyShapeStyle(AppTheme.accentFilled)
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
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }

    // MARK: - Custom machines

    /// One compact card holding every user-authored machine plus the add
    /// action. Deliberately a single card so custom equipment stays
    /// clearly identifiable without visually outweighing the 28-entry
    /// standard catalog below it.
    private var customCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                MyGymStyle.sectionHeader(icon: "wrench.and.screwdriver.fill", title: "カスタムマシン")
                if viewModel.hasCustomMachines {
                    Text("\(viewModel.customSelectedCount) / \(viewModel.customMachines.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
                Spacer(minLength: 0)
                Button {
                    isAddingCustom = true
                } label: {
                    Label("追加", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
                .accessibilityLabel("カスタムマシンを追加")
            }

            if !viewModel.hasCustomMachines {
                Text("カタログにない器具は、ここに登録するとプラン作成に使えます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if viewModel.visibleCustomMachines.isEmpty {
                Text("現在の絞り込みに一致するカスタムマシンはありません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(viewModel.visibleCustomMachines.enumerated()), id: \.element.id) { index, machine in
                    if index > 0 { Divider().opacity(0.35) }
                    customRow(machine)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }

    private func customRow(_ machine: CustomMachine) -> some View {
        let isOn = viewModel.isCustomSelected(machine)
        return HStack(spacing: 12) {
            Button {
                viewModel.toggleCustom(machine)
            } label: {
                HStack(spacing: 12) {
                    checkbox(isOn: isOn)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(machine.displayName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            customBadge
                        }
                        Text(customSubtitle(machine))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(customAccessibilityLabel(machine, isOn: isOn))
            .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            .frame(minHeight: 52)

            Menu {
                Button {
                    editingCustomMachine = machine
                } label: {
                    Label("編集", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    pendingDeletion = machine
                } label: {
                    Label("削除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(machine.displayName) の操作")
        }
        .padding(.vertical, 4)
    }

    private var customBadge: some View {
        Text("カスタム")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
            .foregroundStyle(Color.accentColor)
            .accessibilityHidden(true)
    }

    /// Body parts, plus the equipment type when the user set one.
    private func customSubtitle(_ machine: CustomMachine) -> String {
        let parts = machine.resolvedBodyParts.map(\.displayName).joined(separator: " / ")
        let base = parts.isEmpty ? "部位未設定" : parts
        if let type = machine.resolvedEquipmentType {
            return "\(base) ・ \(type.displayName)"
        }
        return base
    }

    /// Spoken as one phrase so VoiceOver conveys name, source, parts and
    /// availability without the user hunting through separate elements.
    private func customAccessibilityLabel(_ machine: CustomMachine, isOn: Bool) -> String {
        "\(machine.displayName)、カスタムマシン、\(customSubtitle(machine))、\(isOn ? "利用可能" : "利用しない")"
    }

    private func checkbox(isOn: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isOn ? Color.clear : Color.secondary.opacity(0.4),
                    lineWidth: 1.5
                )
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn ? AnyShapeStyle(AppTheme.accentFilled) : AnyShapeStyle(Color.clear))
                )
                .frame(width: 22, height: 22)
            if isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(.white)
            }
        }
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

    /// Distinguishes "you have selected nothing yet" from "your filter
    /// matched nothing" from "this gym has no custom machines yet", so
    /// the message always tells the user what to do next.
    private var emptyMessage: String {
        if viewModel.showSelectedOnly {
            return viewModel.hasSelection
                ? "現在の絞り込みでは選択済みマシンが表示されません。"
                : "マシンを選ぶと、ここで確認できます。"
        }
        if viewModel.hasActiveFilters {
            return viewModel.hasCustomMachines
                ? "検索ワードや部位フィルターを変更してください。"
                : "検索ワードや部位フィルターを変更するか、カスタムマシンを追加してください。"
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
                                .fill(viewModel.isSelected(entry) ? AnyShapeStyle(AppTheme.accentFilled) : AnyShapeStyle(Color.clear))
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
            .frame(minHeight: 52)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(viewModel.isSelected(entry) ? .isSelected : [])
    }

    private var saveBar: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    selectionSummary
                    saveButton
                        .frame(maxWidth: .infinity)
                }
            } else {
                HStack(spacing: 12) {
                    selectionSummary
                    Spacer()
                    saveButton
                        .frame(maxWidth: 200)
                }
            }
        }
        .padding(14)
        .background(
            PulseGlassPlate(level: .functional, cornerRadius: 18)
        )
    }

    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("選択済み")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Standard + custom, so the number matches what will
            // actually be saved and used for plan generation.
            Text("\(viewModel.totalSelectedCount) 台")
                .font(.headline.weight(.bold))
        }
    }

    private var saveButton: some View {
        Button {
            viewModel.save()
        } label: {
            if viewModel.state == .saving {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                Label("プランを保存", systemImage: "tray.and.arrow.down.fill")
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(MyGymPrimaryButtonStyle())
        .disabled(viewModel.state == .saving)
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
