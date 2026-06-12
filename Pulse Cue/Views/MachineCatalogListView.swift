//
//  MachineCatalogListView.swift
//  Pulse Cue
//
//  Local, read-only browser over `MachineCatalog.all`. Uses the pure
//  `MachineCatalogQuery` / `filteredEntries` helpers from PR #64 so the
//  view stays a thin shell — no SwiftData reads, no networking, no AI,
//  no save-to-routine behavior. The screen is reachable from Settings
//  as a reference/catalog view; binding it to routine creation is a
//  follow-up PR.
//

import SwiftUI

struct MachineCatalogListView: View {
    @State private var searchText: String = ""
    @State private var selectedBodyParts: Set<BodyPart> = []

    // BodyPart row order matches the spec (胸/背中/肩/腕/脚/体幹/有酸素).
    // `fullBody` stands in for 有酸素 in the local catalog (treadmill /
    // bike are tagged `fullBody`); we relabel it in the chip only.
    private let bodyPartFilters: [BodyPart] = [
        .chest, .back, .shoulders, .arms, .legs, .core, .fullBody
    ]

    private var query: MachineCatalogQuery {
        MachineCatalogQuery(
            searchText: searchText,
            bodyParts: Array(selectedBodyParts)
        )
    }

    private var results: [MachineCatalogEntry] {
        MachineCatalog.filteredEntries(matching: query)
    }

    var body: some View {
        ZStack {
            backgroundLayer.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerBlock
                    searchField
                    bodyPartChips
                    resultCountRow
                    resultsList
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .navigationTitle("マシンカタログ")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("マシンカタログ")
                .font(.system(size: 28, weight: .bold))
            Text("アプリ内のローカルマシン一覧です。外部APIは使用していません。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.textSecondary)
            TextField("マシン名・タグで検索", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("検索をクリア")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
                .strokeBorder(AppTheme.separator, lineWidth: 1)
        )
    }

    // MARK: - Body part chips

    private var bodyPartChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(bodyPartFilters, id: \.self) { part in
                    chip(for: part)
                }
                if !selectedBodyParts.isEmpty {
                    Button {
                        selectedBodyParts.removeAll()
                    } label: {
                        Text("クリア")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(Color.primary.opacity(0.06))
                            )
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func chip(for part: BodyPart) -> some View {
        let isOn = selectedBodyParts.contains(part)
        return Button {
            if isOn { selectedBodyParts.remove(part) }
            else { selectedBodyParts.insert(part) }
        } label: {
            Text(chipLabel(for: part))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(
                        isOn ? AppTheme.accentSoft
                             : Color.primary.opacity(0.06)
                    )
                )
                .foregroundStyle(isOn ? AppTheme.accent : .primary)
                .overlay(
                    Capsule().strokeBorder(
                        isOn ? AppTheme.accent.opacity(0.5) : Color.clear,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func chipLabel(for part: BodyPart) -> String {
        // Catalog uses `.fullBody` for cardio-style machines (treadmill/
        // bike); surface that as 有酸素 here per the spec without
        // touching the persisted `BodyPart` enum.
        part == .fullBody ? "有酸素" : part.displayName
    }

    // MARK: - Result count

    private var resultCountRow: some View {
        HStack {
            Text("該当 \(results.count) 件")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text("全 \(MachineCatalog.all.count) 件")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsList: some View {
        if results.isEmpty {
            emptyState
        } else {
            LazyVStack(spacing: 10) {
                ForEach(results) { entry in
                    NavigationLink {
                        MachineCatalogDetailView(entry: entry)
                    } label: {
                        MachineCatalogRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("詳細を表示")
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "dumbbell")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(AppTheme.textSecondary)
            Text("一致するマシンがありません")
                .font(.subheadline.weight(.semibold))
            Text("検索ワードや部位フィルターを変更してください。")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                .strokeBorder(AppTheme.separator, lineWidth: 1)
        )
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        // Calm, airy Apple Health Light surface (adapts to dark mode).
        AppTheme.surface
    }
}

// MARK: - Row

private struct MachineCatalogRow: View {
    let entry: MachineCatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.displayName)
                    .font(.headline)
                Spacer(minLength: 8)
                if entry.beginnerFriendly == true {
                    PulseStatusBadge("初心者OK", kind: .success)
                }
            }

            // Body parts row
            if !entry.bodyParts.isEmpty {
                FlowChips(
                    items: BodyPart.allCases.filter { entry.bodyParts.contains($0) }
                        .map { $0.displayName }
                )
            }

            // Metadata row (category / equipment / difficulty)
            let meta = metadataLabels()
            if !meta.isEmpty {
                HStack(spacing: 6) {
                    ForEach(meta, id: \.self) { label in
                        Text(label)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(Color.primary.opacity(0.05))
                            )
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }
        }
        .pulseCard()
    }

    private func metadataLabels() -> [String] {
        var out: [String] = []
        if let c = entry.category { out.append(c.displayName) }
        if let e = entry.equipmentType { out.append(e.displayName) }
        if let d = entry.difficulty { out.append(d.displayName) }
        return out
    }
}

/// Lightweight horizontal chip row that wraps using SwiftUI's `Layout`
/// fallback `HStack`. Kept simple — the catalog has at most a handful
/// of body parts per entry so we don't need a full flow-layout impl.
private struct FlowChips: View {
    let items: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(AppTheme.accentSoft)
                    )
                    .foregroundStyle(AppTheme.accent)
            }
            Spacer(minLength: 0)
        }
    }
}

#Preview {
    NavigationStack {
        MachineCatalogListView()
    }
}
