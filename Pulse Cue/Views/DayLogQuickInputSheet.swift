//
//  DayLogQuickInputSheet.swift
//  Pulse Cue
//
//  Created by Codex.
//

import SwiftUI
import SwiftData

struct DayLogQuickInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var dayLog: DayLog
    let field: DayLogField

    @State private var valueText: String

    init(field: DayLogField, dayLog: DayLog) {
        self.field = field
        self._dayLog = Bindable(wrappedValue: dayLog)
        self._valueText = State(initialValue: DayLogQuickInputSheet.initialValue(field: field, dayLog: dayLog))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(fieldTitle, text: $valueText)
                        .keyboardType(keyboardType)
                } footer: {
                    Text(footerText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(fieldTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        dismiss()
                    }
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

    private var fieldTitle: String {
        switch field {
        case .workout: return "運動消費カロリー"
        case .nutrition: return "摂取カロリー"
        case .sleep: return "睡眠（分）"
        case .weight: return "体重（kg）"
        }
    }

    private var footerText: String {
        switch field {
        case .workout: return "運動で消費した推定カロリー。"
        case .nutrition: return "今日の総摂取カロリー。"
        case .sleep: return "睡眠時間（分）。"
        case .weight: return "体重（kg）。"
        }
    }

    private var keyboardType: UIKeyboardType {
        switch field {
        case .weight: return .decimalPad
        default: return .numberPad
        }
    }

    private func save() {
        let trimmed = valueText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            setValue(nil)
            return
        }
        switch field {
        case .weight:
            setValue(Double(trimmed))
        default:
            setValue(Int(trimmed))
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
