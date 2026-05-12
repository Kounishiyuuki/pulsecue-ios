//
//  WorkoutView.swift
//  Pulse Cue
//
//  Created by Codex.
//

import SwiftUI
import SwiftData

struct WorkoutView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var runnerViewModel: RunnerViewModel

    @Query(sort: [SortDescriptor(\Routine.updatedAt, order: .reverse)]) private var routines: [Routine]

    @State private var searchText: String = ""
    @State private var editorRoutine: Routine?
    @State private var orderStore = RoutineOrderStore()

    var body: some View {
        List {
            if routines.isEmpty {
                ContentUnavailableView(
                    "ルーティンがありません",
                    systemImage: "list.bullet.rectangle",
                    description: Text("右上の＋から作成できます。")
                )
                .listRowBackground(AppTheme.background)
            } else {
                if !pinnedRoutines.isEmpty {
                    Section("ピン留め") {
                        routineList(pinnedRoutines, pinned: true)
                    }
                }
                Section(pinnedRoutines.isEmpty ? "ルーティン" : "その他") {
                    routineList(regularRoutines, pinned: false)
                }
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic))
        .navigationTitle("ワークアウト")
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    createRoutine()
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                EditButton()
            }
        }
        .sheet(item: $editorRoutine) { routine in
            RoutineEditorView(routine: routine)
        }
    }

    private func routineList(_ routines: [Routine], pinned: Bool) -> some View {
        ForEach(routines, id: \.id) { routine in
            NavigationLink {
                RoutineEditorView(routine: routine)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(routine.name)
                            .font(.headline)
                        if routine.isPinned {
                            Image(systemName: "pin.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("更新: \(DateUtils.formatDate(routine.updatedAt))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    togglePinned(routine)
                } label: {
                    Label(routine.isPinned ? "ピン解除" : "ピン留め", systemImage: routine.isPinned ? "pin.slash" : "pin")
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
                Button("開始") {
                    runnerViewModel.start(routine: routine)
                }
                Button(routine.isPinned ? "ピン解除" : "ピン留め") {
                    togglePinned(routine)
                }
                Button("複製") {
                    duplicateRoutine(routine)
                }
                Button("削除", role: .destructive) {
                    deleteRoutine(routine)
                }
            }
        }
        .onMove { fromOffsets, toOffset in
            orderStore.move(routines: routines, fromOffsets: fromOffsets, toOffset: toOffset, pinned: pinned)
        }
    }

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
