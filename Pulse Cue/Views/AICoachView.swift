//
//  AICoachView.swift
//  Pulse Cue
//
//  Created by Codex.
//
//  Premium liquid-glass AI Coach screen.
//
//  This screen never calls an external API. The entire suggestion is
//  synthesised locally from existing SwiftData records (Session,
//  StepResult, DayLog), and the wording is intentionally restrained:
//
//    - 「目安」「観察」 etc. are used instead of definitive
//      prescriptions.
//    - No medical metrics (HRV, autonomic nervous system, etc.) are
//      mentioned. Only data the user has actually entered or that
//      the app has measured.
//    - The CTA writes to DayLog.note via UserConfirmed<…> so the
//      privacy boundary established in AICoachStub.swift is honoured
//      from the only place that mutates persisted data.
//    - A privacy footer explicitly notes that AI is off and the
//      suggestion is local-only.
//

import SwiftUI
import SwiftData

struct AICoachView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var settings: SettingsStore

    @Query(sort: [SortDescriptor(\Session.startedAt, order: .reverse)])
    private var sessions: [Session]

    @Query private var allStepResults: [StepResult]
    @Query private var allDayLogs: [DayLog]

    @State private var savedAlertVisible = false
    @State private var selectedOptionId: UUID?

    private var suggestion: LocalCoachSuggestion {
        LocalCoachSuggestion.from(
            sessions: sessions,
            stepResults: allStepResults,
            dayLogs: allDayLogs,
            now: Date()
        )
    }

    private var aiEnabled: Bool {
        AIServicesProvider.coach.isEnabled
    }

    var body: some View {
        ZStack {
            backgroundLayer.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    brandHeader
                    timestampPill
                    userMessageBubble
                    assistantCard
                    primaryCTA
                    privacyFooter
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
        }
        .navigationTitle("AI コーチ")
        .navigationBarTitleDisplayMode(.inline)
        .alert("提案を保存しました", isPresented: $savedAlertVisible) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("今日のメモに追記しました。確定済みのカロリーや履歴には影響しません。")
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

    // MARK: - Header / timestamp / user bubble

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

    private var timestampPill: some View {
        HStack {
            Spacer()
            Text(formatNowPill())
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 0.6))
            Spacer()
        }
    }

    private var userMessageBubble: some View {
        HStack {
            Spacer(minLength: 40)
            Text(suggestion.userPrompt)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.regularMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.5), lineWidth: 0.6)
                )
                .frame(maxWidth: 320, alignment: .trailing)
        }
    }

    // MARK: - Assistant card

    private var assistantCard: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(accentGradient)
                    .frame(width: 32, height: 32)
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 14) {
                Text(suggestion.reply)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().opacity(0.3)
                proposalSection
                Divider().opacity(0.3)
                reasonSection
                Divider().opacity(0.3)
                optionsSection
            }
            .padding(16)
            .background(glassBackground)
            .overlay(glassStroke)
        }
    }

    private var proposalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(icon: "mappin.and.ellipse", title: "提案")
            Text(suggestion.proposalDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var reasonSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(icon: "list.clipboard", title: "理由")
            Text(suggestion.reasonDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(icon: "slider.horizontal.3", title: "選択肢")
            ForEach(suggestion.options) { option in
                optionRow(option)
            }
        }
    }

    private func sectionLabel(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(accentGradient)
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(accentGradient)
        }
    }

    private func optionRow(_ option: LocalCoachSuggestion.Option) -> some View {
        let isSelected = selectedOptionId == option.id
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedOptionId = isSelected ? nil : option.id
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(accentGradient.opacity(isSelected ? 0.25 : 0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: option.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accentGradient)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(option.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(accentGradient) : AnyShapeStyle(Color.secondary))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.06 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(accentGradient, lineWidth: 0.8)
                    .opacity(isSelected ? 0.5 : 0)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.title) — \(option.detail)\(isSelected ? "、選択中" : "")")
    }

    // MARK: - Primary CTA / privacy footer

    private var primaryCTA: some View {
        Button {
            saveSuggestionToTodayNote()
        } label: {
            HStack(spacing: 8) {
                Text("提案をメモに保存")
                    .font(.headline)
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 14, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(accentGradient)
                    .shadow(
                        color: Color(red: 0.27, green: 0.5, blue: 0.95).opacity(0.35),
                        radius: 18, x: 0, y: 10
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("提案を今日のメモに保存")
    }

    private var privacyFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: aiEnabled ? "sparkles" : "sparkles.slash")
                    .font(.system(size: 11, weight: .bold))
                Text(aiEnabled ? "AI コーチ：有効" : "AI コーチ：オフ")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            Text("この提案はオンデバイスで生成された **目安** です。AI コーチは現在オフのため、データを外部に送信していません。医学的な助言ではなく、参考情報としてご活用ください。送信範囲は設定 → 連携と AI から変更できます（現在: \(settings.aiTransmissionScope.label)）。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    // MARK: - Save flow (UserConfirmed boundary)

    private func saveSuggestionToTodayNote() {
        // The local synthesis is treated as if it were AI output: it
        // must pass through `UserConfirmed` before mutating any
        // SwiftData record, mirroring the contract in
        // `AICoachStub.swift`.
        let coachSuggestion = AICoachSuggestion(
            id: UUID(),
            title: suggestion.proposalDetail,
            detail: suggestion.reasonDetail,
            proposedAction: nil
        )
        let confirmed = UserConfirmed(coachSuggestion)
        applyConfirmedSuggestion(confirmed)
        if settings.hapticsEnabled {
            SoundHapticManager.playHaptic()
        }
        savedAlertVisible = true
    }

    private func applyConfirmedSuggestion(_ confirmed: UserConfirmed<AICoachSuggestion>) {
        let log = DayLogStore.fetchOrCreateToday(modelContext: modelContext)
        let timeStr = formatTimeShort(confirmed.confirmedAt)
        let entry = "[\(timeStr) AI コーチ] \(confirmed.value.title)"
        if let existing = log.note, !existing.isEmpty {
            log.note = existing + "\n" + entry
        } else {
            log.note = entry
        }
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

    private func formatNowPill() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "今日 H:mm"
        return f.string(from: Date())
    }

    private func formatTimeShort(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "H:mm"
        return f.string(from: date)
    }
}

// MARK: - Local synthesis

/// On-device suggestion built from PulseCue's own records. No remote
/// model is involved. Wording is intentionally observational and
/// avoids medical claims.
struct LocalCoachSuggestion {
    let userPrompt: String
    let reply: String
    let proposalDetail: String
    let reasonDetail: String
    let options: [Option]

    struct Option: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String
    }

    static func from(
        sessions: [Session],
        stepResults: [StepResult],
        dayLogs: [DayLog],
        now: Date
    ) -> LocalCoachSuggestion {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let weekAgo = cal.date(byAdding: .day, value: -6, to: today) ?? today

        let recentSessions = sessions.filter { $0.startedAt >= weekAgo }
        let completed = recentSessions.filter { $0.status == .completed }
        let aborted = recentSessions.filter { $0.status == .abandoned }
        let totalSeconds = completed.reduce(0) { $0 + $1.totalSeconds }
        let totalMinutes = totalSeconds / 60

        let recentLogs = dayLogs.filter { $0.date >= weekAgo }
        let sleepValues = recentLogs.compactMap { $0.sleepMinutes }
        let avgSleepMinutes = sleepValues.isEmpty ? 0 : sleepValues.reduce(0, +) / sleepValues.count

        // 1. Cold start — not enough data.
        if recentSessions.isEmpty && recentLogs.isEmpty {
            return LocalCoachSuggestion(
                userPrompt: "まだ記録が少ないのですが、何から始めるのが良いですか？",
                reply: "現状は記録が少ないため、無理のない始め方をいくつかご提案します。あくまで目安としてご覧ください。",
                proposalDetail: "週 2 回・20 分前後の軽い種目から始めて、入力を続けてみる。記録が増えると次回以降の提案も具体的になります。",
                reasonDetail: "過去 7 日間でセッション・DayLog 共に入力がほぼありません。継続入力をきっかけにできる範囲の提案です。",
                options: [
                    .init(icon: "figure.walk", title: "20分の軽いウォーキング", detail: "気分転換・低負荷"),
                    .init(icon: "figure.cooldown", title: "10分のストレッチ", detail: "動き出すきっかけ作り")
                ]
            )
        }

        // 2. High abort rate — pull back.
        let abortRatio = recentSessions.isEmpty ? 0 : Double(aborted.count) / Double(recentSessions.count)
        if recentSessions.count >= 3 && abortRatio > 0.4 {
            return LocalCoachSuggestion(
                userPrompt: "最近セッションを途中で切り上げることが多いです。スケジュールは見直すべきでしょうか？",
                reply: "直近の中断率が目立つので、量よりも継続を優先する 2 択をご提案します。",
                proposalDetail: "今週の高強度を 1 回減らし、低負荷のセッションに置き換えてみる。週次の合計負荷を 10〜15% 下げる目安です。",
                reasonDetail: "過去 7 日に \(recentSessions.count) セッション中、\(aborted.count) 件が中断として記録されています。",
                options: [
                    .init(icon: "figure.cooldown", title: "30分のストレッチ", detail: "推奨・低負荷"),
                    .init(icon: "figure.walk", title: "45分の軽いウォーキング", detail: "気分転換")
                ]
            )
        }

        // 3. Short sleep — propose recovery.
        if avgSleepMinutes > 0 && avgSleepMinutes < 360 && completed.count >= 1 {
            let h = avgSleepMinutes / 60
            let m = avgSleepMinutes % 60
            let sleepLabel = m == 0 ? "\(h) 時間" : "\(h) 時間 \(m) 分"
            return LocalCoachSuggestion(
                userPrompt: "夕方のセッション後に疲労感が強いです。スケジュールを見直すべきでしょうか？",
                reply: "睡眠の入力データから判断できる範囲で、回復寄りのバリエーションをご提案します。",
                proposalDetail: "週中の高強度セッションを「アクティブリカバリー」に変更し、全体の週次負荷を約 15% 削減する目安です。",
                reasonDetail: "過去 7 日の睡眠平均が \(sleepLabel) で、6 時間を下回る日が確認されています。",
                options: [
                    .init(icon: "figure.cooldown", title: "30分のヨガ・ストレッチ", detail: "推奨・低負荷"),
                    .init(icon: "figure.walk", title: "45分の軽いウォーキング", detail: "気分転換")
                ]
            )
        }

        // 4. Default — balanced upkeep suggestion.
        return LocalCoachSuggestion(
            userPrompt: "今週のスケジュールに調整は必要でしょうか？",
            reply: "直近のセッション量と入力データを見たところ、現状は無理のない範囲のように見えます。維持向けの目安をお出しします。",
            proposalDetail: "今のペースを維持しつつ、週末に「アクティブリカバリー」を 1 件加えると、継続しやすい目安になります。",
            reasonDetail: "過去 7 日の完了セッションは \(completed.count) 件、合計 \(totalMinutes) 分。中断は \(aborted.count) 件、睡眠の入力日数は \(sleepValues.count) 日です。",
            options: [
                .init(icon: "figure.cooldown", title: "30分のヨガ・ストレッチ", detail: "推奨・低負荷"),
                .init(icon: "figure.walk", title: "45分の軽いウォーキング", detail: "気分転換")
            ]
        )
    }
}
