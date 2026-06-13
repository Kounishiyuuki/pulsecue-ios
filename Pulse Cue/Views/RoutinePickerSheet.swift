//
//  RoutinePickerSheet.swift
//  Pulse Cue
//
//  Sheet shown from the Runner tab when the user picks which routine
//  to start. Surface goals (per `Docs/p0-requirements-audit.md`):
//   - quick search by routine name
//   - pinned routines on top, in the same order the WorkoutView uses
//   - pin/unpin without leaving the sheet
//   - tap a row → start runner (existing behavior, unchanged)
//
//  Reorder is **intentionally not** offered here — toggling SwiftUI
//  edit mode would clash with the "single tap to start" flow. The
//  WorkoutView remains the canonical drag-to-reorder surface, and a
//  footnote in the sheet points there. Pin order changes made here
//  propagate to WorkoutView through the shared `RoutineOrderStore`.
//

import SwiftUI
import SwiftData

struct RoutinePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var runnerViewModel: RunnerViewModel
    @Query(sort: [SortDescriptor(\Routine.updatedAt, order: .reverse)])
    private var routines: [Routine]

    @State private var searchText: String = ""
    @State private var orderStore = RoutineOrderStore()

    var body: some View {
        NavigationStack {
            List {
                if routines.isEmpty {
                    emptyStateRow
                } else if filteredRoutines.isEmpty {
                    noMatchRow
                } else {
                    if !pinnedRoutines.isEmpty {
                        Section {
                            ForEach(pinnedRoutines) { routine in
                                routineRow(routine)
                            }
                        } header: {
                            PulseSectionHeader("ピン留め", icon: "pin.fill")
                        }
                    }
                    if !otherRoutines.isEmpty {
                        Section {
                            ForEach(otherRoutines) { routine in
                                routineRow(routine)
                            }
                        } header: {
                            PulseSectionHeader(
                                pinnedRoutines.isEmpty ? "ルーティン" : "その他",
                                icon: "list.bullet.rectangle"
                            )
                        }
                    }
                    reorderHintFooter
                }
            }
            .navigationTitle("ルーティン開始")
            .scrollContentBackground(.hidden)
            .background(AppTheme.surface.ignoresSafeArea())
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "ルーティンを検索")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
        }
    }

    // MARK: - Rows

    private func routineRow(_ routine: Routine) -> some View {
        Button {
            runnerViewModel.start(routine: routine)
            dismiss()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                if routine.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(routine.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("更新: \(DateUtils.formatDate(routine.updatedAt))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
        .accessibilityLabel("\(routine.name)\(routine.isPinned ? "、ピン留め済み" : "")")
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                togglePinned(routine)
            } label: {
                Label(
                    routine.isPinned ? "ピン解除" : "ピン留め",
                    systemImage: routine.isPinned ? "pin.slash" : "pin"
                )
            }
            .tint(.orange)
        }
    }

    private var emptyStateRow: some View {
        ContentUnavailableView(
            "ルーティンがありません",
            systemImage: "list.bullet.rectangle",
            description: Text("ワークアウトでルーティンを作成してください。")
        )
        .listRowBackground(AppTheme.surface)
    }

    private var noMatchRow: some View {
        ContentUnavailableView(
            "「\(searchText)」 に一致するルーティンがありません",
            systemImage: "magnifyingglass",
            description: Text("別のキーワードを試すか、検索をクリアしてください。")
        )
        .listRowBackground(AppTheme.surface)
    }

    @ViewBuilder
    private var reorderHintFooter: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "pin")
                        .font(.caption2)
                    Text("行を右にスワイプするとピン留め / 解除できます。")
                        .font(.footnote)
                }
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.caption2)
                    Text("並び替えはワークアウト タブから行えます。")
                        .font(.footnote)
                }
            }
            .foregroundStyle(.secondary)
            .listRowBackground(AppTheme.surface)
        }
    }

    // MARK: - Derived data

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredRoutines: [Routine] {
        guard !trimmedSearch.isEmpty else { return routines }
        return routines.filter {
            $0.name.localizedCaseInsensitiveContains(trimmedSearch)
        }
    }

    private var pinnedRoutines: [Routine] {
        orderStore.ordered(routines: filteredRoutines.filter(\.isPinned), pinned: true)
    }

    private var otherRoutines: [Routine] {
        orderStore.ordered(routines: filteredRoutines.filter { !$0.isPinned }, pinned: false)
    }

    // MARK: - Actions

    private func togglePinned(_ routine: Routine) {
        routine.isPinned.toggle()
        routine.updatedAt = Date()
        orderStore.setPinned(routine.id, pinned: routine.isPinned)
        // The SwiftData model context auto-saves on next render, but
        // we make the write explicit so the sheet's @Query observes
        // the update before the next animation frame.
        try? modelContext.save()
    }
}
