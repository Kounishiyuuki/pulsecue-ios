//
//  RoutinePickerSheet.swift
//  Pulse Cue
//
//  Created by Codex.
//

import SwiftUI
import SwiftData

struct RoutinePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var runnerViewModel: RunnerViewModel
    @Query(sort: [SortDescriptor(\Routine.updatedAt, order: .reverse)]) private var routines: [Routine]

    var body: some View {
        NavigationStack {
            List {
                if routines.isEmpty {
                    ContentUnavailableView(
                        "ルーティンがありません",
                        systemImage: "list.bullet.rectangle",
                        description: Text("ワークアウトでルーティンを作成してください。")
                    )
                    .listRowBackground(AppTheme.background)
                } else {
                    ForEach(routines) { routine in
                        Button {
                            runnerViewModel.start(routine: routine)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(routine.name)
                                    .font(.headline)
                                Text("更新: \(DateUtils.formatDate(routine.updatedAt))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("ルーティン開始")
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .listStyle(.insetGrouped)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        dismiss()
                    }
                }
            }
        }
    }
}
