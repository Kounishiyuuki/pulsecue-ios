//
//  SettingsChrome.swift
//  Pulse Cue
//
//  The visual vocabulary the settings sections are written in.
//
//  These were private helpers inside one 1,100-line `SettingsView`, which is
//  what made the screen hard to split: every card was welded to the file that
//  held its glass plate and its number formatter. They say nothing about body
//  measurements, HealthKit or the account — they are the shared *how it looks*,
//  so they live apart from the four *what it is about* sections.
//
//  Deliberately a namespace of static helpers rather than a set of new view
//  types: the goal was to stop copying them, not to introduce four public
//  components with lifecycles of their own.
//

import SwiftUI

enum SettingsChrome {

    // MARK: - Cards

    static func glassCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(glassBackground)
            .overlay(glassStroke)
    }

    static func featuredGlassCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(
                PulseGlassPlate(level: .functional, cornerRadius: 24)
            )
    }

    static var glassBackground: some View {
        PulseGlassPlate(level: .subtle, cornerRadius: 22)
    }

    static var glassStroke: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.clear, lineWidth: 0)
    }

    static func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(AppTheme.accent)
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppTheme.accent)
        }
    }

    // MARK: - Gradients

    static func accentGradient(_ colorScheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [AppTheme.iceLight, AppTheme.edgeBlue]
                : [AppTheme.accentFilled, AppTheme.accent],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func tealGradient(_ colorScheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [AppTheme.iceLight, AppTheme.reflectedBlue]
                : [AppTheme.deepGlass, AppTheme.reflectedBlue],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Cells

    /// A profile number shown large, opening the shared wheel sheet when
    /// tapped — the same control onboarding uses for the same fields.
    ///
    /// - Parameter identifier: stable handle for UI tests. Defaults to the
    ///   label, which is fine until two cells share one; pass an explicit
    ///   identifier when a test needs to address exactly this control.
    static func wheelNumberCell(
        label: String,
        helper: String? = nil,
        scale: NumericWheelScale,
        signed: Bool = false,
        style: NumericWheelStyle = .single,
        unit: String,
        binding: Binding<Double?>,
        identifier: String? = nil
    ) -> some View {
        NumericWheelField(
            title: label,
            unit: unit,
            scale: scale,
            signed: signed,
            style: style,
            value: binding,
            initial: binding.wrappedValue ?? scale.minValue,
            identifier: identifier ?? label
        ) { _ in
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(binding.wrappedValue.map { scale.text($0, signed: signed) } ?? "—")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        Text(unit)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let helper {
                        Text(helper)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.09))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.30), lineWidth: 0.6)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    static func pickerCell<T, Content: View>(
        label: String,
        selection: Binding<T>,
        @ViewBuilder content: @escaping (T) -> Content
    ) -> some View where T: Hashable & CaseIterable & Identifiable, T.AllCases == [T] {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Picker(label, selection: selection) {
                    ForEach(T.allCases) { item in
                        content(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.primary)
            }
            Spacer()
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.30), lineWidth: 0.6)
                )
        )
    }

    static func derivedRow(
        label: String,
        value: String,
        valueStyle: Color = .primary
    ) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(valueStyle)
        }
    }

    /// - Parameter identifier: stable handle for UI tests. These figures are
    ///   derived from the profile on screen, and the only way to prove they
    ///   update as it is edited is to read them back after an edit.
    static func summaryCard(
        label: String,
        value: String,
        unit: String,
        gradient: LinearGradient,
        identifier: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(gradient)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(glassBackground)
        .overlay(glassStroke)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value) \(unit)")
        .accessibilityIdentifier(identifier ?? label)
    }
}
