import SwiftData
import SwiftUI

/// One completed workout, ordered as identity → exercises → performed sets.
struct SessionDetailView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Bindable var session: Session
    @Query private var results: [StepResult]
    @Query private var steps: [Step]
    @Query private var routines: [Routine]

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
        ZStack {
            PulseAtmosphericBackground()
                .ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    identity

                    if stepsWithResults.isEmpty {
                        emptyState
                    } else {
                        Text("実施した種目")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)

                        VStack(spacing: 0) {
                            ForEach(stepsWithResults, id: \.id) { step in
                                exerciseResult(step)
                                if step.id != stepsWithResults.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 36)
            }
        }
        .navigationTitle("トレーニング詳細")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(routineName)
                .font(.largeTitle.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(formatDate(session.startedAt))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ViewThatFits {
                HStack(spacing: 20) {
                    summaryItem(statusText, label: "状態")
                    summaryItem(DateUtils.formatDuration(seconds: session.totalSeconds), label: "時間")
                }
                VStack(alignment: .leading, spacing: 12) {
                    summaryItem(statusText, label: "状態")
                    summaryItem(DateUtils.formatDuration(seconds: session.totalSeconds), label: "時間")
                }
            }
        }
        .pulseGlass(level: .subtle, padding: 20)
    }

    private func summaryItem(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .monospacedDigit()
        }
    }

    private func exerciseResult(_ step: Step) -> some View {
        let stepResults = results.filter { $0.stepId == step.id }
        return VStack(alignment: .leading, spacing: 12) {
            Text(step.title)
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(stepResults) { result in
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 6) {
                                resultIdentity(result)
                                resultRepetitions(result)
                                    .padding(.leading, 34)
                            }
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                resultIdentity(result)
                                Spacer()
                                resultRepetitions(result)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "セット \(result.setIndex + 1)、\(result.done ? "完了" : "未完了")、\(result.actualReps.map { "\($0)回" } ?? "回数記録なし")"
                    )
                }
            }
        }
        .padding(.vertical, 18)
    }

    private func resultIdentity(_ result: StepResult) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: result.done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(result.done ? AppTheme.accent : .secondary)
                .accessibilityHidden(true)
            Text("セット \(result.setIndex + 1)")
                .font(.subheadline)
        }
    }

    private func resultRepetitions(_ result: StepResult) -> some View {
        Text(result.actualReps.map { "\($0) 回" } ?? "記録なし")
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(result.actualReps == nil ? .secondary : .primary)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "セット結果がありません",
            systemImage: "list.bullet.clipboard",
            description: Text("このトレーニングには記録されたセット結果がありません。")
        )
    }

    private var stepsWithResults: [Step] {
        steps.filter { step in results.contains(where: { $0.stepId == step.id }) }
    }

    private var routineName: String {
        routines.first(where: { $0.id == session.routineId })?.name ?? "トレーニング"
    }

    private var statusText: String {
        switch session.status {
        case .completed: return "完了"
        case .abandoned: return "中断"
        case .inProgress: return "進行中"
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy年M月d日（E） HH:mm"
        return formatter.string(from: date)
    }
}
