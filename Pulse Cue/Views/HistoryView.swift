//
//  HistoryView.swift
//  Pulse Cue
//
//  Created by Codex.
//
//  Premium liquid-glass activity log. Layout (top → bottom):
//    1. Title block: 「アクティビティ履歴」+ subtitle.
//    2. Hero card for the most recent completed session:
//       - "最新の完了セッション" pill
//       - Routine name + Japanese date/time
//       - 1h 15m TOTAL TIME (monospaced rounded)
//       - 総セット数 / 総レップス derived from StepResults
//       - Subtle 7-session sparkline (only when ≥3 completed
//         sessions exist — no fake analytics)
//    3. Recent session list:
//       - Icon, routine name, date/time, TOTAL TIME, COMPLETE /
//         ABORTED / 進行中 status.
//       - Tap → SessionDetailView (preserved).
//    4. 「さらに読み込む」CTA when more sessions are hidden.
//
//  No data is invented; everything comes from existing Session +
//  StepResult + Routine records.
//

import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.colorScheme) private var colorScheme

    @Query(sort: [SortDescriptor(\Session.startedAt, order: .reverse)])
    private var sessions: [Session]

    @Query(sort: [SortDescriptor(\Routine.updatedAt, order: .reverse)])
    private var routines: [Routine]

    @Query private var allStepResults: [StepResult]

    @State private var visibleCount: Int = 5

    private let pageSize: Int = 5

    var body: some View {
        ZStack {
            backgroundLayer.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    titleBlock

                    if let latest = latestCompletedSession {
                        heroCard(for: latest)
                    } else if sessions.isEmpty {
                        emptyStateCard
                    }

                    if !listSessions.isEmpty {
                        sessionListSection
                    }

                    if listSessions.count > visibleCount {
                        loadMoreButton
                    }

                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
        }
        .navigationTitle("履歴")
        .navigationBarTitleDisplayMode(.inline)
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

    // MARK: - Derived data

    /// Sessions surfaced in the list section. Hides the one already
    /// shown in the hero card to avoid visual duplication.
    private var listSessions: [Session] {
        guard let latest = latestCompletedSession else { return sessions }
        return sessions.filter { $0.id != latest.id }
    }

    private var latestCompletedSession: Session? {
        sessions.first(where: { $0.status == .completed })
    }

    private var completedSessions: [Session] {
        sessions.filter { $0.status == .completed }
    }

    private var sparklineValues: [Double] {
        // Last 7 completed sessions in chronological order, normalized
        // by totalSeconds. Hide when there's nothing meaningful to show.
        let recent = completedSessions.prefix(7).reversed()
        let values = recent.map { Double($0.totalSeconds) }
        return values.count >= 3 ? values : []
    }

    private func sessionTotals(_ session: Session) -> (done: Int, attempts: Int, reps: Int) {
        let results = allStepResults.filter { $0.sessionId == session.id }
        let done = results.filter { $0.done }.count
        let attempts = results.count
        let reps = results.compactMap { $0.actualReps }.reduce(0, +)
        return (done, attempts, reps)
    }

    private func routineName(for session: Session) -> String {
        routines.first(where: { $0.id == session.routineId })?.name ?? "ルーティン"
    }

    private func iconFor(routineId: UUID) -> String {
        let pool = [
            "figure.run",
            "figure.strengthtraining.traditional",
            "figure.cooldown",
            "figure.flexibility",
            "figure.core.training",
            "figure.pool.swim"
        ]
        let index = abs(routineId.uuidString.hashValue) % pool.count
        return pool[index]
    }

    // MARK: - Title

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("アクティビティ履歴")
                .font(.system(size: 28, weight: .bold))
            Text("過去のセッションのプレミアムログ")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Hero card

    private func heroCard(for session: Session) -> some View {
        let totals = sessionTotals(session)
        let totalSetsTheoretical = theoreticalTotalSets(for: session)
        let setsLabel: String = totalSetsTheoretical > 0
            ? "\(totals.done) /\(totalSetsTheoretical)"
            : "\(totals.done)"

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                latestSessionPill
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(routineName(for: session))
                    .font(.system(size: 24, weight: .bold))
                    .lineLimit(2)
                Text(formatJapaneseDateTime(session.startedAt))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatTotalTime(seconds: session.totalSeconds))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(accentGradient)
                Text("TOTAL TIME")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                statTile(label: "総セット数", value: setsLabel)
                statTile(label: "総レップス", value: "\(totals.reps)")
            }

            if !sparklineValues.isEmpty {
                sparklineChart
                    .frame(height: 56)
                    .padding(.top, 4)
            }
        }
        .padding(20)
        .background(glassBackground)
        .overlay(glassStroke)
    }

    private var latestSessionPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(accentGradient)
                .frame(width: 6, height: 6)
            Text("最新の完了セッション")
                .font(.caption.weight(.semibold))
                .foregroundStyle(accentGradient)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(accentGradient.opacity(0.4), lineWidth: 0.6))
    }

    private func statTile(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var sparklineChart: some View {
        GeometryReader { geo in
            ZStack {
                // Soft band underneath
                Sparkline(values: sparklineValues, smooth: true)
                    .stroke(
                        accentGradient.opacity(0.15),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round)
                    )
                Sparkline(values: sparklineValues, smooth: true)
                    .stroke(
                        accentGradient,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityHidden(true)
    }

    private func theoreticalTotalSets(for session: Session) -> Int {
        // We don't have direct access to routine steps without a separate
        // query; recorded attempts are the next-best proxy and avoid
        // inventing analytics.
        sessionTotals(session).attempts
    }

    // MARK: - Empty state

    private var emptyStateCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 32))
                .foregroundStyle(accentGradient)
            Text("履歴がありません")
                .font(.headline)
            Text("ルーティンを完了するとここに記録されます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(36)
        .background(glassBackground)
        .overlay(glassStroke)
    }

    // MARK: - Session list

    private var sessionListSection: some View {
        VStack(spacing: 12) {
            ForEach(listSessions.prefix(visibleCount), id: \.id) { session in
                sessionRow(session)
            }
        }
    }

    private func sessionRow(_ session: Session) -> some View {
        NavigationLink {
            SessionDetailView(session: session)
        } label: {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 40, height: 40)
                    Image(systemName: iconFor(routineId: session.routineId))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accentGradient)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(routineName(for: session))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(formatJapaneseDateShort(session.startedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text("TOTAL TIME")
                            .font(.caption2.weight(.bold))
                            .tracking(1.0)
                            .foregroundStyle(.secondary)
                        Text(formatTotalTime(seconds: session.totalSeconds))
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                    }
                    .padding(.top, 2)
                }

                Spacer(minLength: 8)
                statusBadge(for: session)
            }
            .padding(14)
            .background(glassBackground)
            .overlay(glassStroke)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(routineName(for: session)) \(formatJapaneseDateShort(session.startedAt)) \(formatTotalTime(seconds: session.totalSeconds)) \(statusLabel(session.status))")
    }

    private func statusBadge(for session: Session) -> some View {
        let (label, color, icon) = statusVisuals(session.status)
        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(label)
                .font(.caption2.weight(.bold))
                .tracking(0.6)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private func statusVisuals(_ status: SessionStatus) -> (String, Color, String) {
        switch status {
        case .completed: return ("COMPLETE", Color(red: 0.27, green: 0.62, blue: 0.95), "checkmark.circle.fill")
        case .abandoned: return ("ABORTED", Color(red: 0.85, green: 0.30, blue: 0.35), "xmark.circle.fill")
        case .inProgress: return ("進行中", .orange, "circle.dashed")
        }
    }

    private func statusLabel(_ status: SessionStatus) -> String {
        switch status {
        case .completed: return "完了"
        case .abandoned: return "中断"
        case .inProgress: return "進行中"
        }
    }

    // MARK: - Load more

    private var loadMoreButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                visibleCount += pageSize
            }
        } label: {
            Text("さらに読み込む")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accentGradient)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    Capsule()
                        .fill(.regularMaterial)
                )
                .overlay(
                    Capsule().strokeBorder(accentGradient.opacity(0.35), lineWidth: 0.6)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("さらに読み込む")
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

    // MARK: - Formatters

    private func formatTotalTime(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let h = clamped / 3600
        let m = (clamped % 3600) / 60
        let s = clamped % 60
        if h > 0 {
            return "\(h)h \(String(format: "%02d", m))m"
        }
        if m > 0 {
            return "\(m)m \(String(format: "%02d", s))s"
        }
        return "\(s)s"
    }

    private func formatJapaneseDateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日・aa h:mm"
        return f.string(from: date)
    }

    private func formatJapaneseDateShort(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d・HH:mm"
        return f.string(from: date)
    }
}

// MARK: - Sparkline shape

private struct Sparkline: Shape {
    let values: [Double]
    let smooth: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count >= 2 else { return path }
        let maxV = values.max() ?? 1
        let minV = values.min() ?? 0
        let range = max(0.001, maxV - minV)
        let stepX = rect.width / CGFloat(values.count - 1)

        let points: [CGPoint] = values.enumerated().map { i, v in
            let x = stepX * CGFloat(i)
            let normalized = (v - minV) / range
            // Inset 12% top and bottom so the line sits inside the rect.
            let y = rect.height - rect.height * 0.12 - rect.height * 0.76 * CGFloat(normalized)
            return CGPoint(x: x, y: y)
        }

        path.move(to: points[0])
        if smooth, points.count >= 2 {
            for i in 1..<points.count {
                let prev = points[i - 1]
                let curr = points[i]
                let mid = CGPoint(x: (prev.x + curr.x) / 2, y: (prev.y + curr.y) / 2)
                path.addQuadCurve(to: mid, control: prev)
                path.addQuadCurve(to: curr, control: CGPoint(x: mid.x, y: curr.y))
            }
        } else {
            for i in 1..<points.count {
                path.addLine(to: points[i])
            }
        }
        return path
    }
}
