//
//  SessionDetailView.swift
//  Pulse Cue
//
//  Created by Codex.
//

import SwiftUI
import SwiftData

struct SessionDetailView: View {
    @Bindable var session: Session
    @Query private var results: [StepResult]
    @Query private var steps: [Step]

    init(session: Session) {
        self._session = Bindable(wrappedValue: session)
        let sessionId = session.id
        let routineId = session.routineId
        self._results = Query(
            filter: #Predicate<StepResult> { $0.sessionId == sessionId },
            sort: [SortDescriptor(\StepResult.setIndex, order: .forward)]
        )
        self._steps = Query(
            filter: #Predicate<Step> { $0.routineId == routineId },
            sort: [SortDescriptor(\Step.order, order: .forward)]
        )
    }

    var body: some View {
        List {
            Section("概要") {
                LabeledContent("状態", value: statusText)
                LabeledContent("開始", value: DateUtils.formatTime(session.startedAt))
                if let endedAt = session.endedAt {
                    LabeledContent("終了", value: DateUtils.formatTime(endedAt))
                    LabeledContent("合計", value: DateUtils.formatDuration(seconds: session.totalSeconds))
                }
            }

            Section("結果") {
                if results.isEmpty {
                    Text("記録された結果はありません")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(results) { result in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stepTitle(for: result))
                                    .font(.subheadline)
                                Text("セット \(result.setIndex + 1)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: result.done ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(result.done ? .green : .orange)
                        }
                    }
                }
            }
        }
        .navigationTitle(DateUtils.formatDate(session.dayDate))
    }

    private var statusText: String {
        switch session.status {
        case .completed:
            return "完了"
        case .abandoned:
            return "中断"
        case .inProgress:
            return "進行中"
        }
    }

    private func stepTitle(for result: StepResult) -> String {
        steps.first(where: { $0.id == result.stepId })?.title ?? "種目"
    }
}
