//
//  DayLogQuickInputSheet.swift
//  Pulse Cue
//
//  Created by Codex.
//
//  Sleep and weight are adjusted with keyboard-free wheel controls (a natural,
//  bounded, VoiceOver-friendly way to nudge a value). Calorie fields keep the
//  numeric keyboard because their range is open-ended. No schema change: the
//  wheels map to the existing `DayLog.sleepMinutes` (Int) / `weightKg` (Double).
//

import SwiftUI
import SwiftData

struct DayLogQuickInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var dayLog: DayLog
    let field: DayLogField

    // Calorie fields (open-ended range) keep the numeric keyboard.
    @State private var valueText: String
    // Sleep, adjusted as hours + minutes.
    @State private var sleepHours: Int
    @State private var sleepMinutes: Int
    // Weight, adjusted as whole kilograms + a 0.1 kg decimal.
    @State private var weightWhole: Int
    @State private var weightDecimal: Int

    // Bounds for the wheel ranges. Sleep spans a full day (0–24h; 24h is the
    // ceiling and allows only 24h00m); weight spans a generous adult range.
    // All inclusive.
    private static let sleepHourRange = 0...24
    private static let sleepMinuteRange = 0...59
    private static let weightWholeRange = 20...250
    private static let weightDecimalRange = 0...9

    /// Draft value shown when no sleep is recorded yet (6h00m). Only saved on
    /// an explicit "保存"; opening or cancelling records nothing.
    private static let sleepDraftMinutes = 360

    init(field: DayLogField, dayLog: DayLog) {
        self.field = field
        self._dayLog = Bindable(wrappedValue: dayLog)
        self._valueText = State(initialValue: DayLogQuickInputSheet.initialValue(field: field, dayLog: dayLog))

        let sleep = DayLogQuickInputSheet.sleepComponents(
            fromMinutes: DayLogQuickInputSheet.initialSleepMinutes(stored: dayLog.sleepMinutes)
        )
        let clampedHours = sleep.hours.clamped(to: DayLogQuickInputSheet.sleepHourRange)
        self._sleepHours = State(initialValue: clampedHours)
        // At the 24h ceiling only 24h00m is valid, so pin minutes to 0.
        self._sleepMinutes = State(
            initialValue: clampedHours >= 24 ? 0 : sleep.minutes.clamped(to: DayLogQuickInputSheet.sleepMinuteRange)
        )

        let weight = DayLogQuickInputSheet.weightComponents(fromKg: dayLog.weightKg ?? 60.0)
        self._weightWhole = State(initialValue: weight.whole.clamped(to: DayLogQuickInputSheet.weightWholeRange))
        self._weightDecimal = State(initialValue: weight.decimal.clamped(to: DayLogQuickInputSheet.weightDecimalRange))
    }

    var body: some View {
        NavigationStack {
            Form {
                switch field {
                case .sleep:
                    sleepSection
                case .weight:
                    weightSection
                case .workout, .nutrition:
                    calorieSection
                }

                if hadValue {
                    Section {
                        Button("記録を削除", role: .destructive) {
                            setValue(nil)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(fieldTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private var sleepSection: some View {
        Section {
            summaryText(sleepSummary)
                .accessibilityLabel("睡眠 \(sleepSummary)")

            HStack(spacing: 0) {
                wheel(
                    "時間",
                    selection: $sleepHours,
                    range: Self.sleepHourRange,
                    format: { "\($0)" }
                )
                wheel(
                    "分",
                    selection: $sleepMinutes,
                    range: Self.sleepMinuteRange,
                    format: { String(format: "%02d", $0) }
                )
                // 24h is the ceiling and permits only 24h00m, so the minutes
                // wheel is pinned to 0 and disabled there.
                .disabled(sleepHours >= 24)
            }
            .onChange(of: sleepHours) { _, hours in
                if hours >= 24 { sleepMinutes = 0 }
            }
        } footer: {
            Text("時間と分のホイールで調整できます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var weightSection: some View {
        Section {
            summaryText(weightSummary)
                .accessibilityLabel("体重 \(weightSummary)")

            HStack(spacing: 0) {
                wheel(
                    "kg",
                    selection: $weightWhole,
                    range: Self.weightWholeRange,
                    format: { "\($0)" }
                )
                wheel(
                    "小数",
                    selection: $weightDecimal,
                    range: Self.weightDecimalRange,
                    format: { ".\($0)" }
                )
            }
        } footer: {
            Text("0.1 kg 単位でホイール調整できます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var calorieSection: some View {
        Section {
            TextField(fieldTitle, text: $valueText)
                .keyboardType(.numberPad)
        } footer: {
            Text(footerText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Reusable pieces

    private func summaryText(_ text: String) -> some View {
        Text(text)
            .font(.title2.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityAddTraits(.updatesFrequently)
    }

    /// A labeled wheel column. The visible caption sits above the wheel; the
    /// picker itself carries the same label for VoiceOver.
    private func wheel(
        _ caption: String,
        selection: Binding<Int>,
        range: ClosedRange<Int>,
        format: @escaping (Int) -> String
    ) -> some View {
        VStack(spacing: 2) {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(caption, selection: selection) {
                ForEach(Array(range), id: \.self) { value in
                    Text(format(value)).tag(value)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .accessibilityLabel(caption)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Summaries

    private var sleepSummary: String {
        "\(sleepHours)時間\(sleepMinutes)分"
    }

    private var weightSummary: String {
        String(format: "%.1f kg", Self.weightValue(whole: weightWhole, decimal: weightDecimal))
    }

    private var hadValue: Bool {
        switch field {
        case .sleep: return dayLog.sleepMinutes != nil
        case .weight: return dayLog.weightKg != nil
        case .workout: return dayLog.exerciseCalories != nil
        case .nutrition: return dayLog.intakeCalories != nil
        }
    }

    private var fieldTitle: String {
        switch field {
        case .workout: return "運動消費カロリー"
        case .nutrition: return "摂取カロリー"
        case .sleep: return "睡眠時間"
        case .weight: return "体重（kg）"
        }
    }

    private var footerText: String {
        switch field {
        case .workout: return "運動で消費した推定カロリー。"
        case .nutrition: return "今日の総摂取カロリー。"
        case .sleep: return "睡眠時間。"
        case .weight: return "体重（kg）。"
        }
    }

    // MARK: - Save

    private func save() {
        switch field {
        case .sleep:
            let total = Self.totalSleepMinutes(hours: sleepHours, minutes: sleepMinutes)
            dayLog.sleepMinutes = total == 0 ? nil : total
        case .weight:
            dayLog.weightKg = Self.weightValue(whole: weightWhole, decimal: weightDecimal)
        case .workout, .nutrition:
            let trimmed = valueText.trimmingCharacters(in: .whitespacesAndNewlines)
            setValue(trimmed.isEmpty ? nil : Int(trimmed))
        }
    }

    private func setValue(_ value: Any?) {
        switch field {
        case .workout:
            dayLog.exerciseCalories = value as? Int
        case .nutrition:
            dayLog.intakeCalories = value as? Int
        case .sleep:
            dayLog.sleepMinutes = value as? Int
        case .weight:
            dayLog.weightKg = value as? Double
        }
    }

    // MARK: - Pure conversions (unit-tested)

    /// The minutes the sheet should open on: the stored value when present,
    /// otherwise the 6h00m draft. The draft is display-only until an explicit
    /// "保存"; opening or cancelling the sheet never writes it.
    static func initialSleepMinutes(stored: Int?) -> Int {
        stored ?? sleepDraftMinutes
    }

    static func sleepComponents(fromMinutes minutes: Int) -> (hours: Int, minutes: Int) {
        let clamped = max(0, minutes)
        return (clamped / 60, clamped % 60)
    }

    static func totalSleepMinutes(hours: Int, minutes: Int) -> Int {
        let boundedHours = max(0, hours)
        // 24h is the ceiling and only 24h00m is valid, so minutes are dropped.
        if boundedHours >= 24 { return 24 * 60 }
        return boundedHours * 60 + max(0, minutes)
    }

    /// Rounds to the nearest 0.1 kg so the two wheels round-trip a stored value.
    static func weightComponents(fromKg kilograms: Double) -> (whole: Int, decimal: Int) {
        let tenths = Int((max(0, kilograms) * 10).rounded())
        return (tenths / 10, tenths % 10)
    }

    static func weightValue(whole: Int, decimal: Int) -> Double {
        Double(max(0, whole)) + Double(max(0, decimal)) / 10.0
    }

    private static func initialValue(field: DayLogField, dayLog: DayLog) -> String {
        switch field {
        case .workout:
            if let value = dayLog.exerciseCalories { return String(value) }
        case .nutrition:
            if let value = dayLog.intakeCalories { return String(value) }
        case .sleep:
            if let value = dayLog.sleepMinutes { return String(value) }
        case .weight:
            if let value = dayLog.weightKg {
                let formatter = NumberFormatter()
                formatter.minimumFractionDigits = 0
                formatter.maximumFractionDigits = 1
                return formatter.string(from: NSNumber(value: value)) ?? String(value)
            }
        }
        return ""
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
