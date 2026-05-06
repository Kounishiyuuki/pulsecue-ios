//
//  WorkoutView.swift
//  Pulse Cue
//
//  Created by Codex.
//
//  Premium liquid-glass routine browser. Layout:
//    - Brand header (PulseCue + bell)
//    - Inline glass search bar
//    - 「ルーティン」title block
//    - List of routine cards: name, pin indicator, 推定時間 chip,
//      最終実行 chip. Pinned routines surface above the rest. Each
//      card supports the existing swipe actions / context menu /
//      tap-to-edit (NavigationLink) wiring.
//    - Inline 「新規作成」outlined card at the bottom.
//    - Floating gradient FAB at bottom-right.
//
//  Behavior preserved 1:1: search filter, pin/unpin, duplicate,
//  delete, start (RunnerViewModel.start), edit (push), create new
//  (modal sheet via $editorRoutine), drag-to-reorder via EditButton.
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
        LinearGradient(colors: backgroundColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var backgroundColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.05, green: 0.07, blue: 0.12),
                Color(red: 0.07, green: 0.06, blue: 0.13),
                Color(red: 0.05, green: 0.07, blue: 0.10)
            ]
        } else {
            return [
                Color(red: 0.93, green: 0.96, blue: 1.00),
                Color(red: 0.96, green: 0.97, blue: 1.00),
                Color(red: 0.99, green: 0.96, blue: 1.00)
            ]
        }
    }

    private var accentGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.27, green: 0.62, blue: 0.95),
                Color(red: 0.49, green: 0.51, blue: 0.97),
                Color(red: 0.66, green: 0.45, blue: 0.95)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Header / search / title

    private var brandHeader: some View {
        HStack {
            ZStack {
                Circle().fill(accentGradient).frame(width: 32, height: 32)
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
        HStack(spacing: 6) {
            Text("ルーティン")
                .font(.system(size: 26, weight: .bold))
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accentGradient)
            Spacer()
            if !routines.isEmpty {
                Text("\(routines.count) 件")
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
                metaChip(icon: "clock", text: durationText(for: routine))
                metaChip(icon: "calendar", text: lastRunText(for: routine))
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                glassBackground
                if routine.isPinned {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(accentGradient.opacity(0.05))
                }
            }
        )
        .overlay(glassStroke)
        .accessibilityLabel("\(routine.name) \(routine.isPinned ? "ピン留め" : "")")
    }

    private func pinIcon(isPinned: Bool) -> some View {
        ZStack {
            if isPinned {
                Circle().fill(accentGradient.opacity(0.15)).frame(width: 28, height: 28)
            }
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isPinned ? AnyShapeStyle(accentGradient) : AnyShapeStyle(Color.secondary))
        }
        .frame(width: 28, height: 28)
    }

    private func metaChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(Color.primary.opacity(0.06))
        )
    }

    // MARK: - Empty state / new-routine card / FAB

    private var emptyStateRow: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 32))
                .foregroundStyle(accentGradient)
            Text("ルーティンがありません")
                .font(.headline)
            Text("下のカード、または右下の + から作成できます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(36)
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
                        .fill(accentGradient.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(accentGradient)
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
                        accentGradient.opacity(0.4),
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
                    .fill(accentGradient)
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
