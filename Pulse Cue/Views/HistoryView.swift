import SwiftData
import SwiftUI

/// Past sessions stay primary: one quiet chronological list, with detail
/// available through navigation instead of an analytics-style overview.
struct HistoryView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var dataScope: WorkoutDataScopeResolver
    /// Opens an in-progress Free Workout the same way Home / Training do.
    @StateObject private var freeWorkout = FreeWorkoutLauncher()
    /// A 進行中 Free Workout row that could not be resumed falls back to its
    /// ordinary detail, so the tap is never a dead end.
    @State private var detailSessionId: UUID?

    @Query(sort: [SortDescriptor(\Session.startedAt, order: .reverse)])
    private var allSessions: [Session]

    @Query(sort: [SortDescriptor(\Routine.updatedAt, order: .reverse)])
    private var routines: [Routine]

    /// History for whoever is signed in. The other rows stay in the store —
    /// they are simply not this account's to show.
    private var sessions: [Session] { dataScope.scope.visible(allSessions) }

    @State private var visibleCount = 10
    private let pageSize = 10

    var body: some View {
        ZStack {
            PulseAtmosphericBackground()
                .ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header

                    if sessions.isEmpty {
                        emptyState
                            .padding(.top, 36)
                    } else {
                        Text("最近のトレーニング")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.top, 30)
                            .padding(.bottom, 8)

                        ForEach(Array(sessions.prefix(visibleCount).enumerated()), id: \.element.id) { index, session in
                            sessionRow(session)
                            if index < min(sessions.count, visibleCount) - 1 {
                                Divider()
                                    .padding(.leading, 54)
                            }
                        }

                        if sessions.count > visibleCount {
                            loadMoreButton
                                .padding(.top, 18)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("履歴")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { freeWorkout.configure(context: modelContext, scope: dataScope.scope, authority: dataScope.authority) }
        .onChange(of: dataScope.scope) { _, scope in freeWorkout.configure(context: modelContext, scope: scope, authority: dataScope.authority) }
        .fullScreenCover(item: $freeWorkout.presented) { model in
            FreeWorkoutView(model: model, onClose: freeWorkout.workoutScreenClosed)
        }
        .navigationDestination(item: $detailSessionId) { id in
            if let session = sessions.first(where: { $0.id == id }) {
                SessionDetailView(session: session)
            }
        }
        .alert(
            "記録されたセットがないため保存されませんでした",
            isPresented: Binding(
                get: { freeWorkout.notice == .nothingSaved },
                set: { if !$0 { freeWorkout.notice = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        }
    }

    private func isResumableFreeWorkout(_ session: Session) -> Bool {
        session.status == .inProgress
            && routines.first(where: { $0.id == session.routineId })?.origin == .freeWorkout
    }

    /// Whether to resume is decided at tap time by the launcher, against the
    /// store and scope as they are then — never by this row's snapshot.
    private func resumeFreeWorkout(_ session: Session) {
        let id = session.id
        if !freeWorkout.resume(sessionId: id) {
            detailSessionId = id
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("トレーニング履歴")
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text("過去のトレーニングを日付順に確認できます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: Session) -> some View {
        if isResumableFreeWorkout(session) {
            Button {
                resumeFreeWorkout(session)
            } label: {
                sessionRowLabel(session)
            }
            .buttonStyle(.plain)
            .disabled(freeWorkout.isBusy)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(rowAccessibilityLabel(session))
            .accessibilityHint("進行中のフリーワークアウトを再開")
        } else {
            NavigationLink {
                SessionDetailView(session: session)
            } label: {
                sessionRowLabel(session)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(rowAccessibilityLabel(session))
            .accessibilityHint("トレーニング内容を表示")
        }
    }

    private func sessionRowLabel(_ session: Session) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                accessibilitySessionRow(session)
            } else {
                standardSessionRow(session)
            }
        }
        .contentShape(Rectangle())
    }

    private func rowAccessibilityLabel(_ session: Session) -> String {
        "\(routineName(for: session))、\(formatDate(session.startedAt))、\(formatDuration(session.totalSeconds))、\(statusLabel(session.status))"
    }

    private func standardSessionRow(_ session: Session) -> some View {
        HStack(alignment: .center, spacing: 14) {
            statusIconView(session)

            VStack(alignment: .leading, spacing: 5) {
                sessionTitle(session)
                ViewThatFits {
                    HStack(spacing: 8) {
                        Text(formatDate(session.startedAt))
                        Text("・")
                        Text(formatDuration(session.totalSeconds))
                    }
                    sessionMetadata(session)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
            statusAndChevron(session)
        }
        .frame(minHeight: 70)
    }

    private func accessibilitySessionRow(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                statusIconView(session)
                Text(statusLabel(session.status))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor(session.status))
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            sessionTitle(session)
            sessionMetadata(session)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
    }

    private func statusIconView(_ session: Session) -> some View {
        Image(systemName: statusIcon(session.status))
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(statusColor(session.status))
            .frame(width: 40, height: 40)
            .background(Circle().fill(statusColor(session.status).opacity(0.12)))
            .accessibilityHidden(true)
    }

    private func sessionTitle(_ session: Session) -> some View {
        Text(routineName(for: session))
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sessionMetadata(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(formatDate(session.startedAt))
            Text(formatDuration(session.totalSeconds))
        }
    }

    private func statusAndChevron(_ session: Session) -> some View {
        HStack(spacing: 10) {
            Text(statusLabel(session.status))
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor(session.status))
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "まだ履歴がありません",
            systemImage: "clock.arrow.circlepath",
            description: Text("トレーニングを完了すると、ここから内容を振り返れます。")
        )
    }

    private var loadMoreButton: some View {
        Button("さらに読み込む") {
            visibleCount += pageSize
        }
        .buttonStyle(PulseSecondaryButtonStyle())
        .accessibilityHint("古いトレーニングを追加で表示")
    }

    private func routineName(for session: Session) -> String {
        routines.first(where: { $0.id == session.routineId })?.name ?? "トレーニング"
    }

    private func statusLabel(_ status: SessionStatus) -> String {
        switch status {
        case .completed: return "完了"
        case .abandoned: return "中断"
        case .inProgress: return "進行中"
        }
    }

    private func statusIcon(_ status: SessionStatus) -> String {
        switch status {
        case .completed: return "checkmark"
        case .abandoned: return "xmark"
        case .inProgress: return "ellipsis"
        }
    }

    private func statusColor(_ status: SessionStatus) -> Color {
        switch status {
        case .completed: return AppTheme.accent
        case .abandoned: return .orange
        case .inProgress: return .secondary
        }
    }

    // A single cached formatter shared by every row. Each session row formats
    // its date twice (visible label + VoiceOver string); creating a
    // `DateFormatter` per call re-parsed the format string on every row on
    // every scroll pass. The output is identical.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M月d日（E） HH:mm"
        return formatter
    }()

    private func formatDate(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }

    private func formatDuration(_ seconds: Int) -> String {
        DateUtils.formatDuration(seconds: max(0, seconds))
    }
}
