//
//  MachineCatalogDetailView.swift
//  Pulse Cue
//
//  Read-only detail screen for a single `MachineCatalogEntry`, reached
//  by tapping a row in `MachineCatalogListView`. Mirrors the list's
//  local-only stance: no SwiftData reads/writes, no networking, no AI,
//  and crucially no routine creation — the "基本メニュー案" section is a
//  non-binding preview. Optional metadata renders only when present so
//  sparse entries don't show empty/broken sections.
//

import SwiftUI

struct MachineCatalogDetailView: View {
    @Environment(\.colorScheme) private var colorScheme

    let entry: MachineCatalogEntry

    @State private var showingCandidatePreview = false

    private var template: MachineExerciseTemplate {
        MachineExerciseTemplate(entry: entry)
    }

    private var candidate: RoutineStepCandidate {
        RoutineStepCandidate(entry: entry)
    }

    var body: some View {
        ZStack {
            backgroundLayer.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard
                    bodyPartSection
                    machineInfoSection
                    starterMenuSection
                    notesSection
                    footerNote
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .navigationTitle("マシン詳細")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingCandidatePreview) {
            MachineRoutineStepCandidatePreviewView(candidate: candidate)
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.displayName)
                        .font(.system(size: 24, weight: .bold))
                    Spacer()
                    if entry.beginnerFriendly == true {
                        badge(text: "初心者OK", color: .green)
                    }
                }
                if !primaryBodyParts.isEmpty {
                    chipRow(primaryBodyParts.map(\.displayName), tint: .accentColor)
                }
            }
        }
    }

    // MARK: - 対象部位

    @ViewBuilder
    private var bodyPartSection: some View {
        if !primaryBodyParts.isEmpty || !entry.secondaryMuscles.isEmpty {
            section(title: "対象部位") {
                VStack(alignment: .leading, spacing: 12) {
                    if !primaryBodyParts.isEmpty {
                        labeledChips(
                            label: "主に効く部位",
                            items: primaryBodyParts.map(\.displayName),
                            tint: .accentColor
                        )
                    }
                    if !entry.secondaryMuscles.isEmpty {
                        labeledChips(
                            label: "補助的に効く部位",
                            items: entry.secondaryMuscles.map(\.displayName),
                            tint: .secondary
                        )
                    }
                }
            }
        }
    }

    // MARK: - マシン情報

    @ViewBuilder
    private var machineInfoSection: some View {
        let rows = infoRows()
        if !rows.isEmpty || !entry.tags.isEmpty {
            section(title: "マシン情報") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows, id: \.label) { row in
                        infoRow(label: row.label, value: row.value)
                    }
                    if !entry.tags.isEmpty {
                        if !rows.isEmpty { Divider().opacity(0.4) }
                        labeledChips(label: "タグ", items: entry.tags, tint: .secondary)
                    }
                }
            }
        }
    }

    // MARK: - 基本メニュー案

    private var starterMenuSection: some View {
        section(title: "基本メニュー案") {
            VStack(alignment: .leading, spacing: 8) {
                if template.hasAnyDefault {
                    if let setsReps = template.setsAndRepsText {
                        menuLine(icon: "repeat", text: setsReps)
                    }
                    if let rest = template.restText {
                        menuLine(icon: "timer", text: rest)
                    }
                    Text("※ あくまで目安です。体調や経験に合わせて調整してください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                } else {
                    Text(MachineExerciseTemplate.fallbackMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    showingCandidatePreview = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.pencil")
                        Text("種目候補を見る")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                    )
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .accessibilityHint("種目候補のプレビューを開きます")
            }
        }
    }

    // MARK: - 注意点 / セットアップ

    @ViewBuilder
    private var notesSection: some View {
        if entry.setupNotes != nil || entry.safetyNotes != nil {
            section(title: "注意点・セットアップ") {
                VStack(alignment: .leading, spacing: 12) {
                    if let setup = entry.setupNotes {
                        noteBlock(icon: "slider.horizontal.3", title: "セットアップ", text: setup)
                    }
                    if let safety = entry.safetyNotes {
                        noteBlock(icon: "exclamationmark.shield", title: "安全のために", text: safety)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footerNote: some View {
        Text("この画面はローカルカタログの確認用です。「種目候補を見る」から、このマシンを1種目のルーティンとして保存できます。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    // MARK: - Derived data

    /// Primary body parts in the canonical `BodyPart.allCases` order so
    /// the (unordered) `Set` renders stably across launches.
    private var primaryBodyParts: [BodyPart] {
        BodyPart.allCases.filter { entry.bodyParts.contains($0) }
    }

    private func infoRows() -> [(label: String, value: String)] {
        var out: [(label: String, value: String)] = []
        if let c = entry.category { out.append(("カテゴリ", c.displayName)) }
        if let e = entry.equipmentType { out.append(("器具タイプ", e.displayName)) }
        if let m = entry.movementPattern { out.append(("動作パターン", m.displayName)) }
        if let d = entry.difficulty { out.append(("難易度", d.displayName)) }
        return out
    }

    // MARK: - Reusable building blocks

    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 4)
            card { content() }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }

    private func labeledChips(label: String, items: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            chipRow(items, tint: tint)
        }
    }

    private func chipRow(_ items: [String], tint: Color) -> some View {
        FlowChipRow(items: items, tint: tint)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.trailing)
        }
    }

    private func menuLine(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            Text(text)
                .font(.subheadline.weight(.semibold))
        }
    }

    private func noteBlock(icon: String, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        let colors: [Color] = colorScheme == .dark
            ? [Color(red: 0.05, green: 0.07, blue: 0.12),
               Color(red: 0.07, green: 0.06, blue: 0.13)]
            : [Color(red: 0.93, green: 0.96, blue: 1.00),
               Color(red: 0.99, green: 0.96, blue: 1.00)]
        return LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// Wrapping chip row. The catalog has at most a handful of chips per
/// entry, but tags can be longer, so we wrap to new lines instead of
/// clipping. Uses SwiftUI's native `Layout` via a simple flow.
private struct FlowChipRow: View {
    let items: [String]
    let tint: Color

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(tint.opacity(0.14)))
                    .foregroundStyle(tint)
            }
        }
    }
}

/// Minimal flow layout that wraps subviews to the next line when they
/// run out of horizontal space. Local to this screen to avoid pulling
/// in a dependency for a handful of chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalWidth = max(totalWidth, x - spacing)
        }
        return CGSize(width: min(totalWidth, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

#Preview("Full metadata") {
    NavigationStack {
        MachineCatalogDetailView(
            entry: MachineCatalogEntry(
                id: "bench_press",
                displayName: "ベンチプレス",
                bodyParts: [.chest, .arms],
                category: .chest,
                equipmentType: .freeWeight,
                movementPattern: .push,
                difficulty: .intermediate,
                beginnerFriendly: true,
                secondaryMuscles: [.shoulders, .core],
                setupNotes: "ベンチに仰向けになり、肩甲骨を寄せて胸を張ります。",
                safetyNotes: "高重量ではセーフティバーを必ず使用してください。",
                defaultSets: 3,
                defaultReps: 8...12,
                defaultRestSeconds: 90,
                tags: ["コンパウンド", "バーベル"]
            )
        )
    }
}

#Preview("Minimal entry") {
    NavigationStack {
        MachineCatalogDetailView(
            entry: MachineCatalogEntry(
                id: "pec_deck",
                displayName: "ペックデック",
                bodyParts: [.chest]
            )
        )
    }
}
