//
//  RunnerStatusChips.swift
//  Pulse Cue
//
//  今 / 残り / 次 — where you are in the workout, in three words.
//
//  Read mid-set, at arm's length, by someone out of breath. That is why they
//  are three short chips rather than a sentence, and why 今 is the filled one:
//  the other two are context for it.
//
//  Presentation only. Every value is derived from `RunnerViewModel` state
//  passed in; nothing here advances a set or touches a Session.
//

import SwiftUI

struct RunnerStatusChips: View {
    let phase: RunnerPhase
    let isRunning: Bool
    let currentStep: Step?
    let nextStep: Step?
    let currentSetIndex: Int

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) { chips }
        } else {
            HStack(spacing: 10) { chips }
        }
    }

    @ViewBuilder
    private var chips: some View {
        chip(
            label: "今",
            value: nowValue,
            accessibilityText: "現在の状態、\(nowValue)",
            isActive: true
        )
        chip(label: "残り", value: remainingValue, accessibilityText: remainingAccessibility)
        chip(label: "次", value: nextValue, accessibilityText: nextAccessibility)
    }

    // MARK: - Values

    private var nowValue: String {
        switch phase {
        case .rest: return "休憩"
        case .exercise: return isRunning ? "実行中" : "準備"
        case .done: return "未開始"
        }
    }

    private var remainingValue: String {
        guard let currentStep else { return "—" }
        // During .rest the just-completed set has not yet incremented
        // currentSetIndex. Treat it as one set already done so the chip
        // counts down as the user expects.
        let setsDone = phase == .rest ? currentSetIndex + 1 : currentSetIndex
        return "\(max(0, currentStep.sets - setsDone))"
    }

    private var nextValue: String {
        if let nextStep { return nextStep.title }
        if isRunning { return "最後" }
        return "—"
    }

    private var remainingAccessibility: String {
        guard currentStep != nil else { return "残りセット、未設定" }
        return "残り \(remainingValue) セット"
    }

    private var nextAccessibility: String {
        if nextStep != nil { return "次の種目、\(nextValue)" }
        return isRunning ? "次の種目、なし" : "次の種目、未設定"
    }

    // MARK: - Chip

    private func chip(
        label: String,
        value: String,
        accessibilityText: String,
        isActive: Bool = false
    ) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(isActive ? Color.white : .secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isActive ? Color.white : .primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(background(isActive: isActive))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.84), AppTheme.iceLight.opacity(0.26), .white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isActive ? 0.9 : 0.7
                )
        )
        // One chip, one sentence: read separately, the label and the value are
        // two fragments that mean nothing apart.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private func background(isActive: Bool) -> some View {
        if isActive {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.accentFilled)
        } else {
            PulseGlassPlate(level: .subtle, focused: true, cornerRadius: 12)
        }
    }
}
