//
//  HealthTargetSettingsView.swift
//  Pulse Cue
//
//  Entry point for health target configuration. Surfaces all three
//  layers of the resolver chain:
//    - defaults (always editable)
//    - weekday overrides (collapsible per-weekday section)
//    - date-specific overrides (one-off plans: trips, holidays, races)
//
//  Resolution priority remains date > weekday > default, locked by
//  HealthTargetResolverTests. Storage continues to use the existing
//  `health.targetSettings.v1` UserDefaults JSON — this PR adds UI
//  only, no persistence format changes.
//

import SwiftUI

struct HealthTargetSettingsView: View {
    @StateObject private var store = HealthTargetStore()
    @Environment(\.colorScheme) private var colorScheme

    @State private var showAddDateSheet = false
    @State private var pendingNewDate: Date = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                introBlock
                defaultsCard
                weekdayCard
                dateOverridesCard
                Color.clear.frame(height: 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(backgroundLayer.ignoresSafeArea())
        .navigationTitle("健康目標")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddDateSheet) {
            addDateSheet
        }
    }

    // MARK: - Sections

    private var introBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("デフォルト・曜日・日付ごとに目標を設定できます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("優先順位: 日付指定 > 曜日 > デフォルト")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var defaultsCard: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(icon: "flag.fill", title: "デフォルト目標")
                Text("毎日の基準。曜日や日付の上書きがない日に使われます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                targetEditor(
                    targets: store.settings.defaults,
                    apply: { store.updateDefaults($0) },
                )
            }
        }
    }

    private var weekdayCard: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(icon: "calendar", title: "曜日別の上書き")
                Text("曜日ごとに違う目標を設定できます。未設定の項目はデフォルトを使います。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(HealthTargetWeekday.allCases) { weekday in
                    weekdayRow(weekday)
                }
            }
        }
    }

    private func weekdayRow(_ weekday: HealthTargetWeekday) -> some View {
        let current = store.settings.weekdayOverrides[weekday] ?? HealthTargets()
        let hasAny = !current.isEmpty
        return DisclosureGroup {
            VStack(spacing: 10) {
                targetEditor(
                    targets: current,
                    apply: { store.updateWeekdayOverride(weekday, targets: $0) },
                )
                if hasAny {
                    Button(role: .destructive) {
                        store.clearWeekdayOverride(weekday)
                    } label: {
                        Label("この曜日の上書きを削除", systemImage: "trash")
                            .font(.caption.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text("\(weekday.shortLabel)曜日")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(hasAny ? "上書きあり" : "デフォルト")
                    .font(.caption2)
                    .foregroundStyle(hasAny ? accentColor : .secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    // MARK: - Date overrides

    private var dateOverridesCard: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(icon: "calendar.badge.plus", title: "日付ごとの上書き")
                Text("旅行・外食・休日など、特定の日だけ目標を変えたい場合に使います。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                let sortedDates = store.settings.dateOverrides.keys.sorted()
                if sortedDates.isEmpty {
                    Text("まだ日付指定の上書きはありません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(sortedDates, id: \.self) { day in
                        dateOverrideRow(day)
                    }
                }

                Button {
                    pendingNewDate = Calendar.current.startOfDay(for: Date())
                    showAddDateSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text("日付を追加")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(accentColor.opacity(0.12))
                    )
                    .foregroundStyle(accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func dateOverrideRow(_ day: Date) -> some View {
        let current = store.settings.dateOverrides[day] ?? HealthTargets()
        let hasAny = !current.isEmpty
        return DisclosureGroup {
            VStack(spacing: 10) {
                targetEditor(
                    targets: current,
                    apply: { store.updateDateOverride(day, targets: $0) },
                )
                Button(role: .destructive) {
                    store.clearDateOverride(day)
                } label: {
                    Label("この日の上書きを削除", systemImage: "trash")
                        .font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text(Self.dateLabel(day))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(hasAny ? "上書きあり" : "未設定")
                    .font(.caption2)
                    .foregroundStyle(hasAny ? accentColor : .secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var addDateSheet: some View {
        let alreadyConfigured = store.settings.dateOverrides[Calendar.current.startOfDay(for: pendingNewDate)] != nil
        return NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("対象日")
                    .font(.subheadline.weight(.semibold))
                DatePicker(
                    "対象日",
                    selection: $pendingNewDate,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
                .labelsHidden()

                if alreadyConfigured {
                    Text("この日は既に上書きが設定されています。リストから編集してください。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("日付を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { showAddDateSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加") {
                        addPendingDate()
                    }
                    .disabled(alreadyConfigured)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func addPendingDate() {
        let day = Calendar.current.startOfDay(for: pendingNewDate)
        // Seed with an empty HealthTargets so the row appears in the
        // list; the store auto-cleans rows that stay empty across
        // edits, but we want the user to immediately see the new row
        // so they can fill in values. Inserting via `updateDateOverride`
        // with a non-empty seed would force a value, so write directly
        // through a one-field default copied from the defaults — this
        // gives the user a visible starting point they can clear.
        let seed = HealthTargets(
            intakeCalories: store.settings.defaults.intakeCalories,
            sleepMinutes: store.settings.defaults.sleepMinutes,
            exerciseCalories: store.settings.defaults.exerciseCalories,
            balanceCalories: store.settings.defaults.balanceCalories
        )
        if seed.isEmpty {
            // No defaults configured — fall back to intake = 2000 so
            // the row isn't empty (the store would otherwise drop it).
            store.updateDateOverride(day, targets: HealthTargets(intakeCalories: 2000))
        } else {
            store.updateDateOverride(day, targets: seed)
        }
        showAddDateSheet = false
    }

    /// Long-form Japanese date label like "2026年5月19日 (火)" used in
    /// the date override list rows.
    static func dateLabel(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy年M月d日 (E)"
        return formatter.string(from: date)
    }

    private func targetEditor(
        targets: HealthTargets,
        apply: @escaping (HealthTargets) -> Void,
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(HealthTargetMetric.allCases) { metric in
                targetFieldRow(metric: metric, targets: targets, apply: apply)
            }
            Text("数値を空欄にすると、その項目は未設定になります。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    private func targetFieldRow(
        metric: HealthTargetMetric,
        targets: HealthTargets,
        apply: @escaping (HealthTargets) -> Void,
    ) -> some View {
        let current = targets.value(for: metric)
        let bindingText = Binding<String>(
            get: { current.map(String.init) ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                let parsed = trimmed.isEmpty ? nil : Int(trimmed)
                apply(targets.setting(parsed, for: metric))
            }
        )
        return HStack(alignment: .center, spacing: 10) {
            Text(metric.label)
                .font(.subheadline.weight(.semibold))
            Spacer()
            TextField("—", text: bindingText)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.subheadline.weight(.semibold))
                .frame(width: 88)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
            Text(metric.unit)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
        }
    }

    // MARK: - Style helpers (light copy of SettingsView for visual parity)

    private var backgroundLayer: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    Color(red: 0.05, green: 0.07, blue: 0.12),
                    Color(red: 0.07, green: 0.06, blue: 0.13)
                ]
                : [
                    Color(red: 0.93, green: 0.96, blue: 1.00),
                    Color(red: 0.99, green: 0.96, blue: 1.00)
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var accentColor: Color {
        Color(red: 0.49, green: 0.51, blue: 0.97)
    }

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(accentColor)
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(accentColor)
        }
    }

    private func glassCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.05), radius: 14, x: 0, y: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.7), .white.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.6
                    )
            )
    }
}

#Preview {
    NavigationStack {
        HealthTargetSettingsView()
    }
}
