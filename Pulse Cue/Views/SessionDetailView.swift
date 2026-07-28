import SwiftData
import SwiftUI

/// History-detail presentation derived from persisted `StepResult` records.
///
/// `StepResult` is the historical source of truth: a completed workout's
/// results are preserved even after its original `Step`/`Routine` is deleted
/// (deletion does not cascade to `StepResult`). Current `Step`s only *enrich*
/// the display with the exercise title when still resolvable — they are never
/// required for a result to remain visible.
enum SessionHistoryPresentation {
    /// One exercise's worth of performed sets. `isOrphaned` is true when the
    /// originating `Step` no longer exists, so no truthful title is available.
    struct ExerciseResultGroup: Identifiable {
        let id: UUID            // the historical stepId
        let title: String
        let isOrphaned: Bool
        let results: [StepResult]
    }

    /// Fallback heading when the original `Step` was deleted. No exercise name
    /// is persisted on `StepResult`, so we never guess one.
    static let orphanedTitle = "削除された種目"

    /// Groups every persisted `StepResult` by its historical `stepId`.
    /// Resolvable steps come first in `Step.order`; orphaned groups follow in
    /// stable first-appearance order. Nothing is ever dropped.
    static func groupedResults(results: [StepResult], steps: [Step]) -> [ExerciseResultGroup] {
        guard !results.isEmpty else { return [] }

        var order: [UUID] = []
        var seen = Set<UUID>()
        // Resolvable steps first, honouring the routine's step order.
        for step in steps where results.contains(where: { $0.stepId == step.id }) {
            if seen.insert(step.id).inserted { order.append(step.id) }
        }
        // Then orphaned stepIds, in the order they first appear in results.
        for result in results where !seen.contains(result.stepId) {
            if seen.insert(result.stepId).inserted { order.append(result.stepId) }
        }

        return order.map { stepId in
            let groupResults = results
                .filter { $0.stepId == stepId }
                .sorted { $0.setIndex < $1.setIndex }
            if let step = steps.first(where: { $0.id == stepId }) {
                return ExerciseResultGroup(id: stepId, title: step.title, isOrphaned: false, results: groupResults)
            } else {
                return ExerciseResultGroup(id: stepId, title: orphanedTitle, isOrphaned: true, results: groupResults)
            }
        }
    }
}

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

                    if resultGroups.isEmpty {
                        emptyState
                    } else {
                        Text("実施した種目")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)

                        VStack(spacing: 0) {
                            ForEach(resultGroups) { group in
                                exerciseGroup(group)
                                if group.id != resultGroups.last?.id {
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

    private func exerciseGroup(_ group: SessionHistoryPresentation.ExerciseResultGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(group.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(group.isOrphaned ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(group.isOrphaned ? "\(group.title)（元の種目は削除されています）" : group.title)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(group.results) { result in
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

    /// History rows derived from persisted `StepResult` (source of truth),
    /// enriched with the current `Step` title when it still resolves.
    private var resultGroups: [SessionHistoryPresentation.ExerciseResultGroup] {
        SessionHistoryPresentation.groupedResults(results: results, steps: steps)
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
