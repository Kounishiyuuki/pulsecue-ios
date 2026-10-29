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

/// A scale split into a whole-number wheel and a fraction wheel, the way
/// Health picks a weight: "82 | .5 kg" instead of one 2201-row wheel.
///
/// Only for scales whose bounds are whole and whose step divides 1. The
/// fraction wheel offers only the steps that exist for the chosen whole
/// number, so at the scale's top (250 on a 250 kg scale) it holds .0 alone:
/// 250.5 cannot be turned to, seen, or reached with VoiceOver.
extension NumericWheelScale {
    var wholeNumbers: ClosedRange<Int> { Int(minValue.rounded(.down))...Int(maxValue.rounded(.down)) }

    var fractionCount: Int { max(1, Int((1 / step).rounded())) }

    /// The fraction steps that stay on the scale for `whole`.
    func fractions(forWhole whole: Int) -> Range<Int> {
        let valid = (0..<fractionCount).filter { fraction in
            let raw = Double(whole) + Double(fraction) * step
            return raw >= minValue - 1e-9 && raw <= maxValue + 1e-9
        }
        guard let first = valid.first, let last = valid.last else { return 0..<1 }
        return first..<(last + 1)
    }

    /// The value at `whole` and the `fraction`-th step of the unit. A
    /// fraction `whole` does not offer (moving 249.9 to 250) falls back onto
    /// the scale, so the result is always a row the wheels can show.
    func value(whole: Int, fraction: Int) -> Double {
        snapped(Double(whole) + Double(fraction) * step)
    }

    /// The wheel positions showing `value` (snapped onto the scale first).
    func parts(of value: Double) -> (whole: Int, fraction: Int) {
        let onScale = snapped(value)
        let whole = Int((onScale + 1e-9).rounded(.down))
        let fraction = Int(((onScale - Double(whole)) / step).rounded())
        return (whole, min(max(fraction, 0), fractionCount - 1))
    }

    /// ".5" for the `fraction`-th step.
    func fractionText(_ fraction: Int) -> String {
        let text = String(format: "%.\(fractionDigits)f", Double(fraction) * step)
        return String(text.drop(while: { $0 == "0" }))
    }
}

/// How `NumericWheelField` lays out its wheel.
enum NumericWheelStyle {
    /// One wheel, one row per value.
    case single
    /// Whole numbers and fractions on two wheels; see `wholeNumbers`.
    case wholeAndFraction
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

/// A weight on two wheels, "82 | .5 kg". Each wheel is labelled with the
/// field and its part, so VoiceOver says which half is being turned.
struct WeightWheelPicker: View {
    let title: String
    let unit: String
    let scale: NumericWheelScale
    let identifier: String
    @Binding var value: Double

    var body: some View {
        let parts = scale.parts(of: value)
        HStack(spacing: 0) {
            Picker("\(title) 整数部", selection: Binding(
                get: { parts.whole },
                set: { value = scale.value(whole: $0, fraction: scale.parts(of: value).fraction) }
            )) {
                ForEach(Array(scale.wholeNumbers), id: \.self) { whole in
                    Text("\(whole)").monospacedDigit().tag(whole)
                }
            }
            .pickerStyle(.wheel)
            .accessibilityLabel("\(title) 整数部")
            .accessibilityIdentifier("\(identifier)-wheel-whole")

            Picker("\(title) 小数部", selection: Binding(
                get: { parts.fraction },
                set: { value = scale.value(whole: scale.parts(of: value).whole, fraction: $0) }
            )) {
                ForEach(scale.fractions(forWhole: parts.whole), id: \.self) { fraction in
                    Text(scale.fractionText(fraction)).monospacedDigit().tag(fraction)
                }
            }
            .pickerStyle(.wheel)
            // A wheel whose rows change underneath it can keep showing a row
            // that is gone; a new identity per row set redraws it on the
            // selection.
            .id(scale.fractions(forWhole: parts.whole))
            .accessibilityLabel("\(title) 小数部")
            .accessibilityIdentifier("\(identifier)-wheel-fraction")

            Text(unit)
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .labelsHidden()
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
    var style: NumericWheelStyle = .single
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
                wheel
                    .padding(.horizontal, 16)
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

    @ViewBuilder
    private var wheel: some View {
        switch style {
        case .single:
            NumericWheelPicker(title: title, unit: unit, scale: scale, signed: signed, value: $editing)
                .accessibilityIdentifier("\(identifier)-wheel")
        case .wholeAndFraction:
            WeightWheelPicker(title: title, unit: unit, scale: scale, identifier: identifier, value: $editing)
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
        style: NumericWheelStyle = .single,
        value: Binding<Double?>,
        initial: Double,
        identifier: String
    ) {
        self.init(
            title: title, unit: unit, scale: scale, signed: signed, style: style,
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
