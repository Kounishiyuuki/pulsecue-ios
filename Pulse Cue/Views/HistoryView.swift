//
//  HistoryView.swift
//  Pulse Cue
//
//  Created by Codex.
//

import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query(sort: [SortDescriptor(\Session.startedAt, order: .reverse)]) private var sessions: [Session]
    @Query(sort: [SortDescriptor(\Routine.updatedAt, order: .reverse)]) private var routines: [Routine]

    var body: some View {
        List {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "履歴がありません",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("ルーティンを完了すると表示されます。")
                )
                .listRowBackground(AppTheme.background)
            } else {
                ForEach(sessions) { session in
                    NavigationLink {
                        SessionDetailView(session: session)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(routineName(for: session))
                                .font(.headline)
                            HStack(spacing: 8) {
                                Text(DateUtils.formatDate(session.dayDate))
                                Text(statusText(for: session))
                                if session.status != .inProgress {
                                    Text(DateUtils.formatDuration(seconds: session.totalSeconds))
                                }
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("履歴")
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .listStyle(.insetGrouped)
    }

    private func routineName(for session: Session) -> String {
        routines.first(where: { $0.id == session.routineId })?.name ?? "ルーティン"
    }

    private func statusText(for session: Session) -> String {
        switch session.status {
        case .completed:
            return "完了"
        case .abandoned:
            return "中断"
        case .inProgress:
            return "進行中"
        }
    }
}
