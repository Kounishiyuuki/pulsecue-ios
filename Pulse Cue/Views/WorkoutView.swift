//
//  WorkoutView.swift
//  Pulse Cue
//
//  Created by Codex.
//
//  Premium routine browser. Behavior preserved: search, pin/unpin,
//  duplicate, delete, start, edit, create, and drag-to-reorder.
//

import SwiftUI
import SwiftData

struct WorkoutView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var runnerViewModel: RunnerViewModel

    @Query(sort: [SortDescriptor(\Routine.updatedAt, order: .reverse)]) private var routines: [Routine]
    @Query private var allSteps: [Step]
    @Query(sort: [SortDescriptor(\Session.startedAt, order: .reverse)]) private var recentSessions: [Session]

    @State private var searchText: String = ""
    @State private var editorRoutine: Routine?
    @State private var orderStore = RoutineOrderStore()

    var body: some View {
        ZStack {
            backgroundLayer.ignoresSafeArea()

            VStack(spacing: 12) {
                brandHeader
                searchBar
                titleBlock
                routineList
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .overlay(alignment: .bottomTrailing) {
            floatingCreateButton
                .padding(.trailing, 20)
                .padding(.bottom, 24)
        }
        .navigationTitle("ワークアウト")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
            }
        }
        .sheet(item: $editorRoutine) { routine in
            NavigationStack {
                RoutineEditorView(routine: routine)
            }
        }
    }

    // MARK: - Background / accent

    private var backgroundLayer: some View {
        // Calm, airy Apple Health Light surface (adapts to dark mode).
        AppTheme.surface
    }

    // MARK: - Header / search / title

    private var brandHeader: some View {
        HStack {
            ZStack {
                Circle().fill(AppTheme.accent).frame(width: 32, height: 32)
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Spacer()
            Text("PulseCue")
                .font(.headline.weight(.semibold))
            Spacer()
            Image(systemName: "bell")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
        }
        .padding(.top, 4)
        .accessibilityHidden(true)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("ルーティンを検索…", text: $searchText)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("検索クリア")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
        )
        .overlay(
            Capsule().strokeBorder(.white.opacity(0.6), lineWidth: 0.6)
        )
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("ルーティン")
                    .font(.system(size: 28, weight: .black))
                Image(systemName: "bolt.heart.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                Spacer()
                if !routines.isEmpty {
                    Text("\(filteredRoutines.count) / \(routines.count) 件")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
            }

            if !pinnedRoutines.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text("ピン留め \(pinnedRoutines.count) 件を優先表示中")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.orange)
            } else if !routines.isEmpty {
                Text("よく使うルーティンはピン留めすると上に固定されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - List

    private var routineList: some View {
        List {
            if routines.isEmpty {
                emptyStateRow
            } else if filteredRoutines.isEmpty {
                noSearchResultsRow
            } else {
                ForEach(pinnedRoutines, id: \.id) { routine in
                    routineCardRow(routine)
                }
                .onMove { fromOffsets, toOffset in
                    orderStore.move(routines: pinnedRoutines, fromOffsets: fromOffsets, toOffset: toOffset, pinned: true)
                }

                ForEach(regularRoutines, id: \.id) { routine in
                    routineCardRow(routine)
                }
                .onMove { fromOffsets, toOffset in
                    orderStore.move(routines: regularRoutines, fromOffsets: fromOffsets, toOffset: toOffset, pinned: false)
                }
            }

            newRoutineCard
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func routineCardRow(_ routine: Routine) -> some View {
        NavigationLink {
            RoutineEditorView(routine: routine)
        } label: {
            routineCardContent(routine)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { togglePinned(routine) } label: {
                Label(routine.isPinned ? "ピン解除" : "ピン留め",
                      systemImage: routine.isPinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing) {
            Button {
                runnerViewModel.start(routine: routine)
            } label: {
                Label("開始", systemImage: "play.fill")
            }
            .tint(.green)

            Button(role: .destructive) {
                deleteRoutine(routine)
            } label: {
                Label("削除", systemImage: "trash")
            }

            Button {
                duplicateRoutine(routine)
            } label: {
                Label("複製", systemImage: "doc.on.doc")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button("開始") { runnerViewModel.start(routine: routine) }
            Button(routine.isPinned ? "ピン解除" : "ピン留め") { togglePinned(routine) }
            Button("複製") { duplicateRoutine(routine) }
            Button("削除", role: .destructive) { deleteRoutine(routine) }
        }
    }

    private func routineCardContent(_ routine: Routine) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(routine.name)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                pinIcon(isPinned: routine.isPinned)
            }
            HStack(spacing: 8) {
                metaChip(icon: "clock.fill", text: durationText(for: routine), emphasized: estimatedMinutes(for: routine) != nil)
                metaChip(icon: "calendar", text: lastRunText(for: routine), emphasized: false)
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                cardBackground(isPinned: routine.isPinned)
                if routine.isPinned {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.orange.opacity(colorScheme == .dark ? 0.22 : 0.16),
                                    Color(red: 0.95, green: 0.28, blue: 0.18).opacity(colorScheme == .dark ? 0.14 : 0.08),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
        )
        .overlay(cardStroke(isPinned: routine.isPinned))
        .accessibilityLabel("\(routine.name) \(routine.isPinned ? "ピン留め" : "")")
    }

    private func pinIcon(isPinned: Bool) -> some View {
        ZStack {
            if isPinned {
                Circle().fill(AppTheme.accent.opacity(0.15)).frame(width: 28, height: 28)
            }
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isPinned ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(Color.secondary))
        }
        .frame(width: 28, height: 28)
    }

    private func metaChip(icon: String, text: String, emphasized: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(emphasized ? .primary : .secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(emphasized ? Color.orange.opacity(0.13) : Color.primary.opacity(0.06))
        )
    }

    // MARK: - Empty state / new-routine card / FAB

    private var emptyStateRow: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(AppTheme.accent.opacity(0.14))
                    .frame(width: 74, height: 74)
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
            }
            VStack(spacing: 6) {
                Text("最初のルーティンを作成")
                    .font(.headline.weight(.bold))
                Text("種目、セット、休憩をまとめておくと、次のトレーニングをすぐ開始できます。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                createRoutine()
            } label: {
                Label("ルーティンを作成", systemImage: "plus")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(AppTheme.accent))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(glassStroke)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
    }

    private var noSearchResultsRow: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
            Text("該当するルーティンがありません")
                .font(.headline.weight(.bold))
            Text("検索語を変えるか、新しいルーティンを作成してください。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(glassStroke)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
    }

    private var newRoutineCard: some View {
        Button {
            createRoutine()
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(AppTheme.accent.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AppTheme.accent)
                }
                Text("新規作成")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                Text("カスタムルーティンを追加")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        AppTheme.accent.opacity(0.4),
                        style: StrokeStyle(lineWidth: 1.2, dash: [5])
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("新規ルーティンを作成")
    }

    private var floatingCreateButton: some View {
        Button {
            createRoutine()
        } label: {
            ZStack {
                Circle()
                    .fill(AppTheme.accent)
                    .frame(width: 56, height: 56)
                    .shadow(
                        color: Color(red: 0.27, green: 0.5, blue: 0.95).opacity(0.4),
                        radius: 16, x: 0, y: 8
                    )
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("新規ルーティンを作成")
    }

    // MARK: - Glass surfaces

    private var glassBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.regularMaterial)
            .shadow(color: .black.opacity(0.05), radius: 14, x: 0, y: 8)
    }

    private var glassStroke: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.7), .white.opacity(0.1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.6
            )
    }

    private func cardBackground(isPinned: Bool) -> some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.regularMaterial)
            .shadow(
                color: isPinned ? Color.orange.opacity(0.18) : Color.black.opacity(0.05),
                radius: isPinned ? 18 : 14,
                x: 0,
                y: isPinned ? 10 : 8
            )
    }

    private func cardStroke(isPinned: Bool) -> some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: isPinned
                        ? [Color.orange.opacity(0.78), Color.white.opacity(0.26)]
                        : [Color.white.opacity(0.7), Color.white.opacity(0.1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: isPinned ? 1.2 : 0.6
            )
    }

    // MARK: - Derived data

    private var filteredRoutines: [Routine] {
        guard !searchText.isEmpty else { return routines }
        return routines.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var pinnedRoutines: [Routine] {
        let pinned = filteredRoutines.filter { $0.isPinned }
        return orderStore.ordered(routines: pinned, pinned: true)
    }

    private var regularRoutines: [Routine] {
        let regular = filteredRoutines.filter { !$0.isPinned }
        return orderStore.ordered(routines: regular, pinned: false)
    }

    private var stepsByRoutine: [UUID: [Step]] {
        Dictionary(grouping: allSteps, by: \.routineId)
    }

    private func estimatedMinutes(for routine: Routine) -> Int? {
        let steps = stepsByRoutine[routine.id] ?? []
        guard !steps.isEmpty else { return nil }
        var totalSeconds = 0
        for step in steps {
            let sets = max(1, step.sets)
            // Assume ~30s per set + the step's rest interval between sets.
            totalSeconds += sets * 30 + max(0, sets - 1) * step.restSeconds
        }
        return max(1, totalSeconds / 60)
    }

    private func durationText(for routine: Routine) -> String {
        if let minutes = estimatedMinutes(for: routine) { return "\(minutes)分" }
        return "種目なし"
    }

    private var lastRunByRoutine: [UUID: Date] {
        var map: [UUID: Date] = [:]
        for session in recentSessions {
            // recentSessions is ordered by startedAt desc, so the first
            // hit is the latest run for that routine.
            if map[session.routineId] == nil {
                map[session.routineId] = session.startedAt
            }
        }
        return map
    }

    private func lastRunText(for routine: Routine) -> String {
        if let date = lastRunByRoutine[routine.id] {
            let formatter = DateFormatter()
            formatter.dateFormat = "M/d"
            return "最終: " + formatter.string(from: date)
        }
        return "未実施"
    }

    // MARK: - Mutations (preserved)

    private func createRoutine() {
        let routine = Routine(name: "新しいルーティン")
        modelContext.insert(routine)
        editorRoutine = routine
    }

    private func togglePinned(_ routine: Routine) {
        routine.isPinned.toggle()
        routine.updatedAt = Date()
        orderStore.setPinned(routine.id, pinned: routine.isPinned)
    }

    private func duplicateRoutine(_ routine: Routine) {
        let newRoutine = Routine(name: routine.name + "（コピー）", isPinned: routine.isPinned)
        modelContext.insert(newRoutine)

        let rid = routine.id
        let descriptor = FetchDescriptor<Step>(
            predicate: #Predicate<Step> { step in
                step.routineId == rid
            },
            sortBy: [SortDescriptor(\Step.order)]
        )
        let steps = (try? modelContext.fetch(descriptor)) ?? []
        for step in steps {
            let copy = Step(
                routineId: newRoutine.id,
                order: step.order,
                title: step.title,
                sets: step.sets,
                repsTarget: step.repsTarget,
                restSeconds: step.restSeconds,
                note: step.note,
                isWarmup: step.isWarmup
            )
            modelContext.insert(copy)
        }
        orderStore.setPinned(newRoutine.id, pinned: newRoutine.isPinned)
    }

    private func deleteRoutine(_ routine: Routine) {
        let rid = routine.id
        let descriptor = FetchDescriptor<Step>(
            predicate: #Predicate<Step> { step in
                step.routineId == rid
            }
        )
        let steps = (try? modelContext.fetch(descriptor)) ?? []
        steps.forEach { modelContext.delete($0) }
        modelContext.delete(routine)
    }
}
