//
//  NumericWheelPicker.swift
//  Pulse Cue
//
//  The wheel the profile's numbers are picked with, in onboarding and in
//  「設定 › 体と目標」 alike, so the two never feel like different apps.
//
//  A row shows the value; tapping it opens a short sheet with one wheel.
//  Never several wheels inline: a Form of them would be mostly wheel.
//
//  The wheel is driven by row index, not by the Double itself. Building
//  values as `lower + i * step` and tagging rows with them would make
//  equality depend on floating-point accumulation (30 + 0.1 * 3 != 30.3);
//  an index cannot drift.
//

import SwiftUI

/// The values a wheel offers: `range` walked in `step`s. Ranges come from
/// `ProfileFieldRanges`; nothing here defines a bound of its own.
struct NumericWheelScale: Equatable {
    let lowerBound: Double
    let step: Double
    let count: Int
    /// Decimal places `step` needs, used both for rounding and for display.
    let fractionDigits: Int

    init(range: ClosedRange<Double>, step: Double) {
        precondition(step > 0, "NumericWheelScale step must be positive, got \(step)")
        lowerBound = range.lowerBound
        self.step = step
        // The epsilon keeps 220 / 0.1 = 2199.99… from dropping the last row.
        count = Int(((range.upperBound - range.lowerBound) / step + 1e-9).rounded(.down)) + 1
        var digits = 0
        while digits < 3, abs((step * pow(10, Double(digits))).rounded() - step * pow(10, Double(digits))) > 1e-9 {
            digits += 1
        }
        fractionDigits = digits
    }

    init(range: ClosedRange<Int>, step: Int = 1) {
        self.init(range: Double(range.lowerBound)...Double(range.upperBound), step: Double(step))
    }

    var minValue: Double { value(at: 0) }
    var maxValue: Double { value(at: count - 1) }

    func value(at index: Int) -> Double {
        let clamped = min(max(index, 0), count - 1)
        let scale = pow(10, Double(fractionDigits))
        return ((lowerBound + Double(clamped) * step) * scale).rounded() / scale
    }

    /// The row nearest `value`, clamped into the scale.
    func index(nearest value: Double) -> Int {
        min(max(Int(((value - lowerBound) / step).rounded()), 0), count - 1)
    }

    /// `value` moved onto the scale: the nearest row's value.
    func snapped(_ value: Double) -> Double {
        self.value(at: index(nearest: value))
    }

    func text(_ value: Double, signed: Bool = false) -> String {
        String(format: signed ? "%+.\(fractionDigits)f" : "%.\(fractionDigits)f", value)
    }
}

/// The profile's wheels, each built from `ProfileFieldRanges`.
extension NumericWheelScale {
    static let ageYears = NumericWheelScale(range: ProfileFieldRanges.ageYears)
    static let heightCm = NumericWheelScale(range: ProfileFieldRanges.heightCm)
    static let bodyWeightKg = NumericWheelScale(
        range: ProfileFieldRanges.bodyWeightKg, step: ProfileFieldRanges.bodyWeightStepKg
    )
    static let goalWeightKg = NumericWheelScale(
        range: ProfileFieldRanges.goalWeightKg, step: ProfileFieldRanges.goalWeightStepKg
    )
    static let weeklyChangeKg = NumericWheelScale(
        range: ProfileFieldRanges.weeklyChangeKg, step: ProfileFieldRanges.weeklyChangeStepKg
    )
    static let trainingDaysPerWeek = NumericWheelScale(range: ProfileFieldRanges.trainingDaysPerWeek)
    static let sessionMinutes = NumericWheelScale(
        range: ProfileFieldRanges.sessionMinutes, step: ProfileFieldRanges.sessionMinutesStep
    )
}

/// One wheel over `scale`. Each row reads value and unit together, so
/// VoiceOver says "72.5 kg", not a bare number.
struct NumericWheelPicker: View {
    let title: String
    let unit: String
    let scale: NumericWheelScale
    var signed = false
    @Binding var value: Double

    var body: some View {
        Picker(title, selection: Binding(
            get: { scale.index(nearest: value) },
            set: { value = scale.value(at: $0) }
        )) {
            ForEach(0..<scale.count, id: \.self) { index in
                Text("\(scale.text(scale.value(at: index), signed: signed)) \(unit)")
                    .monospacedDigit()
                    .tag(index)
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
        .accessibilityLabel(title)
    }
}

/// A tappable value that opens a `NumericWheelPicker` in a sheet. The sheet
/// edits a copy and writes back only on 完了, so a dismissed sheet changes
/// nothing.
///
/// `value` is optional: nil reads 未設定 and the wheel opens at `initial`.
/// The default `label` is a Form row; Settings passes its own cell.
struct NumericWheelField<Label: View>: View {
    let title: String
    let unit: String
    let scale: NumericWheelScale
    var signed = false
    @Binding var value: Double?
    let initial: Double
    let identifier: String
    @ViewBuilder let label: (_ valueText: String) -> Label

    @State private var isEditing = false
    @State private var editing = 0.0

    var body: some View {
        Button {
            editing = scale.snapped(value ?? initial)
            isEditing = true
        } label: {
            label(valueText)
                // A Form button would tint the whole row in the accent.
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .accessibilityValue(valueText)
        .accessibilityHint("ダブルタップで値を選択")
        .accessibilityIdentifier(identifier)
        .sheet(isPresented: $isEditing) {
            NavigationStack {
                NumericWheelPicker(title: title, unit: unit, scale: scale, signed: signed, value: $editing)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("\(identifier)-wheel")
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("キャンセル") { isEditing = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完了") {
                                value = editing
                                isEditing = false
                            }
                            .accessibilityIdentifier("\(identifier)-done")
                        }
                    }
            }
            .presentationDetents([.medium])
        }
    }

    private var valueText: String {
        value.map { "\(scale.text($0, signed: signed)) \(unit)" } ?? "未設定"
    }
}

extension NumericWheelField where Label == LabeledContent<Text, Text> {
    init(
        _ title: String,
        unit: String,
        scale: NumericWheelScale,
        signed: Bool = false,
        value: Binding<Double?>,
        initial: Double,
        identifier: String
    ) {
        self.init(
            title: title, unit: unit, scale: scale, signed: signed,
            value: value, initial: initial, identifier: identifier
        ) { valueText in
            LabeledContent { Text(valueText) } label: { Text(title) }
        }
    }
}

extension Binding where Value == Int {
    /// An Int field as the wheel's `Double?`. The wheel only ever writes
    /// whole numbers to an integer scale, so the rounding never loses data.
    var wheelValue: Binding<Double?> {
        Binding<Double?>(
            get: { Double(wrappedValue) },
            set: { if let new = $0 { wrappedValue = Int(new.rounded()) } }
        )
    }
}

extension Binding where Value == Int? {
    var wheelValue: Binding<Double?> {
        Binding<Double?>(
            get: { wrappedValue.map(Double.init) },
            set: { if let new = $0 { wrappedValue = Int(new.rounded()) } }
        )
    }
}

extension Binding where Value == Double {
    var wheelValue: Binding<Double?> {
        Binding<Double?>(
            get: { wrappedValue },
            set: { if let new = $0 { wrappedValue = new } }
        )
    }
}
